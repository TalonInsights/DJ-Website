# Enquiry pipeline and analytics — how it works

Written for whoever picks this up next, including Harry when he asks what
counts as a win rate. 10 September 2026.

Companion documents: [schema-current.md](schema-current.md) for what existed
before, [gaps.md](gaps.md) for what was missing and why, [GDPR.md](GDPR.md) for
the personal-data position.

---

## 1. Running it

Nothing here is applied automatically. There is no Supabase CLI in this project
and no local Postgres, so this is done by hand in the **Supabase SQL Editor**.

**The short way.** Open the Supabase dashboard → SQL Editor → New query, paste
the whole of **`supabase/install.sql`**, and press Run. That file is the five
migrations concatenated in order, so nothing can be run out of sequence. Then
paste `supabase/tests/acceptance.sql` for a PASS or FAIL on each check, and
`supabase/seed/seed.sql` first if you want test data to look at.

**The long way**, if you would rather see each step land:

| Order | File | What it does |
| --- | --- | --- |
| 1 | `migrations/20260910_0001_enquiries.sql` | Enquiries, history, reference numbers, RLS |
| 2 | `migrations/20260910_0002_jobs_workshop_wide_rls.sql` | Opens `jobs` to all staff |
| 3 | `migrations/20260910_0003_production_measurement.sql` | Baseline, actuals, schedule history, capacity |
| 4 | `migrations/20260910_0004_analytics_views.sql` | `dim_date`, twelve views, the summary |
| 5 | `migrations/20260910_0005_transition_rules.sql` | Transition rules, enquiry conversion |
| 6 | `seed/seed.sql` | The full test dataset — **never in production** |
| 7 | `tests/acceptance.sql` | Prints PASS or FAIL per check |

Every file has a matching `_down.sql`. Each one is idempotent, so re-running is
safe. Each was parsed against the real PostgreSQL grammar before shipping, but
**none has been executed against a database** — there was nowhere to run one.
Expect to fix something on first run, and run the acceptance script immediately
afterwards rather than trusting it.

**Seed.** One file, `seed/seed.sql`. It clears its own previous run first, so
it is safe to paste again at any point.

It creates 150 enquiries across two years with every column populated, 30
completed jobs, 10 live on the board, and two years of varying weekly capacity.
Three things about it are deliberate:

- **History is earned, not asserted.** A job's baseline comes from the trigger
  reading its first plan, and the drift comes from really updating the plan
  afterwards. So `reschedule_count` and `job_events` are what the triggers
  actually recorded, and the seed doubles as a test of them.
- **Every status is reached**, including `on_hold` and `follow_up`, and some
  enquiries stall and are chased before they close.
- **One job in six has no enquiry behind it.** That is the repeat and phone work
  the revenue figures cannot see, and the test data shows the hole rather than
  hiding it.

Without it the capacity, schedule variance, estimate accuracy and
delivered-on-time panels are correct and empty, which reads as a fault.

**Removing the seed**, two commands:

```sql
delete from public.jobs      where ref like 'TEST-%';
delete from public.enquiries where notes like '%[seed data]%';
```

**Nightly summary refresh.** Enable `pg_cron` under Database → Extensions, then:

```sql
select cron.schedule('refresh-dashboard', '15 3 * * *',
                     $$select public.refresh_dashboard()$$);
```

Until that is scheduled, the Refresh button on the dashboard rebuilds it.

---

## 2. The status model

Nine statuses. Seven are stages in order; `follow_up` is a holding position after
a quote, and `on_hold` is a state rather than progress and should never be
counted as forward movement.

```
new → contacted → survey_booked → surveyed → quoted → won
                                                   ↘ lost
                                          follow_up ↺
                                          on_hold
```

**A status cannot be entered without the fact that makes it true.** Enforced by
a database trigger, not by the form, because row-level security lets any signed-in
member of staff update a row directly and a rule that lives only in the browser
is not a rule.

| Moving to | Requires |
| --- | --- |
| `contacted` | `first_contacted_on` |
| `survey_booked` | `survey_date`, `surveyor` |
| `surveyed` | `survey_completed_on` |
| `quoted` | `quote_value`, `quote_sent_on` |
| `won` | `quote_value` |
| `lost` | `lost_reason` |

The error names the missing field, and the board uses that to highlight it and
put the cursor in the first one. `won_on` and `lost_on` fill themselves in if
not supplied.

This is the single thing that makes the analytics worth having in a year. A
quoted enquiry with no quote value poisons every conversion and value figure
downstream, and there is no way to reconstruct it later.

---

## 3. What each metric means

Ask "how is this calculated" and the answer is always a column in a view, never
code in a page. If a number ever needs changing, change it in the view and every
screen follows.

### Win rate
`won ÷ (won + lost)`, counting only **decided** enquiries. Enquiries still open
are excluded, because including them would make the rate rise every time
something closes regardless of how it closed. Carried on `v_enquiry_funnel`,
`v_source_performance` and the summary, always beside `win_rate_n`, the number
of decided enquiries it was computed from.

### The funnel
Each stage counts enquiries that **reached** it, taken from the event history,
not enquiries currently sitting in it. An enquiry that went straight to won is
counted at every stage it passed through. This is why the history table exists:
the current status only tells you where something ended.

### Cycle times
Medians, not averages, of the days between one status and the next, taken from
the event timestamps. One job that sat in a drawer for eight months would drag
an average far enough to be useless. `median_days_total` is enquiry to decision.

### Weighted pipeline
`quote_value × probability ÷ 100`, summed over open enquiries. Probability is
whatever the person entering it believed. It is a planning number, not a
forecast, and it is only as honest as the person setting it.

