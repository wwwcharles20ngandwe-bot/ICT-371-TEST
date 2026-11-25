-- Create Farmers table
CREATE TABLE farmers (
    farmer_id SERIAL PRIMARY KEY,
    farmer_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

-- Create Deliveries table
CREATE TABLE deliveries (
    delivery_id SERIAL PRIMARY KEY,
    farmer_id INTEGER NOT NULL
        REFERENCES farmers(farmer_id),
    grade CHAR(1) NOT NULL
        CHECK (grade IN ('A', 'B', 'C')),
    weight_kg NUMERIC(12,2) NOT NULL
        CHECK (weight_kg > 0),
    unit_rate NUMERIC(10,2) NOT NULL DEFAULT 0,
    total_value NUMERIC(14,2) NOT NULL DEFAULT 0,
    delivered_on DATE NOT NULL,
    is_paid BOOLEAN NOT NULL DEFAULT FALSE
);

-- Create Daily Purchases table
CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_value NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- Insert three farmers
INSERT INTO farmers (farmer_number, full_name)
VALUES
('F001', 'John Banda'),
('F002', 'Mary Phiri'),
('F003', 'Peter Zulu');

-- Display farmers
SELECT * FROM farmers;

CREATE OR REPLACE FUNCTION fn_maize_rate(
    p_grade CHAR(1)
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN
            RETURN 5.00;
        WHEN 'B' THEN
            RETURN 4.00;
        WHEN 'C' THEN
            RETURN 3.00;
        ELSE
            RAISE EXCEPTION
            'Unsupported maize grade: %', p_grade;
    END CASE;
END;
$$;

-- Test grade A
SELECT fn_maize_rate('A');

-- Test grade B
SELECT fn_maize_rate('B');

-- Test grade C
SELECT fn_maize_rate('C');

-- Test unsupported grade
SELECT fn_maize_rate('D');

-- Test NULL grade
SELECT fn_maize_rate(NULL);

CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade CHAR(1),
    p_weight NUMERIC,
    p_date DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Validate farmer
    IF NOT EXISTS (
        SELECT 1
        FROM farmers
        WHERE farmer_id = p_farmer_id
    ) THEN
        RAISE EXCEPTION
        'Farmer ID % does not exist', p_farmer_id;
    END IF;

    -- Validate grade
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    PERFORM fn_maize_rate(p_grade);

    -- Validate weight
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION
        'Weight must be greater than zero';
    END IF;

    -- Validate delivery date
    IF p_date IS NULL THEN
        RAISE EXCEPTION
        'Delivery date cannot be NULL';
    END IF;

    -- Insert basic delivery information
    INSERT INTO deliveries (
        farmer_id,
        grade,
        weight_kg,
        delivered_on,
        is_paid
    )
    VALUES (
        p_farmer_id,
        UPPER(TRIM(p_grade)),
        p_weight,
        p_date,
        FALSE
    );

END;
$$;


-- Create trigger function
CREATE OR REPLACE FUNCTION fn_calculate_delivery_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Reject non-positive weight
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION
        'Delivery weight must be greater than zero';
    END IF;

    -- Validate and normalize grade
    IF NEW.grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL';
    END IF;

    NEW.grade := UPPER(TRIM(NEW.grade));

    -- Get the correct unit rate
    NEW.unit_rate := fn_maize_rate(NEW.grade);

    -- Calculate total delivery value
    NEW.total_value :=
        ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

-- Create BEFORE INSERT OR UPDATE trigger
CREATE TRIGGER trg_calculate_delivery_value
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION fn_calculate_delivery_value();

-- Insert six deliveries using the procedure
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 5);
CALL pr_receive_delivery(1, 'B', 150, CURRENT_DATE - 4);
CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE - 3);
CALL pr_receive_delivery(2, 'A', 120, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'B', 180, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C', 250, CURRENT_DATE);

-- Mark some deliveries as paid
UPDATE deliveries
SET is_paid = TRUE
WHERE delivery_id IN (1, 3, 5);

-- Display deliveries
SELECT * FROM deliveries;

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(
        SUM(d.total_value)
        FILTER (WHERE d.is_paid = FALSE),
        0
    ) AS total_unpaid_value
FROM farmers f
LEFT JOIN deliveries d
    ON f.farmer_id = d.farmer_id
GROUP BY
    f.farmer_id,
    f.farmer_number,
    f.full_name;

-- Display farmer amounts due
SELECT * FROM v_farmer_amount_due;

-- Create composite index
CREATE INDEX idx_deliveries_farmer_date
ON deliveries(farmer_id, delivered_on);

-- Query deliveries for a particular farmer
-- within a specified date range
SELECT
    delivery_id,
    farmer_id,
    grade,
    weight_kg,
    unit_rate,
    total_value,
    delivered_on,
    is_paid
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN
      CURRENT_DATE - 30 AND CURRENT_DATE;

-- Display execution plan
EXPLAIN
SELECT
    delivery_id,
    farmer_id,
    grade,
    weight_kg,
    unit_rate,
    total_value,
    delivered_on,
    is_paid
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN
      CURRENT_DATE - 30 AND CURRENT_DATE;

	  Index justification: The composite index on (farmer_id, delivered_on) supports queries that search for a particular farmer's deliveries within a specified date range.

	  -- Create daily purchases refresh procedure
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION
        'Purchase date cannot be NULL';
    END IF;

    INSERT INTO daily_purchases (
        purchase_date,
        total_weight,
        total_value
    )
    SELECT
        p_day,
        COALESCE(SUM(weight_kg), 0),
        COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day

    ON CONFLICT (purchase_date)
    DO UPDATE SET
        total_weight = EXCLUDED.total_weight,
        total_value = EXCLUDED.total_value;

END;
$$;

-- Enable pg_cron
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule daily execution at 01:30
-- for the previous day
SELECT cron.schedule(
    'daily-maize-purchases',
    '30 1 * * *',
    'CALL pr_refresh_purchases(CURRENT_DATE - 1);'
);

-- Test procedure manually
CALL pr_refresh_purchases(CURRENT_DATE);

-- Display daily purchases
SELECT * FROM daily_purchases;

-- Display scheduled jobs
SELECT * FROM cron.job;

-- Display job execution history
SELECT *
FROM cron.job_run_details
ORDER BY start_time DESC;