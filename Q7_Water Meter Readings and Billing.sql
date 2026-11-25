-- Create Customers table
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

-- Create Readings table
CREATE TABLE readings (
    reading_id SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL
        REFERENCES customers(customer_id),
    reading_month DATE NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL
        CHECK (previous_reading >= 0),
    current_reading NUMERIC(12,2) NOT NULL
        CHECK (current_reading >= 0),

    CONSTRAINT uq_customer_reading_month
        UNIQUE (customer_id, reading_month),

    CONSTRAINT chk_reading_month
        CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

-- Create Bills table
CREATE TABLE bills (
    bill_id SERIAL PRIMARY KEY,
    reading_id INTEGER NOT NULL UNIQUE
        REFERENCES readings(reading_id),
    charge NUMERIC(12,2) NOT NULL
        CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on DATE NOT NULL,

    CONSTRAINT chk_amount_paid
        CHECK (
            amount_paid >= 0
            AND amount_paid <= charge
        )
);

-- Create Receivable Snapshot table
CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due NUMERIC(14,2) NOT NULL
        CHECK (total_due >= 0)
);

-- Insert three customers
INSERT INTO customers (full_name)
VALUES
('John Banda'),
('Mary Phiri'),
('Peter Zulu');

-- Insert six meter readings
INSERT INTO readings (
    customer_id,
    reading_month,
    previous_reading,
    current_reading
)
VALUES
(1, DATE '2026-09-01', 100, 100),
(1, DATE '2026-10-01', 100, 110),
(2, DATE '2026-09-01', 200, 215),
(2, DATE '2026-10-01', 215, 225),
(3, DATE '2026-09-01', 300, 308),
(3, DATE '2026-10-01', 308, 328);

-- Display customers
SELECT * FROM customers;

-- Display readings
SELECT * FROM readings;

-- Display bills
SELECT * FROM bills;

-- Display receivable snapshots
SELECT * FROM receivable_snapshot;

CREATE OR REPLACE FUNCTION fn_water_charge(
    p_units NUMERIC
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12,2);
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION
        'Consumption units cannot be NULL';
    END IF;

    IF p_units < 0 THEN
        RAISE EXCEPTION
        'Consumption units cannot be negative';
    END IF;

    IF p_units <= 10 THEN
        v_charge := p_units * 5;
    ELSE
        v_charge :=
            (10 * 5) +
            ((p_units - 10) * 8);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;

-- Test zero consumption
SELECT fn_water_charge(0);

-- Test exactly 10 units
SELECT fn_water_charge(10);

-- Test consumption above 10 units
SELECT fn_water_charge(15);

-- Test negative consumption
SELECT fn_water_charge(-5);

-- Test NULL consumption
SELECT fn_water_charge(NULL);

CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INTEGER,
    p_due_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_previous_reading NUMERIC(12,2);
    v_current_reading NUMERIC(12,2);
    v_consumption NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    -- Validate due date
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date cannot be NULL';
    END IF;

    -- Get meter readings
    SELECT
        previous_reading,
        current_reading
    INTO
        v_previous_reading,
        v_current_reading
    FROM readings
    WHERE reading_id = p_reading_id;

    -- Reject unknown reading
    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Reading ID % does not exist', p_reading_id;
    END IF;

    -- Check whether a bill already exists
    IF EXISTS (
        SELECT 1
        FROM bills
        WHERE reading_id = p_reading_id
    ) THEN
        RAISE EXCEPTION
        'A bill already exists for reading ID %',
        p_reading_id;
    END IF;

    -- Calculate consumption
    v_consumption :=
        v_current_reading - v_previous_reading;

    -- Calculate water charge
    v_charge := fn_water_charge(v_consumption);

    -- Insert bill
    INSERT INTO bills (
        reading_id,
        charge,
        amount_paid,
        due_on
    )
    VALUES (
        p_reading_id,
        v_charge,
        0,
        p_due_on
    );

END;
$$;

-- Generate bills for all six readings
CALL pr_generate_bill(1, CURRENT_DATE - 30);

CALL pr_generate_bill(2, CURRENT_DATE - 10);

CALL pr_generate_bill(3, CURRENT_DATE - 25);

CALL pr_generate_bill(4, CURRENT_DATE - 5);

CALL pr_generate_bill(5, CURRENT_DATE - 20);

CALL pr_generate_bill(6, CURRENT_DATE + 10);

-- Display generated bills
SELECT * FROM bills;

-- Test unknown reading
CALL pr_generate_bill(99, CURRENT_DATE + 10);

-- Test duplicate bill
CALL pr_generate_bill(1, CURRENT_DATE + 10);

-- Create trigger function
CREATE OR REPLACE FUNCTION fn_check_meter_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION
        'Current meter reading cannot be less than previous reading';
    END IF;

    RETURN NEW;
END;
$$;

-- Create BEFORE INSERT OR UPDATE trigger
CREATE TRIGGER trg_check_meter_reading
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION fn_check_meter_reading();

-- Test valid reading
INSERT INTO readings (
    customer_id,
    reading_month,
    previous_reading,
    current_reading
)
VALUES (
    1,
    DATE '2026-11-01',
    110,
    120
);

-- Test invalid reading
INSERT INTO readings (
    customer_id,
    reading_month,
    previous_reading,
    current_reading
)
VALUES (
    2,
    DATE '2026-11-01',
    225,
    200
);

-- Test invalid update
UPDATE readings
SET current_reading = 90
WHERE reading_id = 1;

-- Display readings
SELECT * FROM readings;

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r
    ON b.reading_id = r.reading_id
JOIN customers c
    ON r.customer_id = c.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- Display overdue bills
SELECT * FROM v_overdue_bills;

-- Create partial index for unpaid bills by due date
CREATE INDEX idx_bills_overdue_due_on
ON bills(due_on)
WHERE amount_paid < charge;

-- Matching unpaid-bill query
SELECT
    bill_id,
    reading_id,
    charge,
    amount_paid,
    (charge - amount_paid) AS outstanding_amount,
    due_on
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

-- Display execution plan
EXPLAIN
SELECT
    bill_id,
    reading_id,
    charge,
    amount_paid,
    (charge - amount_paid) AS outstanding_amount,
    due_on
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

  -- Create receivables refresh procedure
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (
        snapshot_date,
        total_due
    )
    SELECT
        CURRENT_DATE,
        COALESCE(
            SUM(charge - amount_paid),
            0
        )
    FROM bills
    WHERE amount_paid < charge

    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        total_due = EXCLUDED.total_due;

END;
$$;

-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule daily execution at 00:30
SELECT cron.schedule(
    'daily-receivables-refresh',
    '30 0 * * *',
    'CALL pr_refresh_receivables();'
);

-- Test procedure manually
CALL pr_refresh_receivables();

-- Display receivable snapshots
SELECT * FROM receivable_snapshot;

-- Inspect scheduled jobs
SELECT * FROM cron.job;

-- Inspect job execution history
SELECT *
FROM cron.job_run_details
ORDER BY start_time DESC;