### Capacity, in job-days
The workshop has never recorded an hour, so everything is in whole days.
`available_days` is **job-days**: working days in the week multiplied by how many
jobs can run at once. A five-day week running three jobs in parallel is 15.
`committed_days` counts each job's planned span across working days, so a job
spanning three weeks contributes to all three rather than landing in its start
week. Weeks with no row in `capacity_weeks` fall back to 15 and are flagged in
the UI as assumed.

If Harry decides hours are the right unit after all, it is a rename plus a
conversion factor, not a redesign.

### Schedule variance
Measured against `baseline_start` and `baseline_end` — the plan as first
committed, set once and never moved. **Never against `planned_*`**, which moves
every time a bar is dragged; measuring against that makes adherence read as
100% forever.

### Delivered on time
Against `customer_deadline`, the date the customer was actually given.
Deliberately **not** against `jobs.deadline`, which the planner auto-fills from
the end of the plan when left blank and which therefore cannot be missed. The
old column is a mixture of a promise and an echo of the schedule; the new one is
only ever a promise.

### Revenue, and the hole in it
All revenue comes from `enquiries.quote_value`. Production holds no money at
all. **A job typed straight onto the schedule is worth nothing to the
dashboard.** For a firm where much of the work is repeat and recommendation,
that under-reports revenue unless every job starts as an enquiry, including ones
already won before they are entered. This is a working practice question, not a
software one, and it decides whether the revenue tiles can be trusted.

### The thin-denominator rule
Every view emitting a rate also emits `<rate>_n`. Anything under **ten** renders
greyed with a note saying what it was computed from. A monthly conversion rate in
a firm this size can run on three enquiries and will read as a trend when it is
noise. The UI is never allowed to guess what the denominator was.

---

## 4. The shape of the code

```
pipeline/
  index.html      the board, table and drawer
  analytics.html  the dashboard
  app.css         all styling, on the planner's tokens
  client.js       Supabase client and the sign-in gate, shared
  data.js         one function per view, plus the mutations
  board.js        the board
  dash.js         the dashboard
  charts.js       inline SVG charts, no library
```

**Two rules.** No metric is computed in JavaScript; if you are summing or
dividing in a `.js` file, it belongs in a view. And no page reaches Supabase
directly; everything goes through `data.js`.

`pipeline` is a second area of the product Harry already uses, not a second
product: same account, same sign-in, same tokens and type as `/planner`. There
is no build step and no dependencies. Charts are hand-drawn SVG because the
content security policy on `/pipeline` allows scripts only from itself and
`esm.sh`, and any library would need styling back to the brand regardless.

`REQUIRED_FOR` in `data.js` mirrors the database trigger so the drawer can show
the missing field before a round trip. **If you change the rules in SQL, change
that object too.**

---

## 5. Access, privacy and safety

**Who can see what.** Any signed-in member of staff sees every enquiry and every
job. This was a deliberate change on 10 September 2026: `jobs` was previously
scoped to its owner, which cannot support a shared board or a shared dashboard.
There are no roles. If a surveyor should see jobs but not quote values, that
needs a roles table and new policies.

`anon` has no policy on any table, so the publishable key reads nothing. Proven
by the acceptance script, which checks that no policy names `anon` and that an
anonymous insert is refused.

**The history tables cannot be written from the client.** `enquiry_events` and
`job_events` have a read policy only; both are written by security-definer
triggers. The log cannot be forged or tidied up.

**Personal data.** Enquiries hold names, addresses, phone numbers and email
addresses — materially more than the planner's two name fields. Before this goes
into real use:

- agree a retention period and schedule `purge_old_enquiries()` beside
  `purge_old_jobs()`;
- confirm the privacy notice on the public site covers enquiry data;
- if the marketing site is ever wired to post enquiries directly, that must go
  through a server route holding the service key, never an anonymous insert, and
  the form needs a lawful-basis line beside the submit button;
- check Supabase point-in-time recovery is on at the plan tier in use. It has
  not been confirmed either way here.

Nothing is cached in `localStorage` beyond the Supabase session itself.

**Accessibility.** Every colour pair was measured rather than eyeballed. The
site's `--mute` and `--brass` are 3.1:1 and 3.6:1 on white, which is fine for a
rule or a bar but fails AA as text, so `--mute-tx` and `--brass-tx` are the same
hues walked down until they clear 4.5:1 on white, paper and sage; the original
tokens stay for graphics, where 3:1 applies. Input borders use `--rule-ctl` at
3.17:1 so the field edge is findable.

Cards are focusable and open with Enter or Space, which is the keyboard route
past drag and drop. Status is never carried by colour alone: an overdue card has
a brass edge **and** the word Overdue.

---

## 6. Known limits

- **Nothing has been run against a database.** Every file parses; none has
  executed.
- **The enquiry form on the public website is still a demo stub.** It shows a
  "not connected" message and sends nothing. Wiring it to post into `enquiries`
  is the obvious next step and would make the website the top of this funnel.
- **Bank holidays are not modelled.** `dim_date.is_working_day` is Monday to
  Friday, so capacity is overstated about eight days a year.
- **`who` on a job stage is free text.** Two spellings are two people, so
  per-person utilisation is not possible without a staff table.
- **Estimated days are seeded from history** at conversion and are a starting
  point, not a quote.
- **Jobs already on the board have a baseline of wherever their plan stood on
  the day the migration ran.** Their real original plan was overwritten long ago
  and cannot be recovered. Every job created afterwards has an honest one.
