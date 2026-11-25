-- Create Patients table
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

-- Create Doctors table
CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

-- Create Appointments table
CREATE TABLE appointments (
    appointment_id SERIAL PRIMARY KEY,
    patient_id INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'BOOKED',

    CONSTRAINT chk_appointment_slot
        CHECK (slot_time IN (
            '09:00:00',
            '10:00:00',
            '11:00:00',
            '12:00:00'
        )),

    CONSTRAINT chk_appointment_status
        CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

-- Create Clinic Summary table
CREATE TABLE clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INTEGER NOT NULL,
    attended_count INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

-- Insert three patients
INSERT INTO patients (full_name)
VALUES
('John Banda'),
('Mary Phiri'),
('Peter Zulu');

-- Insert three doctors
INSERT INTO doctors (full_name)
VALUES
('Dr. James Mwansa'),
('Dr. Grace Chanda'),
('Dr. David Zulu');

-- Insert six appointments
INSERT INTO appointments
(patient_id, doctor_id, appointment_day, slot_time, status)
VALUES
(1, 1, CURRENT_DATE, '09:00', 'BOOKED'),
(2, 1, CURRENT_DATE, '10:00', 'ATTENDED'),
(3, 2, CURRENT_DATE, '09:00', 'BOOKED'),
(1, 2, CURRENT_DATE, '11:00', 'CANCELLED'),
(2, 3, CURRENT_DATE, '10:00', 'BOOKED'),
(3, 3, CURRENT_DATE, '12:00', 'ATTENDED');

-- Display patients
SELECT * FROM patients;

-- Display doctors
SELECT * FROM doctors;

-- Display appointments
SELECT * FROM appointments;

-- Display clinic summary
SELECT * FROM clinic_summary;

CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INTEGER,
    p_day DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_total INTEGER;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM doctors
        WHERE doctor_id = p_doctor_id
    ) THEN
        RAISE EXCEPTION 'Doctor ID % does not exist', p_doctor_id;
    END IF;

    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Appointment date cannot be NULL';
    END IF;

    SELECT COUNT(*)
    INTO v_total
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_total;
END;
$$;

-- Test the function
SELECT fn_daily_load(1, CURRENT_DATE);

SELECT fn_daily_load(2, CURRENT_DATE);

SELECT fn_daily_load(3, CURRENT_DATE);

-- Test a doctor with no bookings
SELECT fn_daily_load(1, CURRENT_DATE + 1);

-- Test an unknown doctor
SELECT fn_daily_load(99, CURRENT_DATE);

CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id INTEGER,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Validate patient ID
    IF NOT EXISTS (
        SELECT 1
        FROM patients
        WHERE patient_id = p_patient_id
    ) THEN
        RAISE EXCEPTION 'Patient ID % does not exist', p_patient_id;
    END IF;

    -- Validate doctor ID
    IF NOT EXISTS (
        SELECT 1
        FROM doctors
        WHERE doctor_id = p_doctor_id
    ) THEN
        RAISE EXCEPTION 'Doctor ID % does not exist', p_doctor_id;
    END IF;

    -- Validate appointment date
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Appointment date cannot be NULL';
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date cannot be in the past';
    END IF;

    -- Validate appointment slot
    IF p_slot IS NULL OR p_slot NOT IN (
        TIME '09:00',
        TIME '10:00',
        TIME '11:00',
        TIME '12:00'
    ) THEN
        RAISE EXCEPTION 'Unsupported appointment slot';
    END IF;

    -- Insert appointment
    INSERT INTO appointments (
        patient_id,
        doctor_id,
        appointment_day,
        slot_time,
        status
    )
    VALUES (
        p_patient_id,
        p_doctor_id,
        p_day,
        p_slot,
        'BOOKED'
    );

END;
$$;

-- Test successful booking
CALL pr_book_appointment(
    1,
    1,
    CURRENT_DATE + 1,
    '09:00'
);

-- Display appointments
SELECT * FROM appointments;

-- Test invalid patient
CALL pr_book_appointment(
    99,
    1,
    CURRENT_DATE + 1,
    '10:00'
);

-- Test invalid doctor
CALL pr_book_appointment(
    1,
    99,
    CURRENT_DATE + 1,
    '10:00'
);

-- Test past date
CALL pr_book_appointment(
    1,
    1,
    CURRENT_DATE - 1,
    '11:00'
);

-- Test unsupported slot
CALL pr_book_appointment(
    1,
    1,
    CURRENT_DATE + 1,
    '13:00'
);

-- Create trigger function
CREATE OR REPLACE FUNCTION fn_check_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN

        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time = NEW.slot_time
              AND a.status <> 'CANCELLED'
              AND a.appointment_id <> COALESCE(
                  NEW.appointment_id,
                  -1
              )
        ) THEN
            RAISE EXCEPTION
            'Appointment clash: doctor already has an appointment on this date and slot';
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

-- Create BEFORE INSERT OR UPDATE trigger
CREATE TRIGGER trg_check_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION fn_check_appointment_clash();

-- Test a valid appointment
INSERT INTO appointments (
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
)
VALUES (
    3,
    1,
    CURRENT_DATE + 2,
    '09:00',
    'BOOKED'
);

-- Test appointment clash
INSERT INTO appointments (
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
)
VALUES (
    2,
    1,
    CURRENT_DATE + 2,
    '09:00',
    'BOOKED'
);

-- Test updating an appointment to a conflicting slot
UPDATE appointments
SET slot_time = '09:00'
WHERE appointment_id = 2;

-- Display appointments
SELECT * FROM appointments;

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p
    ON a.patient_id = p.patient_id
JOIN doctors d
    ON a.doctor_id = d.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

-- Display today's appointments
SELECT * FROM v_today_appointments;

-- Create non-unique index
CREATE INDEX idx_appointments_day_doctor
ON appointments(appointment_day, doctor_id);

Index justification: The non-unique composite index on (appointment_day, doctor_id) supports searches that filter appointments by date and doctor. It allows multiple appointments to share the same indexed values where other columns differ.
-- Query appointments by date and doctor
SELECT
    appointment_id,
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

-- Display execution plan
EXPLAIN
SELECT
    appointment_id,
    patient_id,
    doctor_id,
    appointment_day,
    slot_time,
    status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1

  -- Create procedure to refresh clinic summary
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Summary date cannot be NULL';
    END IF;

    INSERT INTO clinic_summary (
        summary_date,
        booked_count,
        attended_count,
        cancelled_count
    )
    SELECT
        p_day,

        COUNT(*) FILTER (
            WHERE status = 'BOOKED'
        ),

        COUNT(*) FILTER (
            WHERE status = 'ATTENDED'
        ),

        COUNT(*) FILTER (
            WHERE status = 'CANCELLED'
        )

    FROM appointments
    WHERE appointment_day = p_day

    ON CONFLICT (summary_date)
    DO UPDATE SET
        booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;

END;
$$;

-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule daily execution at 01:00
SELECT cron.schedule(
    'clinic-daily-summary',
    '0 1 * * *',
    'CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);'
);

-- Test the procedure manually for the previous day
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);

-- Display clinic summary
SELECT * FROM clinic_summary;

-- Display scheduled jobs
SELECT * FROM cron.job;

  