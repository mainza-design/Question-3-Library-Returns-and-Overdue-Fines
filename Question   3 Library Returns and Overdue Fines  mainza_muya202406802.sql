/* #####################################################################
   QUESTION 3 - Library Returns and Overdue Fines
   ##################################################################### */
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3, public;

-- (a) Tables ------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id          SERIAL PRIMARY KEY,
    loan_id           INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on   DATE NULL,
    new_returned_on   DATE NULL,
    changed_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- (b) Function ----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql STABLE AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;
    v_end := LEAST(p_as_of, COALESCE(v_ret, p_as_of));    -- returned loans stop accruing
    RETURN 2 * GREATEST(v_end - v_due, 0);                -- K2/day, never negative
END $$;

-- (c) Procedure ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_ret DATE; v_fine NUMERIC;
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_ret
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_ret IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_ret;
    END IF;
    IF p_returned_on IS NULL OR p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Invalid return date % (borrowed on %)', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);     -- final fine to the return date
    UPDATE loans SET returned_on = p_returned_on, fine_amount = v_fine   -- one statement
    WHERE loan_id = p_loan_id;
END $$;

-- (d) Trigger -----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;
END $$;

CREATE TRIGGER trg_loans_returned_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- (a) continued: seed data ----------------------------------------------
INSERT INTO books (title) VALUES
 ('Database System Concepts'), ('Introduction to Algorithms'), ('Clean Code');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Alice Mulenga',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue
 (2, 'Brian Tembo',    CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 2 open, on time
 (3, 'Chanda Zulu',    CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 3 to be returned late
 (1, 'Dorothy Kunda',  CURRENT_DATE - 20, CURRENT_DATE - 10),  -- 4 open, overdue
 (2, 'Evans Mwale',    CURRENT_DATE - 15, CURRENT_DATE - 5),   -- 5 to be returned on time
 (3, 'Faith Lungu',    CURRENT_DATE - 3,  CURRENT_DATE + 11);  -- 6 open, on time

CALL pr_return_loan(3, CURRENT_DATE - 20);   -- 6 days late  -> K12
CALL pr_return_loan(5, CURRENT_DATE - 7);    -- early        -> K0

SELECT loan_id, returned_on, fine_amount FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;
SELECT fn_loan_fine(1, CURRENT_DATE) AS open_overdue_fine;   -- 16 days * 2 = 32

-- (e) View --------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id, b.title, l.borrower_name, l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;

-- (f) Index -------------------------------------------------------------
-- Partial index: holds only unreturned loans (a small fraction of history), so it
-- is small, cheap to maintain and exactly matches the search predicate.
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job -----------------------------------------------------
-- "Unreturned as of p_as_of" = borrowed on/before that date and not yet returned by it.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE) LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;

SELECT cron.schedule('q3_refresh_overdue', '10 0 * * *',
       $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$);

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);                   -- rerun replaces same date
SELECT * FROM overdue_summary;
