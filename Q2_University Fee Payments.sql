
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL,
    fee_due NUMERIC(12,2) NOT NULL
        CHECK (fee_due >= 0)
);


CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL,
    amount NUMERIC(12,2) NOT NULL
        CHECK (amount > 0),
    paid_on DATE NOT NULL,

    CONSTRAINT fk_payments_student
        FOREIGN KEY (student_id)
        REFERENCES students(student_id)
);


CREATE TABLE payment_audit (
    audit_id SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL,
    student_id INTEGER NOT NULL,
    amount NUMERIC(12,2) NOT NULL,
    logged_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_audit_payment
        FOREIGN KEY (payment_id)
        REFERENCES payments(payment_id),

    CONSTRAINT fk_audit_student
        FOREIGN KEY (student_id)
        REFERENCES students(student_id)
);


CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count INTEGER NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);


INSERT INTO students
(student_number, full_name, fee_due)
VALUES
('MU2024001', 'John Banda', 5000.00),
('MU2024002', 'Mary Phiri', 8000.00),
('MU2024003', 'Peter Zulu', 6500.00);


CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INTEGER
)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12,2);
    v_total_paid NUMERIC(12,2);
BEGIN

    -- Get the student's total fees
    SELECT fee_due
    INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    -- Reject an unknown student
    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Student ID % does not exist',
        p_student_id;
    END IF;

    -- Calculate total payments
    SELECT COALESCE(SUM(amount), 0)
    INTO v_total_paid
    FROM payments
    WHERE student_id = p_student_id;

    -- Return outstanding balance
    RETURN v_fee_due - v_total_paid;

END;
$$;


CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount NUMERIC(12,2),
    p_paid_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN

    -- Validate payment amount
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION
        'Payment amount must be greater than zero';
    END IF;

    -- Validate payment date
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION
        'Payment date cannot be NULL';
    END IF;

    -- Lock the student row and check existence
    PERFORM 1
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Student ID % does not exist',
        p_student_id;
    END IF;

    -- Calculate outstanding balance
    v_balance := fn_fee_balance(p_student_id);

    -- Prevent credit balances
    IF p_amount > v_balance THEN
        RAISE EXCEPTION
        'Payment exceeds outstanding balance. Balance: %',
        v_balance;
    END IF;

    -- Insert valid payment
    INSERT INTO payments (
        student_id,
        amount,
        paid_on
    )
    VALUES (
        p_student_id,
        p_amount,
        p_paid_on
    );

END;
$$;


CREATE OR REPLACE FUNCTION fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    INSERT INTO payment_audit (
        payment_id,
        student_id,
        amount,
        logged_at
    )
    VALUES (
        NEW.payment_id,
        NEW.student_id,
        NEW.amount,
        CURRENT_TIMESTAMP
    );

    RETURN NEW;

END;
$$;


CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    s.fee_due - COALESCE(SUM(p.amount), 0)
        AS outstanding_balance
FROM students s
LEFT JOIN payments p
    ON s.student_id = p.student_id
GROUP BY
    s.student_id,
    s.student_number,
    s.full_name,
    s.fee_due
HAVING
    s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

	
CREATE INDEX idx_payments_student_date
ON payments (student_id, paid_on);


SELECT
    payment_id,
    student_id,
    amount,
    paid_on
FROM payments
WHERE student_id = 1
AND paid_on BETWEEN
    DATE '2026-11-01'
    AND DATE '2026-11-25';


EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
AND paid_on BETWEEN
    DATE '2026-11-01'
    AND DATE '2026-11-25';

RESET enable_seqscan;


CREATE OR REPLACE PROCEDURE pr_refresh_collections(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate the date
    IF p_day IS NULL THEN
        RAISE EXCEPTION
        'Collection date cannot be NULL';
    END IF;

    -- Calculate daily payment collections
    INSERT INTO daily_collections (
        collection_date,
        payment_count,
        total_amount
    )
    SELECT
        p_day,
        COUNT(payment_id),
        COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day

    -- Replace an existing summary
    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount = EXCLUDED.total_amount;

END;
$$;