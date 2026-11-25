-- Create Students table
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

-- Create Applications table
CREATE TABLE applications (
    application_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL
        REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL
        CHECK (age_at_application > 0),
    monthly_income NUMERIC(12,2) NOT NULL
        CHECK (monthly_income >= 0),
    average_mark NUMERIC(5,2) NOT NULL
        CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on DATE NOT NULL,
    status VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

-- Create Decision Audit table
CREATE TABLE decision_audit (
    audit_id SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL
        REFERENCES applications(application_id),
    old_status VARCHAR(10) NOT NULL,
    new_status VARCHAR(10) NOT NULL,
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Insert students
INSERT INTO students (student_number, full_name)
VALUES
('MU2024001', 'John Banda'),
('MU2024002', 'Mary Phiri'),
('MU2024003', 'Peter Zulu');

-- Insert six PENDING applications
INSERT INTO applications (
    student_id,
    age_at_application,
    monthly_income,
    average_mark,
    submitted_on,
    status
)
VALUES
-- Qualifies
(1, 20, 2500, 75, CURRENT_DATE - 6, 'PENDING'),

-- Does not qualify: age below 18
(1, 17, 2000, 80, CURRENT_DATE - 5, 'PENDING'),

-- Does not qualify: income above K3,000
(2, 22, 3500, 85, CURRENT_DATE - 4, 'PENDING'),

-- Does not qualify: average mark below 70
(2, 24, 2500, 65, CURRENT_DATE - 3, 'PENDING'),

-- Boundary case: age 18, income K3,000, mark 70
(3, 18, 3000, 70, CURRENT_DATE - 2, 'PENDING'),

-- Boundary case: age 25, income K3,000, mark 100
(3, 25, 3000, 100, CURRENT_DATE - 1, 'PENDING');

-- Display students
SELECT * FROM students;

-- Display applications
SELECT * FROM applications;

-- Display decision audit
SELECT * FROM decision_audit;

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age INTEGER,
    p_income NUMERIC,
    p_mark NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    -- Reject NULL inputs
    IF p_age IS NULL
       OR p_income IS NULL
       OR p_mark IS NULL THEN
        RAISE EXCEPTION
        'Age, income and average mark cannot be NULL';
    END IF;

    -- Validate age
    IF p_age <= 0 THEN
        RAISE EXCEPTION
        'Age must be greater than zero';
    END IF;

    -- Validate income
    IF p_income < 0 THEN
        RAISE EXCEPTION
        'Monthly income cannot be negative';
    END IF;

    -- Validate average mark
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION
        'Average mark must be between 0 and 100';
    END IF;

    -- Apply scholarship eligibility rules
    RETURN (
        p_age BETWEEN 18 AND 25
        AND p_income <= 3000
        AND p_mark >= 70
    );

END;
$$;

-- Test qualifying applicant
SELECT fn_scholarship_eligible(20, 2500, 75);

-- Test age below 18
SELECT fn_scholarship_eligible(17, 2000, 80);

-- Test income above K3,000
SELECT fn_scholarship_eligible(22, 3500, 85);

-- Test mark below 70
SELECT fn_scholarship_eligible(24, 2500, 65);

-- Test lower boundary
SELECT fn_scholarship_eligible(18, 3000, 70);

-- Test upper age boundary
SELECT fn_scholarship_eligible(25, 3000, 100);

-- Test invalid age
SELECT fn_scholarship_eligible(0, 2000, 80);

-- Test invalid income
SELECT fn_scholarship_eligible(20, -500, 80);

-- Test invalid mark
SELECT fn_scholarship_eligible(20, 2000, 101);

CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INTEGER
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age INTEGER;
    v_income NUMERIC(12,2);
    v_mark NUMERIC(5,2);
    v_status VARCHAR(10);
    v_eligible BOOLEAN;
BEGIN
    -- Retrieve and lock application
    SELECT
        age_at_application,
        monthly_income,
        average_mark,
        status
    INTO
        v_age,
        v_income,
        v_mark,
        v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    -- Check application existence
    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Application ID % does not exist',
        p_application_id;
    END IF;

    -- Check application status
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION
        'Application ID % has already been assessed. Current status: %',
        p_application_id,
        v_status;
    END IF;

    -- Call eligibility function
    v_eligible := fn_scholarship_eligible(
        v_age,
        v_income,
        v_mark
    );

    -- Update application status
    IF v_eligible THEN
        UPDATE applications
        SET status = 'APPROVED'
        WHERE application_id = p_application_id;
    ELSE
        UPDATE applications
        SET status = 'REJECTED'
        WHERE application_id = p_application_id;
    END IF;

END;
$$;

-- Test assessment of application 1
CALL pr_assess_application(1);

-- Test assessment of application 2
CALL pr_assess_application(2);

-- Test assessment of application 3
CALL pr_assess_application(3);

-- Test assessment of application 4
CALL pr_assess_application(4);

-- Test assessment of application 5
CALL pr_assess_application(5);

-- Test assessment of application 6
CALL pr_assess_application(6);

-- Display assessed applications
SELECT * FROM applications
ORDER BY application_id;

-- Test unknown application
CALL pr_assess_application(99);

-- Test already assessed application
CALL pr_assess_application(1);

-- Create trigger function
CREATE OR REPLACE FUNCTION fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Record only actual status changes
    IF OLD.status IS DISTINCT FROM NEW.status THEN

        INSERT INTO decision_audit (
            application_id,
            old_status,
            new_status,
            changed_at
        )
        VALUES (
            NEW.application_id,
            OLD.status,
            NEW.status,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;
END;
$$;

-- Create AFTER UPDATE trigger
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION fn_decision_audit();

-- Test actual status change on a pending application
UPDATE applications
SET status = 'APPROVED'
WHERE application_id = 1
  AND status = 'PENDING';

-- Test unchanged status
UPDATE applications
SET status = 'APPROVED'
WHERE application_id = 1;

-- Display decision audit records
SELECT * FROM decision_audit;

-- Display applications
SELECT * FROM applications;

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s
    ON a.student_id = s.student_id
WHERE a.status = 'APPROVED';

-- Display approved applicants
SELECT * FROM v_approved_applicants;

-- Create composite index
CREATE INDEX idx_applications_status_date
ON applications(status, submitted_on);

-- Query applications by status and submission date
SELECT
    application_id,
    student_id,
    age_at_application,
    average_mark,
    submitted_on,
    status
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN
      CURRENT_DATE - 30 AND CURRENT_DATE;

-- Display execution plan
EXPLAIN
SELECT
    application_id,
    student_id,
    age_at_application,
    average_mark,
    submitted_on,
    status
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN
      CURRENT_DATE - 30 AND CURRENT_DATE;

	  Index justification: The composite index on (status, submitted_on) supports searches that filter scholarship applications by their status and a specified submission date range.

	  -- Create procedure to assess all pending applications
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    v_application RECORD;
BEGIN
    -- Loop through pending applications only
    FOR v_application IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP

        -- Assess each pending application
        CALL pr_assess_application(
            v_application.application_id
        );

    END LOOP;

END;
$$;

-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule every Monday at 08:00
SELECT cron.schedule(
    'weekly-scholarship-assessment',
    '0 8 * * 1',
    'CALL pr_assess_pending();'
);

-- Test procedure manually
CALL pr_assess_pending();

-- Display all applications
SELECT * FROM applications
ORDER BY application_id;

-- Display decision audit
SELECT * FROM decision_audit
ORDER BY audit_id;

-- Inspect scheduled jobs
SELECT * FROM cron.job;

-- Inspect job execution history
SELECT *
FROM cron.job_run_details
ORDER BY start_time DESC;

-- Test rerun
CALL pr_assess_pending();

-- Confirm audit records were not duplicated
SELECT * FROM decision_audit
ORDER BY audit_id;