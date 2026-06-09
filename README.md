# order-recon

Data validation and reconciliation in T-SQL, run against the real
[Olist Brazilian e-commerce dataset](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce):
about 100K orders from 2016-2018, with items, payments, reviews, customers, sellers and
geolocation. Everything that does real work is T-SQL. The only other files are Docker setup
and a shell script that runs the scripts in order.

The data is treated as three systems that are supposed to agree:

- `oms`: the order platform (orders, items, reviews, customers, sellers, products)
- `pay`: the payment processor (one row per payment, and an order can have several)
- `fin`: a finance ledger. Olist has no finance data, so `04` builds one from `pay` the way
  a nightly ingest would, posted in UTC. The reconciliation procs then prove that ingest is
  complete and correct.

The Olist tables are loaded exactly as published, and every issue the checks report is real.

## Running it

Needs Docker (OrbStack works).

```
./run_all.sh
```

On the first run it downloads the dataset from Kaggle's public endpoint (about 45MB, no
login needed) into `data/olist/`. It then starts SQL Server 2022, waits until it's ready,
and runs `sql/00` through `sql/11` in order. The database is rebuilt from scratch every
time, and a full run takes about 30 seconds.

Connect with any client at `localhost,1433`, user `sa`, password `Recon_local_2026`
(override with `SA_PASSWORD` / `SQL_PORT`).

| script | what |
|---|---|
| 00 | database |
| 01 | `raw` schema: BULK INSERT of all 9 CSVs as text |
| 02 | typed tables with PKs/FKs, plus the qa, etl and fin tables |
| 03 | raw to typed with TRY_CONVERT, then source vs target row count audit |
| 04 | `etl.usp_LoadFinLedger`: builds the finance ledger, converting to UTC |
| 05 | `qa.usp_RunDataQualityChecks` |
| 06 | `qa.usp_ReconcileDaily` |
| 07 | `qa.usp_ReconcileRecordLevel` |
| 08 | `qa.usp_RunAll` |
| 09 | `stg.OrderUpdate`, `etl.usp_ApplyOrderUpdates`, staged batch 1 |
| 10 | runs the qa suite |
| 11 | applies the ETL batch and validates it |

The procs also work ad hoc. Without `@RunID` they return rows instead of logging them:

```sql
EXEC qa.usp_ReconcileDaily @FromDate = '2017-11-20', @ToDate = '2017-11-30';
EXEC qa.usp_ReconcileRecordLevel;
```

## Loading notes

These came up while loading and are worth knowing for any CSV import into SQL Server on Linux:

- BULK INSERT on Linux has no `CODEPAGE` option. The raw columns are `VARCHAR` with a
  `_UTF8` collation, so the bytes land unchanged and the Portuguese text in reviews
  survives. Joins from `raw` to typed tables need `COLLATE DATABASE_DEFAULT`.
- The reviews file and the category translation file use CRLF line endings, and the other
  seven use LF. Using the wrong terminator on reviews gives a misleading error:
  `Cannot obtain the required interface ("IID_IColumnsInfo")`.
- About 3,850 review comments have line breaks inside quoted fields. `FORMAT = 'CSV'`
  handles them, and a naive line count of the file (104,720) overstates the real row
  count (99,224).
- The source spells two column names `product_name_lenght`. They are kept in `raw` and
  fixed in `oms.Product`.

`etl.LoadAudit` compares source and target row counts for every table. All of them match,
and no value fails type conversion.

## Real issues in the data

