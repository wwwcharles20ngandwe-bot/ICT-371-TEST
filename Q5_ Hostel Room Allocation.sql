-- Create Students table
CREATE TABLE students (
    student_id SERIAL PRIMARY KEY,
    student_number VARCHAR(30) UNIQUE NOT NULL,
    full_name VARCHAR(100) NOT NULL
);

-- Create Rooms table
CREATE TABLE rooms (
    room_id SERIAL PRIMARY KEY,
    room_number VARCHAR(20) UNIQUE NOT NULL,
    capacity INTEGER NOT NULL CHECK (capacity > 0)
);

-- Create Allocations table
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on DATE NOT NULL,
    released_on DATE,
    status VARCHAR(10) NOT NULL,

    CONSTRAINT chk_allocation_status
    CHECK (status IN ('ACTIVE', 'ENDED')),

    CONSTRAINT chk_release_date
    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR
        (status = 'ENDED' AND released_on IS NOT NULL)
    ),

    CONSTRAINT chk_allocation_dates
    CHECK (
        released_on IS NULL
        OR released_on >= allocated_on
    )
);

-- Create Occupancy Snapshot table
CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

-- Insert students
INSERT INTO students (student_number, full_name)
VALUES
('MU2024001', 'John Banda'),
('MU2024002', 'Mary Phiri'),
('MU2024003', 'Peter Zulu'),
('MU2024004', 'Grace Mwansa'),
('MU2024005', 'James Tembo'),
('MU2024006', 'Linda Phiri');

-- Insert rooms
INSERT INTO rooms (room_number, capacity)
VALUES
('A101', 2),
('A102', 3),
('A103', 2);

-- Insert allocations
INSERT INTO allocations
(student_id, room_id, allocated_on, released_on, status)
VALUES
(1, 1, CURRENT_DATE - 30, NULL, 'ACTIVE'),
(2, 1, CURRENT_DATE - 25, NULL, 'ACTIVE'),
(3, 2, CURRENT_DATE - 20, NULL, 'ACTIVE'),
(4, 2, CURRENT_DATE - 40, CURRENT_DATE - 10, 'ENDED');

-- Display students
SELECT * FROM students;

-- Display rooms
SELECT * FROM rooms;

-- Display allocations
SELECT * FROM allocations;

-- Display occupancy snapshots
SELECT * FROM occupancy_snapshot;

