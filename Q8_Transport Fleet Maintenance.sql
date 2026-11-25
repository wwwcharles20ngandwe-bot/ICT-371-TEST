-- Create Vehicles table
CREATE TABLE vehicles (
    vehicle_id SERIAL PRIMARY KEY,
    registration VARCHAR(30) UNIQUE NOT NULL,
    current_odometer BIGINT NOT NULL
        CHECK (current_odometer >= 0),
    last_service_odometer BIGINT NOT NULL
        CHECK (
            last_service_odometer >= 0
            AND last_service_odometer <= current_odometer
        )
);

-- Create Trips table
CREATE TABLE trips (
    trip_id SERIAL PRIMARY KEY,
    vehicle_id INTEGER NOT NULL
        REFERENCES vehicles(vehicle_id),
    trip_on DATE NOT NULL,
    start_odometer BIGINT NOT NULL
        CHECK (start_odometer >= 0),
    end_odometer BIGINT NOT NULL
        CHECK (end_odometer >= 0)
);

-- Create Service Alerts table
CREATE TABLE service_alerts (
    vehicle_id INTEGER PRIMARY KEY
        REFERENCES vehicles(vehicle_id) ON DELETE CASCADE,
    km_since_service BIGINT NOT NULL
        CHECK (km_since_service >= 0),
    flagged_on DATE NOT NULL
);

-- Insert three vehicles
INSERT INTO vehicles (
    registration,
    current_odometer,
    last_service_odometer
)
VALUES
('BCA 1234', 12000, 8000),
('BCA 5678', 25000, 19000),
('BCA 9012', 50000, 45000);

-- Display vehicles
SELECT * FROM vehicles;

-- Display trips
SELECT * FROM trips;

-- Display service alerts
SELECT * FROM service_alerts;

CREATE OR REPLACE FUNCTION fn_service_due(
    p_vehicle_id INTEGER
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_odometer BIGINT;
    v_last_service_odometer BIGINT;
    v_km_since_service BIGINT;
BEGIN
    SELECT
        current_odometer,
        last_service_odometer
    INTO
        v_current_odometer,
        v_last_service_odometer
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Vehicle ID % does not exist', p_vehicle_id;
    END IF;

    v_km_since_service :=
        v_current_odometer - v_last_service_odometer;

    RETURN v_km_since_service >= 5000;
END;
$$;

-- Test vehicles
SELECT fn_service_due(1);

SELECT fn_service_due(2);

SELECT fn_service_due(3);

-- Test unknown vehicle
SELECT fn_service_due(99);

CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on DATE,
    p_start BIGINT,
    p_end BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Validate vehicle ID
    IF NOT EXISTS (
        SELECT 1
        FROM vehicles
        WHERE vehicle_id = p_vehicle_id
    ) THEN
        RAISE EXCEPTION
        'Vehicle ID % does not exist', p_vehicle_id;
    END IF;

    -- Validate trip date
    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date cannot be NULL';
    END IF;

    -- Validate odometer values
    IF p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Odometer values cannot be NULL';
    END IF;

    IF p_start < 0 OR p_end < 0 THEN
        RAISE EXCEPTION 'Odometer values cannot be negative';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION
        'End odometer must be greater than start odometer';
    END IF;

    -- Insert trip
    INSERT INTO trips (
        vehicle_id,
        trip_on,
        start_odometer,
        end_odometer
    )
    VALUES (
        p_vehicle_id,
        p_trip_on,
        p_start,
        p_end
    );

END;
$$;

-- Create trigger function
CREATE OR REPLACE FUNCTION fn_update_vehicle_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_odometer BIGINT;
BEGIN
    -- Lock and retrieve the vehicle's current odometer
    SELECT current_odometer
    INTO v_current_odometer
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Vehicle ID % does not exist', NEW.vehicle_id;
    END IF;

    -- Validate starting odometer
    IF NEW.start_odometer <> v_current_odometer THEN
        RAISE EXCEPTION
        'Trip start odometer must match vehicle current odometer. Current value: %',
        v_current_odometer;
    END IF;

    -- Validate mileage
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION
        'End odometer must be greater than start odometer';
    END IF;

    -- Update vehicle odometer exactly once
    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

-- Create BEFORE INSERT trigger
CREATE TRIGGER trg_update_vehicle_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_update_vehicle_odometer();

CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    current_odometer - last_service_odometer
        AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

-- Display vehicles due for service
SELECT * FROM v_service_due;

-- Create index for vehicle trips by date
CREATE INDEX idx_trips_vehicle_date
ON trips(vehicle_id, trip_on);

-- Query trips for one vehicle within a date range
SELECT
    trip_id,
    vehicle_id,
    trip_on,
    start_odometer,
    end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN
      CURRENT_DATE - 30 AND CURRENT_DATE;

-- Display execution plan
EXPLAIN
SELECT
    trip_id,
    vehicle_id,
    trip_on,
    start_odometer,
    end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN
      CURRENT_DATE - 30 AND CURRENT_DATE;

	  Index justification: The composite index on (vehicle_id, trip_on) supports searches for a particular vehicle's trips within a specified date range.

	  -- Create service alerts refresh procedure
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Insert or update alerts for vehicles due for service
    INSERT INTO service_alerts (
        vehicle_id,
        km_since_service,
        flagged_on
    )
    SELECT
        vehicle_id,
        current_odometer - last_service_odometer,
        CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000

    ON CONFLICT (vehicle_id)
    DO UPDATE SET
        km_since_service = EXCLUDED.km_since_service,
        flagged_on = EXCLUDED.flagged_on;

    -- Remove alerts for vehicles no longer due
    DELETE FROM service_alerts
    WHERE vehicle_id IN (
        SELECT vehicle_id
        FROM vehicles
        WHERE current_odometer - last_service_odometer < 5000
    );

END;
$$;

-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule every Monday at 06:00
SELECT cron.schedule(
    'weekly-service-alerts',
    '0 6 * * 1',
    'CALL pr_refresh_service_alerts();'
);

-- Test procedure manually
CALL pr_refresh_service_alerts();

-- Display service alerts
SELECT * FROM service_alerts;

-- Display vehicles due for service
SELECT * FROM v_service_due;

-- Inspect scheduled jobs
SELECT * FROM cron.job;

-- Inspect job execution history
SELECT *
FROM cron.job_run_details
ORDER BY start_time DESC;