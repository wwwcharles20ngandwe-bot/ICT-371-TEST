-- Create Employees table
CREATE TABLE employees (
    employee_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL
        CHECK (basic_salary >= 0),
    allowance NUMERIC(12,2) NOT NULL
        CHECK (allowance >= 0),
    deduction NUMERIC(12,2) NOT NULL
        CHECK (deduction >= 0),
    active BOOLEAN NOT NULL DEFAULT TRUE
);

-- Create Payroll table
CREATE TABLE payroll (
    payroll_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL
        REFERENCES employees(employee_id),
    pay_month DATE NOT NULL,
    gross_pay NUMERIC(12,2) NOT NULL
        CHECK (gross_pay >= 0),
    net_pay NUMERIC(12,2) NOT NULL
        CHECK (net_pay >= 0),

    CONSTRAINT uq_employee_pay_month
    UNIQUE (employee_id, pay_month),

    CONSTRAINT chk_pay_month_start
    CHECK (EXTRACT(DAY FROM pay_month) = 1)
);

-- Create Salary Audit table
CREATE TABLE salary_audit (
    audit_id SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL
        REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2),
    new_salary NUMERIC(12,2),
    changed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert employees
INSERT INTO employees (
    full_name,
    basic_salary,
    allowance,
    deduction,
    active
)
VALUES
('John Banda', 5000, 1000, 500, TRUE),
('Mary Phiri', 6000, 1500, 700, TRUE),
('Peter Zulu', 4500, 800, 300, TRUE),
('Grace Mwansa', 5500, 1200, 600, FALSE),
('James Tembo', 4000, 500, 200, TRUE),
('Linda Phiri', 7000, 1000, 800, FALSE);

-- Insert payroll records for two months
INSERT INTO payroll (
    employee_id,
    pay_month,
    gross_pay,
    net_pay
)
VALUES
(1, DATE '2026-09-01', 6000, 5500),
(2, DATE '2026-09-01', 7500, 6800),
(3, DATE '2026-09-01', 5300, 5000),
(4, DATE '2026-09-01', 6700, 6100),
(1, DATE '2026-10-01', 6000, 5500),
(2, DATE '2026-10-01', 7500, 6800),
(3, DATE '2026-10-01', 5300, 5000),
(6, DATE '2026-10-01', 8000, 7200);

-- Display employees
SELECT * FROM employees;

-- Display payroll records
SELECT * FROM payroll;

-- Display salary audit
SELECT * FROM salary_audit;

CREATE OR REPLACE FUNCTION fn_net_pay(
    p_employee_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic_salary NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_gross_pay NUMERIC(12,2);
    v_net_pay NUMERIC(12,2);
BEGIN
    SELECT
        basic_salary,
        allowance,
        deduction
    INTO
        v_basic_salary,
        v_allowance,
        v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Employee ID % does not exist', p_employee_id;
    END IF;

    v_gross_pay := v_basic_salary + v_allowance;

    v_net_pay := v_gross_pay - v_deduction;

    IF v_net_pay < 0 THEN
        RAISE EXCEPTION
        'Net pay cannot be negative for employee %',
        p_employee_id;
    END IF;

    RETURN v_net_pay;
END;
$$;

-- Test the function
SELECT fn_net_pay(1);

SELECT fn_net_pay(2);

SELECT fn_net_pay(3);

-- Test unknown employee
SELECT fn_net_pay(99);

CREATE OR REPLACE PROCEDURE pr_process_payroll(
    p_month DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_employee RECORD;
    v_gross_pay NUMERIC(12,2);
    v_net_pay NUMERIC(12,2);
BEGIN
    -- Validate month
    IF p_month IS NULL THEN
        RAISE EXCEPTION 'Payroll month cannot be NULL';
    END IF;

    IF EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION
        'Pay month must be the first date of a month';
    END IF;

    -- Loop through active employees
    FOR v_employee IN
        SELECT
            employee_id,
            basic_salary,
            allowance
        FROM employees
        WHERE active = TRUE
    LOOP

        -- Calculate gross pay
        v_gross_pay :=
            v_employee.basic_salary +
            v_employee.allowance;

        -- Calculate net pay
        v_net_pay :=
            fn_net_pay(v_employee.employee_id);

        -- Insert only missing payroll records
        INSERT INTO payroll (
            employee_id,
            pay_month,
            gross_pay,
            net_pay
        )
        VALUES (
            v_employee.employee_id,
            p_month,
            v_gross_pay,
            v_net_pay
        )
        ON CONFLICT (employee_id, pay_month)
        DO NOTHING;

    END LOOP;

END;
$$;

-- Process September payroll
CALL pr_process_payroll(DATE '2026-09-01');

-- Process October payroll
CALL pr_process_payroll(DATE '2026-10-01');

-- Process November payroll
CALL pr_process_payroll(DATE '2026-11-01');

-- Display payroll records
SELECT * FROM payroll
ORDER BY pay_month, employee_id;

-- Test invalid month
CALL pr_process_payroll(DATE '2026-11-15');

-- Create trigger function
CREATE OR REPLACE FUNCTION fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.basic_salary IS DISTINCT FROM NEW.basic_salary THEN

        INSERT INTO salary_audit (
            employee_id,
            old_salary,
            new_salary,
            changed_at
        )
        VALUES (
            NEW.employee_id,
            OLD.basic_salary,
            NEW.basic_salary,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;
END;
$$;

-- Create AFTER UPDATE trigger
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION fn_salary_audit();

-- Test actual salary change
UPDATE employees
SET basic_salary = 5500
WHERE employee_id = 1;

-- Test unchanged salary
UPDATE employees
SET basic_salary = 5500
WHERE employee_id = 1;

-- Display salary audit records
SELECT * FROM salary_audit;

-- Display updated employee
SELECT * FROM employees
WHERE employee_id = 1;

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e
    ON p.employee_id = e.employee_id;

-- Display payroll report
SELECT * FROM v_payroll_report
ORDER BY pay_month, full_name;

-- Create non-unique index on pay_month
CREATE INDEX idx_payroll_pay_month
ON payroll(pay_month);

-- Query payroll records for a particular month
SELECT
    payroll_id,
    employee_id,
    pay_month,
    gross_pay,
    net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';

-- Display execution plan
EXPLAIN
SELECT
    payroll_id,
    employee_id,
    pay_month,
    gross_pay,
    net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';

Index justification: The non-unique index on pay_month supports reports that retrieve payroll records for a particular month across all employees. It does not duplicate the existing unique index on (employee_id, pay_month).

-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule payroll processing at 02:00
-- on the first day of every month
SELECT cron.schedule(
    'monthly-payroll-processing',
    '0 2 1 * *',
    $job$
    CALL pr_process_payroll(
        (DATE_TRUNC('month', CURRENT_DATE)
         - INTERVAL '1 month')::DATE
    );
    $job$
);

-- Inspect scheduled jobs
SELECT *
FROM cron.job;

-- Inspect payroll job execution history
SELECT *
FROM cron.job_run_details
ORDER BY start_time DESC;

-- Manually test previous month's payroll
CALL pr_process_payroll(
    (DATE_TRUNC('month', CURRENT_DATE)
     - INTERVAL '1 month')::DATE
);

-- Display processed payroll
SELECT *
FROM payroll
ORDER BY pay_month, employee_id;