# Gaps — what analytics needs that production does not capture

Phase 0 output. Reads alongside [schema-current.md](schema-current.md).
10 September 2026.

---

## The acceptance question, answered

> **Can we currently measure planned-versus-actual on a job?**

**No. Not for any job, and not retrospectively for any job already on the
board.** Three separate things are missing, and the third is the serious one:

1. **There are no actuals.** Nothing records when a stage or a job really
   started or finished. `phases[].start` and `phases[].end` are the plan, and
   only ever the plan.
2. **There is no baseline.** No column preserves what was originally committed,
   so there is nothing to measure variance against.
3. **There is no history, and the plan overwrites itself.** Dragging a bar
   rewrites `phases` in place and upserts the whole job. The previous dates are
   gone, permanently and irrecoverably. Every reschedule silently destroys the
   evidence that a reschedule happened.

Point 3 means the usual reassurance — *"we can backfill later"* — is false here.
Nothing can be reconstructed. Whatever has been dragged since the planner went
live is already lost.

Phase 2 must therefore add all of it, and the plan's own sequencing note applies
harder than it reads:

> *"you can add a chart in an afternoon, but history you failed to capture is
> gone permanently."*

**Recommendation:** the baseline columns and the `job_events` table are worth
shipping on their own, before any enquiry work, because every week they are not
there is a week of schedule history that cannot be recovered.

---

## 1. Missing on `jobs` — required by Phase 2

Everything the plan lists is genuinely absent. Nothing in this table already
exists in some other form.

| Field | Present? | Needed by |
| --- | --- | --- |
| `actual_start`, `actual_end` | No | `v_job_performance`, `v_promise_vs_delivery` |
| `baseline_start`, `baseline_end` | No | `v_job_performance` — all variance |
| `estimated_hours` | No | `v_estimate_accuracy`, `v_weekly_capacity` |
| `actual_hours` | No | `v_estimate_accuracy`, `v_source_performance` |
| `reschedule_count` | No | `v_job_performance` |
| `enquiry_id` | No | every cross-domain metric |
| `job_events` table | No | reschedule history, schedule adherence over time |
| `capacity_weeks` table | No | `v_weekly_capacity`, the forward-capacity tile |

## 2. Missing, and *not* in the plan

Found during the audit. Each one breaks a named view if left as it is.

**`product_type` on a job.** `v_estimate_accuracy` and `v_promise_vs_delivery`
both group by product type. The plan puts `product_type` on `enquiries` only. Any
job Harry types straight onto the Gantt — repeat work, a phone job, anything that
never was an enquiry — has no product type and drops out of both views. Either
copy `product_type` onto `jobs` at conversion, or accept that those two views
only ever describe enquiry-originated work and label them that way in the UI.

**`ref` is inconsistent between the two halves.** `jobs.ref` is free text, not
unique, not generated. `enquiries.ref` in the plan is `unique not null` with a
`DJS-YYYY-NNNN` sequence. Two reference schemes in one product will confuse
Harry on the phone to a customer. Decide whether a converted job inherits the
enquiry's ref.

**`deadline` conflates a promise with an echo of the plan.** When left blank it
is auto-filled to one working day after the last stage ends
(`planner.js` 733–736), so for those jobs it can never be breached at the moment
of saving. There is no flag saying which kind it is. `v_promise_vs_delivery`
built on today's column would be measuring a mixture. Needs either a
`deadline_source` flag (`promised` / `derived`) or a separate
`customer_promised_date` that is never auto-filled.

**`who` is free text with no identity.** A `<datalist>` of names typed on other
jobs. Two spellings are two people. Fine for a Gantt label; not usable for
per-person utilisation, and not linkable to `auth.users`. Only matters if
capacity is ever wanted per person rather than for the workshop as a whole.

**There is no money anywhere in the system.** Not on jobs, not on stages,
nowhere. Every revenue figure on the proposed dashboard — weighted pipeline,
revenue per production hour, `v_source_performance`, the value columns in
`v_lost_analysis` — would come solely from `enquiries.quote_value`.

That is a real limit, not a detail. **Work that does not enter through the
enquiry pipeline is worth £0 to the dashboard.** For a firm where a good share
of work arrives by repeat custom and word of mouth, revenue-per-hour and
source-performance will under-count from day one unless Harry commits to
creating an enquiry for *every* job, including ones he has already won before he
types them in. Worth asking him directly, because it changes whether those
tiles are trustworthy or actively misleading.

## 3. Missing everywhere — the analytics substrate

- No `enquiries`, no `enquiry_events`, no `enquiry_status` / `enquiry_source`
  enums. Expected; Phase 1 builds them.
