# Keeping the figures, deleting the paperwork

How old data is compressed so the analytics keep working and the customer
records do not pile up for ever.

## Why this exists

Not because the database is full. This workshop books roughly 40 jobs and 200
enquiries a year, and Postgres would not notice a century of that. The three
real reasons:

1. **The law.** Enquiries hold names, addresses, phone numbers and email
   addresses. Keeping them indefinitely is the part UK GDPR objects to, and
   "we need it for our statistics" is not a defence once you can show the
   statistics do not need the names.
2. **The schedule was carrying history it never drew.** Every load fetched
   every job ever recorded, including work finished two years ago.
3. **Deleting detail used to mean deleting the trend.** Every figure was
   computed from live records, so a purge would have taken the charts with it.
   That is why firms end up never deleting anything.

## The idea

Work out each month's figures **once, while the detail is still there**, and
keep those. A month of trading becomes one row of counts, sums and medians with
no personal data in it at all. Twenty years is about 240 rows.

The records behind it can then be deleted on a schedule without a single figure
disappearing from the dashboard.

## The three steps

| Step | What it does | When |
| --- | --- | --- |
| **Roll up** | Writes the month's figures into `fact_month` | Any time. Re-runs safely while a month is still settling |
| **Seal** | Declares the month final. The charts read the stored row from here on and stop recomputing it | After 13 months by default |
| **Purge** | Deletes the enquiry and job records for that month | After 24 months by default, **and only when someone asks** |

Sealing and purging are deliberately separate. Sealing freezes a month, which is
only right once everything from it has been decided. Thirteen months rather than
twelve gives a margin, so the figure someone reads for last September is the
same figure they read in March.

## Running it

Rolling up and sealing is safe and meant to be routine:

```sql
select * from public.archive_months();
```

Seeing what is held:

```sql
select * from public.v_archive_status;
```

`state` reads `open`, `sealed`, or `figures only`. The last column says how many
enquiry records are still held for that month.

Deleting the personal data, which nothing does on its own:

```sql
select * from public.purge_detail_before();
```

It only touches months that are sealed and past the retention window. It will
not delete a job that is unfinished, whatever its age, nor an enquiry that still
has live work attached.

## Changing the windows

```sql
update public.analytics_retention
   set seal_after_months = 13,
       purge_detail_after_months = 24;
```

The database refuses a purge window shorter than the sealing window, because
that would delete the detail before the figures had been taken from it.

> **The numbers are Harry's decision, not a technical one.** How long a joinery
> firm should keep an unsuccessful enquirer's details is a business and legal
> question. The defaults here are deliberately cautious and nothing is ever
> deleted automatically. Worth a short conversation with whoever advises the
> business on data protection before the first purge is run.

## What survives a purge, and what does not

**Kept for good, per month:** enquiries received, and how many reached each
stage; quoted, won and lost values; the typical days from enquiry to decision
and the other cycle-time medians; jobs completed, how many hit the promised date
and the median days out; committed and available job-days. Plus the breakdowns
by source, by product and by reason lost.

**Deleted:** customer names, contact names, phone numbers, email addresses, site
addresses, notes, and the individual enquiry and job records themselves.

**Cannot be recovered afterwards:** anything not in that first list. A median in
particular cannot be rebuilt from stored totals, which is why the rollup
computes it in advance and why `roll_up_month` refuses to run on a month whose
detail has already been deleted. It would otherwise replace a real year's
trading with a confident set of zeroes.

## How the charts stay unbroken

Each analytics view reads stored figures for sealed months and computes the rest
from live detail. The split is a single flag both halves read, so a month is in
exactly one of the two and can be neither counted twice nor lost between them.
The views expose `from_archive` so it is always visible which is which, and the
dashboard prints a line under the figures saying how many months are stored and
how many have had their records deleted.

Checks live in `supabase/tests/acceptance-archive.sql`. The one that matters
compares the stored figures against the detail they replace, before anything is
deleted.

## The schedule board

The planner now loads live jobs of any age plus finished work from the last six
months, rather than everything ever recorded. Older finished work lives in the
archive as figures, which is where it was being read from anyway. The constant
is `FINISHED_MONTHS_ON_BOARD` in `planner/planner.js`.