CREATE OR REPLACE FUNCTION fn_free_beds(
    p_room_id INTEGER
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    SELECT capacity
    INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room ID % does not exist', p_room_id;
    END IF;

    SELECT COUNT(*)
    INTO v_occupied
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_occupied;
END;
$$;

-- Test the function
SELECT fn_free_beds(1);

SELECT fn_free_beds(2);

SELECT fn_free_beds(3);

-- Test unknown room
SELECT fn_free_beds(99);

CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id INTEGER,
    p_room_id INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Validate student ID
    IF NOT EXISTS (
        SELECT 1
        FROM students
        WHERE student_id = p_student_id
    ) THEN
        RAISE EXCEPTION
        'Student ID % does not exist', p_student_id;
    END IF;

    -- Validate room ID
    IF NOT EXISTS (
        SELECT 1
        FROM rooms
        WHERE room_id = p_room_id
    ) THEN
        RAISE EXCEPTION
        'Room ID % does not exist', p_room_id;
    END IF;

    -- Validate allocation date
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date cannot be NULL';
    END IF;

    -- Check existing active allocation
    IF EXISTS (
        SELECT 1
        FROM allocations
        WHERE student_id = p_student_id
          AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION
        'Student already has an ACTIVE allocation';
    END IF;

    -- Check room availability
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION
        'Room % has no available beds', p_room_id;
    END IF;

    -- Create allocation
    INSERT INTO allocations (
        student_id,
        room_id,
        allocated_on,
        released_on,
        status
    )
    VALUES (
        p_student_id,
        p_room_id,
        p_allocated_on,
        NULL,
        'ACTIVE'
    );

END;
$$;

-- Test successful allocation
CALL pr_allocate_room(
    5,
    2,
    CURRENT_DATE
);

-- Display allocations
SELECT * FROM allocations;

-- Test student with existing ACTIVE allocation
CALL pr_allocate_room(
    1,
    3,
    CURRENT_DATE
);

-- Test full room
CALL pr_allocate_room(
    6,
    1,
    CURRENT_DATE
);

-- Test unknown student
CALL pr_allocate_room(
    99,
    3,
    CURRENT_DATE
);

-- Test unknown room
CALL pr_allocate_room(
    6,
    99,
    CURRENT_DATE
);

-- Create trigger function
CREATE OR REPLACE FUNCTION fn_check_room_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN

        -- Check whether student has another ACTIVE allocation
        IF EXISTS (
            SELECT 1
            FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND a.allocation_id <>
                  COALESCE(NEW.allocation_id, -1)
        ) THEN
            RAISE EXCEPTION
            'Student already has an ACTIVE allocation';
        END IF;

        -- Get room capacity
        SELECT capacity
        INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
            'Room ID % does not exist', NEW.room_id;
        END IF;

        -- Count other ACTIVE allocations
        SELECT COUNT(*)
        INTO v_occupied
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id <>
              COALESCE(NEW.allocation_id, -1);

        -- Check room capacity
        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION
            'Room % has reached its capacity', NEW.room_id;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

-- Create trigger function
CREATE OR REPLACE FUNCTION fn_check_room_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_occupied INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN

        -- Check whether student has another ACTIVE allocation
        IF EXISTS (
            SELECT 1
            FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND a.allocation_id <>
                  COALESCE(NEW.allocation_id, -1)
        ) THEN
            RAISE EXCEPTION
            'Student already has an ACTIVE allocation';
        END IF;

        -- Get room capacity
        SELECT capacity
        INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id;

        IF NOT FOUND THEN
            RAISE EXCEPTION
            'Room ID % does not exist', NEW.room_id;
        END IF;

        -- Count other ACTIVE allocations
        SELECT COUNT(*)
        INTO v_occupied
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id <>
              COALESCE(NEW.allocation_id, -1);

        -- Check room capacity
        IF v_occupied >= v_capacity THEN
            RAISE EXCEPTION
            'Room % has reached its capacity', NEW.room_id;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;

-- Create BEFORE INSERT OR UPDATE trigger
CREATE TRIGGER trg_check_room_allocation
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION fn_check_room_allocation();

-- Test valid direct insertion
INSERT INTO allocations (
    student_id,
    room_id,
    allocated_on,
    released_on,
    status
)
VALUES (
    6,
    3,
    CURRENT_DATE,
    NULL,
    'ACTIVE'
);

-- Test duplicate ACTIVE allocation for same student
INSERT INTO allocations (
    student_id,
    room_id,
    allocated_on,
    released_on,
    status
)
VALUES (
    1,
    3,
    CURRENT_DATE,
    NULL,
    'ACTIVE'
);

-- Test room capacity restriction
INSERT INTO allocations (
    student_id,
    room_id,
    allocated_on,
    released_on,
    status
)
VALUES (
    4,
    1,
    CURRENT_DATE,
    NULL,
    'ACTIVE'
);

-- Display allocations
SELECT * FROM allocations;

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_id,
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
    ON r.room_id = a.room_id
   AND a.status = 'ACTIVE'
GROUP BY
    r.room_id,
    r.room_number,
    r.capacity;

-- Display room occupancy
SELECT * FROM v_room_occupancy;

-- Create partial index for ACTIVE allocations
CREATE INDEX idx_allocations_active_room
ON allocations(room_id)
WHERE status = 'ACTIVE';

-- Matching query
SELECT
    allocation_id,
    student_id,
    room_id,
    allocated_on,
    status
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

-- Display execution plan
EXPLAIN
SELECT
    allocation_id,
    student_id,
    room_id,
    allocated_on,
    status
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

  Index justification: The partial index on room_id stores only ACTIVE allocations. It supports searches for active allocations belonging to a particular room and excludes ENDED allocations from the index.


  -- Create occupancy refresh procedure
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (
        snapshot_date,
        room_id,
        occupied_beds,
        free_beds
    )
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id),
        r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a
        ON r.room_id = a.room_id
       AND a.status = 'ACTIVE'
    GROUP BY
        r.room_id,
        r.capacity

    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds = EXCLUDED.free_beds;

END;
$$;

-- Enable pg_cron extension
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Schedule daily execution at 23:55
SELECT cron.schedule(
    'hostel-daily-occupancy',
    '55 23 * * *',
    'CALL pr_refresh_occupancy();'
);

-- Test procedure manually
CALL pr_refresh_occupancy();

-- Display occupancy snapshots
SELECT * FROM occupancy_snapshot
ORDER BY snapshot_date, room_id;

-- Display scheduled jobs
SELECT * FROM cron.job;