These are the data-quality problems the checks find in the published dataset. Most of them
are also noted in community write-ups on Olist, for example
[this preprocessing deep-dive](https://pavelgrigoryevds.github.io/olist-deep-dive/contents/02_data_preprocessing/09_intermediate_conclusion.html)
and [this project's geolocation cleanup](https://github.com/bsdr18/Predictive-Analytics-for-Sales-and-Marketing).

| check | rows | notes |
|---|---|---|
| `oms_order_without_items` | 8 | 775 orders have no items, but 767 of them are canceled/unavailable, which is expected. The check excludes those. The 8 it flags are created/shipped/invoiced with nothing in them. |
| `pay_order_without_payment` | 1 | one order the processor has no record of |
| `oms_delivered_without_delivery_date` | 8 | status says delivered, but there is no delivery timestamp |
| `oms_canceled_but_delivered` | 6 | canceled orders with a customer delivery date |
| `oms_order_timeline_out_of_order` | 1,382 | mostly handed to the carrier before the payment approval timestamp (1,359), plus 23 delivered before they were shipped |
| `pay_zero_installments` | 2 | credit card payments with 0 installments |
| `pay_type_not_defined` | 3 | payment type `not_defined` |
| `pay_total_vs_items_over_1brl` | 249 | paid amount vs items + freight differs by more than R$1. 232 paid more (card installment interest) and 17 paid less |
| `oms_review_id_on_many_orders` | 789 | the same review_id attached to several orders, which is why the review PK is (ReviewID, OrderID) |
| `oms_order_with_many_reviews` | 547 | customers updating their review |
| `oms_product_without_category` | 610 | NULL category |
| `oms_category_without_translation` | 2 | `pc_gamer` and `portateis_cozinha_e_preparadores_de_alimentos` aren't in the translation table, so there's no FK there |
| `ref_geolocation_exact_duplicate` | 261,831 | exact duplicate rows out of 1,000,163. Zip prefix alone is not a key |
| `oms_customer_zip_not_in_geo` | 278 | customer zip prefix missing from geolocation |
| `oms_seller_zip_not_in_geo` | 7 | same for sellers |
| `fin_booked_in_next_month` | 407 | see below |

`customer_unique_id` mapping to several `customer_id`s (2,997 people) is not flagged.
Olist issues a new customer_id per order by design.

**Month-end cutoff.** Olist timestamps are São Paulo local time and the ledger posts in UTC.
An order placed late on the last day of a month lands in the next month in UTC, and that
affects 407 real orders. Brazil still had daylight saving time in 2016-2018, so the cutoff
moves: orders after 22:00 in January 2017 (UTC-2) and after 21:00 in other months (UTC-3).
`AT TIME ZONE 'E. South America Standard Time'` applies the historical rules. The daily
recon converts back to local time before comparing, so these orders match there, and
only the cutoff check reports them.

## How the reconciliation works

**Daily** (`usp_ReconcileDaily`): builds two aggregated CTEs at day / payment type grain,
one from `pay` and one from `fin` (UTC converted back to local), and joins them with a
FULL OUTER JOIN, so a day that exists on only one side still shows up. Counts must match
exactly. Amounts can differ by `@TolerancePct` (a percent, so 0.01 means 0.01%). Counts
are strict so that a small double post can't hide inside the amount tolerance.

**Record level** (`usp_ReconcileRecordLevel`): one row per payment (order + sequence) on each
side. EXCEPT runs in both directions on the key to find missing and extra records. On
matched keys, `HASHBYTES('SHA2_256', CONCAT_WS('|', ...))` of the remaining columns finds
changed amounts. The ledger is summed to the payment grain first, because EXCEPT is
distinct and a duplicate row would otherwise disappear.

On the published data both recon procs come back clean: every processor payment is in the
ledger once, with the same type and amount, on the same local business day. That is the
expected result for a correct ingest. Edit or delete a few `fin.LedgerEntry` rows and rerun
`10_run_qa.sql` to see them get flagged.

**`usp_RunAll`** inserts the run row before opening the transaction, runs everything in
TRY/CATCH, and on failure rolls back and records the error on the run row.

## Sample output

```
run 1: 26 checks, 16 failed (high 3, medium 5, low 8)
high failures:
  oms_order_without_items (8)
  pay_order_without_payment (1)
  oms_delivered_without_delivery_date (8)
```

The 10 passing checks are the ledger and recon checks plus two guards (no ledger rows for
unknown orders, no items with a zero or negative price). Each row in `qa.ValidationResult`
also carries up to 10 sample IDs (via STRING_AGG) to start an investigation from.

## Incremental load

`stg.OrderUpdate` holds a delta batch: 20 shipped orders that are now delivered, 10 new
orders, and 5 unavailable orders deleted upstream. `etl.usp_ApplyOrderUpdates` applies it
with one MERGE, writing `$action` into `etl.OrderMergeLog` via OUTPUT. It then compares
staged counts against logged actions. If they differ (an insert for an existing order, an
update for a missing one, an update that changes nothing), it throws and rolls back the
whole batch:

```
MergeAction Staged Applied Result
DELETE      5      5       OK
INSERT      10     10      OK
UPDATE      20     20      OK
```

The MERGE has no `WHEN NOT MATCHED BY SOURCE` on purpose. Staging is a delta, so that
clause would delete every order not in the batch.

## ANSI-89 vs ANSI-92

`sql/legacy/old_monthly_revenue.sql` is a comma-join report:
`FROM oms.Orders o, oms.OrderItem oi, pay.Payment p WHERE ...`. Items and payments are both
children of orders, and nothing relates an item row to a payment row. An order with 3 items
and 2 payments becomes 6 rows, so each item is counted twice and each payment three times.
`COUNT(DISTINCT)` keeps the order count right, which is why the report looks fine.

`monthly_revenue_fixed.sql` aggregates each child to one row per order before joining, and
uses explicit INNER JOIN for items and LEFT JOIN for payments. Delivered orders, Jan 2017 to Aug 2018:

```
                 old             fixed
orders           96,230          96,230
product revenue  13,774,556.19   13,183,270.29   (+4.5%)
freight           2,294,068.30    2,192,419.18   (+4.6%)
paid             19,716,963.34   15,378,444.90   (+28.2%)
```

Paid is inflated much more because multi-item orders get multiplied, and every order paid
with voucher + card is already split into two payment rows.

These two reports aren't part of `run_all.sh`. Run them against the built database.
