# Question-3-Library-Returns-and-Overdue-Fines
# Q3 – Library Returns and Overdue Fines (schema `q3`)

**Purpose:** charge K2 per day after the due date; a return on the due date costs nothing and a returned loan stops accruing fines.

## Objects
| Part | Object | What it does |
|---|---|---|
| (a) | `books`, `loans`, `loan_audit`, `overdue_summary` | `CHECK (due_on >= borrowed_on)`; 3 books, 6 loans (open overdue, on-time, returned) |
| (b) | `fn_loan_fine(id, as_of)` | `2 × GREATEST(LEAST(as_of, returned_on) − due_on, 0)`; rejects unknown loan |
| (c) | `pr_return_loan(id, date)` | rejects unknown/already-returned loans and returns before `borrowed_on`; sets `returned_on` and final `fine_amount` in one UPDATE |
| (d) | `trg_loans_returned_audit` | AFTER UPDATE, `WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)` |
| (e) | `v_overdue_loans` | unreturned loans due before today, with title, borrower, due date, fine as of today |
| (f) | `idx_loans_book_unreturned` | partial index on `book_id WHERE returned_on IS NULL` |
| (g) | `pr_refresh_overdue(as_of)` + job `q3_refresh_overdue` | upsert on `snapshot_date`; cron `10 0 * * *` for `CURRENT_DATE` |

## Note
"Unreturned as of a date" is read literally (borrowed on/before the date and not returned by it); non-overdue loans add K0 to the total.
