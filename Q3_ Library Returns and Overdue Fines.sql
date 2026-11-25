
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL
);


CREATE TABLE loans (
    loan_id SERIAL PRIMARY KEY,

    book_id INTEGER NOT NULL,

    borrower_name VARCHAR(100) NOT NULL,

    borrowed_on DATE NOT NULL,

    due_on DATE NOT NULL,

    returned_on DATE DEFAULT NULL,

    fine_amount NUMERIC(10,2) NOT NULL DEFAULT 0,

    CONSTRAINT fk_loans_books
        FOREIGN KEY (book_id)
        REFERENCES books(book_id),

    CONSTRAINT chk_due_date
        CHECK (due_on >= borrowed_on),

    CONSTRAINT chk_fine_amount
        CHECK (fine_amount >= 0),

    CONSTRAINT chk_return_date
        CHECK (
            returned_on IS NULL
            OR returned_on >= borrowed_on
        )
);


CREATE TABLE loan_audit (
    audit_id SERIAL PRIMARY KEY,

    loan_id INTEGER NOT NULL,

    old_returned_on DATE DEFAULT NULL,

    new_returned_on DATE DEFAULT NULL,

    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_audit_loan
        FOREIGN KEY (loan_id)
        REFERENCES loans(loan_id)
);


CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,

    overdue_count INTEGER NOT NULL DEFAULT 0,

    total_fine NUMERIC(12,2) NOT NULL DEFAULT 0
);


INSERT INTO books (title)
VALUES
('Database Management Systems'),
('Computer Networks'),
('Operating Systems');


CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INTEGER,
    p_as_of DATE
)
RETURNS NUMERIC(10,2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on DATE;
    v_returned_on DATE;
    v_effective_date DATE;
    v_overdue_days INTEGER;
BEGIN

    -- Check the loan and retrieve its dates
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    -- Reject an unknown loan
    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Loan ID % does not exist',
        p_loan_id;
    END IF;

    -- Validate the calculation date
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION
        'Calculation date cannot be NULL';
    END IF;

    -- Determine the effective date
    IF v_returned_on IS NOT NULL THEN
        v_effective_date :=
            LEAST(p_as_of, v_returned_on);
    ELSE
        v_effective_date := p_as_of;
    END IF;

    -- Calculate overdue days
    v_overdue_days :=
        GREATEST(v_effective_date - v_due_on, 0);

    -- Return the fine
    RETURN v_overdue_days * 2;

END;
$$;


CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id INTEGER,
    p_returned_on DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_existing_return DATE;
BEGIN

    -- Validate return date
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION
        'Return date cannot be NULL';
    END IF;

    -- Retrieve and lock the loan
    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_existing_return
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    -- Reject unknown loan
    IF NOT FOUND THEN
        RAISE EXCEPTION
        'Loan ID % does not exist',
        p_loan_id;
    END IF;

    -- Reject an already returned loan
    IF v_existing_return IS NOT NULL THEN
        RAISE EXCEPTION
        'Loan ID % has already been returned',
        p_loan_id;
    END IF;

    -- Reject a return before borrowing
    IF p_returned_on < v_borrowed_on THEN
        RAISE EXCEPTION
        'Return date cannot be before borrowed date';
    END IF;

    -- Store the return date
    UPDATE loans
    SET returned_on = p_returned_on
    WHERE loan_id = p_loan_id;

    -- Calculate and store the final fine
    UPDATE loans
    SET fine_amount =
        fn_loan_fine(p_loan_id, p_returned_on)
    WHERE loan_id = p_loan_id;

END;
$$;


CREATE OR REPLACE FUNCTION fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    -- Check whether the return date changed
    IF OLD.returned_on IS DISTINCT FROM
       NEW.returned_on THEN

        INSERT INTO loan_audit (
            loan_id,
            old_returned_on,
            new_returned_on,
            changed_at
        )
        VALUES (
            NEW.loan_id,
            OLD.returned_on,
            NEW.returned_on,
            CURRENT_TIMESTAMP
        );

    END IF;

    RETURN NEW;

END;
$$;


CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE)
        AS fine_as_of_today
FROM loans l
INNER JOIN books b
    ON l.book_id = b.book_id
WHERE
    l.returned_on IS NULL
    AND l.due_on < CURRENT_DATE;

	
CREATE INDEX idx_loans_unreturned_book
ON loans (book_id)
WHERE returned_on IS NULL;


SELECT
    loan_id,
    book_id,
    borrower_name,
    borrowed_on,
    due_on,
    returned_on
FROM loans
WHERE book_id = 2
AND returned_on IS NULL;


EXPLAIN
SELECT
    loan_id,
    book_id,
    borrower_name,
    borrowed_on,
    due_on,
    returned_on
FROM loans
WHERE book_id = 2
AND returned_on IS NULL;


CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Validate the date
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION
        'Snapshot date cannot be NULL';
    END IF;

    -- Calculate and store the overdue summary
    INSERT INTO overdue_summary (
        snapshot_date,
        overdue_count,
        total_fine
    )
    SELECT
        p_as_of,
        COUNT(l.loan_id),
        COALESCE(
            SUM(
                fn_loan_fine(l.loan_id, p_as_of)
            ),
            0
        )
    FROM loans l
    WHERE
        l.returned_on IS NULL
        AND l.due_on < p_as_of

    -- Replace an existing daily summary
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine = EXCLUDED.total_fine;

END;
$$;