- No `dim_date`. Needed so empty weeks render as zero instead of vanishing.
- **No views or materialised views of any kind.** The view layer is being built
  from nothing, which is good news: no legacy aggregation to reconcile.
- No `pg_cron` schedule in place. `purge_old_jobs()` exists but nothing calls it,
  and `mv_dashboard_summary` would need a nightly refresh.

## 4. The unit problem — days versus hours

The plan is written in hours throughout: `estimated_hours`, `actual_hours`,
`capacity_weeks.available_hours`, utilisation %, revenue per production hour.

**The planner has no concept of an hour.** Every stage is a start date and an end
date. The only durations in the system are the eight hard-coded default day
counts in `planner.js` (Timber Matching 3 days, Assembly 5, and so on), which are
per-stage constants — not per-job, not per-unit, not per-product.

Three options, in rough order of cost:

| Option | Cost | What it gives up |
| --- | --- | --- |
| **Model capacity in days**, matching the tool as built | Low | Utilisation is coarse; a half-day is invisible |
| **Add an hours estimate per job**, keep the Gantt in days | Medium | One extra field Harry must fill, honestly, every time |
| **Rebuild the Gantt in hours** | High | Rewrites the planner; not warranted by this brief |

This is the first of Harry's open questions and it blocks Phase 2, exactly as the
plan says. The audit's contribution is that **days is what exists**, and moving
to hours is a change to the production tool, not an addition to the analytics
layer.

## 5. RLS — a contradiction to resolve before Phase 1

The plan says *"Match the pattern found in Phase 0"* and then *"Baseline:
authenticated staff can select and modify all rows."*

Those cannot both be honoured. The pattern found is strictly owner-scoped:
`owner_id = auth.uid()` on select, insert, update and delete, with
`force row level security`. Every job belongs to exactly one user and is
invisible to all others.

Follow the existing pattern and each member of staff gets a private pipeline and
a private dashboard showing only their own enquiries — which is not a dashboard.

The realistic shape, if more than one person will ever sign in:

- Move to workshop-wide visibility for `authenticated`, keeping writes
  controlled, and migrate `jobs` off `owner_id` scoping.
- Introduce a roles table, if surveyors should see jobs but not quote values —
  which is Harry's third open question and cannot be answered without him.

This also has a data-protection edge: enquiries hold names, addresses, phone
numbers and emails, which is materially more personal data than `jobs` holds
today (a client name and a staff name). Widening visibility and widening the
personal data held are happening in the same change. That deserves a deliberate
decision, not a default. See Phase 7 of the plan and `docs/GDPR.md`.

## 6. The stack question — blocks Phases 4, 5 and 6

Set out in [schema-current.md §1](schema-current.md). In short: there is no
Next.js, no TypeScript, no Tailwind and no npm toolchain in this repository, and
no second repository that has them.

Phases 1, 2 and 3 are pure SQL and are unaffected. They can start as soon as the
unit and RLS questions above are answered. Phases 4 to 6 need a decision first:

| Route | Fits | Against |
| --- | --- | --- |
| **Extend the existing planner** — vanilla ES module, same CSS tokens | No new toolchain; one product, one sign-in; matches the CSP already set for `/planner` | Hand-rolling a board, drag-and-drop, and charts. Recharts is unavailable without a bundler; a charting library would have to come from `esm.sh` to satisfy the CSP |
| **New Next.js app**, separate deploy, same Supabase | The plan as written; types, server actions, Recharts all work | Two apps, two sign-ins, two design systems; the planner stays vanilla or gets rewritten too |
| **Rebuild planner and enquiries together in Next.js** | One coherent product, properly typed | Much the largest job, and it rewrites something that currently works |

My recommendation is the **first** for the enquiry board and the **second only if
the dashboard's charting turns out to justify it** — but this is Talon's call and
the client's budget, not a technical default. Nothing below Phase 3 should start
until it is made.

---

## Summary — what blocks what

| Blocker | Blocks | Who decides |
| --- | --- | --- |
| Days versus hours | Phase 2, Phase 3 | Harry |
| RLS: owner-scoped or workshop-wide | Phase 1 onward | Talon + Harry |
| Front-end stack | Phases 4, 5, 6 | Talon |
| Every job an enquiry, or not? | Trustworthiness of all revenue tiles | Harry |
| Retention for enquiry personal data | Phase 7, but agree early | Harry |

**Not blocked, and worth doing now:** baseline columns and `job_events` on the
existing `jobs` table. They need no decisions, and they stop the daily loss of
schedule history described at the top of this document.
