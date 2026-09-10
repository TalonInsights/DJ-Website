-- =====================================================================
--  INSTALL — David Jackson & Son enquiry pipeline and analytics
--
--  GENERATED. Do not edit. It is the five migrations in
--  supabase/migrations concatenated in order, so the whole thing can go
--  into the Supabase SQL Editor in one paste and cannot be run out of
--  sequence. Edit the individual migrations and regenerate.
--
--  HOW TO RUN
--    1. Supabase dashboard -> SQL Editor -> New query
--    2. Paste this whole file, press Run. It takes a few seconds.
--    3. Optional, test data:  paste supabase/seed/enquiries.sql
--    4. Paste supabase/tests/acceptance.sql for a PASS/FAIL verdict
--
--  Safe to re-run: every statement is idempotent.
--  To undo, run the matching _down.sql files in REVERSE order.
--
--  Generated 10 September 2026 from:
--    20260910_0001_enquiries.sql
--    20260910_0002_jobs_workshop_wide_rls.sql
--    20260910_0003_production_measurement.sql
--    20260910_0004_analytics_views.sql
--    20260910_0005_transition_rules.sql
--    20260910_0006_revoke_anon.sql
--    20260910_0007_owner_id_optional.sql
--    20260910_0008_fix_pipeline_spread.sql
-- =====================================================================




-- #####################################################################
-- ##  20260910_0001_enquiries.sql
-- #####################################################################

-- =====================================================================
--  Phase 1 — Enquiry pipeline
--
--  Adds the enquiry side of the business: the enquiries themselves, a
--  tamper-resistant status history, and workshop-wide row-level security.
--
--  Run in the Supabase SQL Editor. Idempotent — safe to re-run.
--  Rollback: supabase/migrations/20260910_0001_enquiries_down.sql
--
--  PERSONAL DATA WARNING
--  ---------------------
--  This table holds materially more personal data than `jobs` does:
--  customer and contact names, site and billing addresses, phone numbers
--  and email addresses. That is a step up from the two name fields the
--  production planner holds, and it changes the retention and access
--  position. See docs/GDPR.md before widening access any further.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. Vocabulary
--
--  Statuses are the pipeline stages, in the order work moves through
--  them. `on_hold` sits outside that order deliberately — it is a state,
--  not a stage, and nothing should treat it as progress.
-- ---------------------------------------------------------------------
do $$ begin
  create type public.enquiry_status as enum (
    'new','contacted','survey_booked','surveyed',
    'quoted','follow_up','won','lost','on_hold'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.enquiry_source as enum (
    'website','phone','email','referral','repeat','trade','walk_in','other'
  );
exception when duplicate_object then null; end $$;


-- ---------------------------------------------------------------------
--  2. Reference numbers — DJS-YYYY-NNNN
--
--  Sequential within the year. A per-year counter row rather than a
--  Postgres sequence, because the number must reset each January and a
--  sequence cannot be reset safely while others are inserting.
--
--  `on conflict do update` takes a row-level lock, so two people saving
--  an enquiry at the same moment queue rather than collide. Do NOT
--  compute this in the client — two browsers would happily agree on the
--  same number.
-- ---------------------------------------------------------------------
create table if not exists public.enquiry_ref_seq (
  year     int primary key,
  last_no  int not null default 0
);

comment on table public.enquiry_ref_seq is
  'Per-year counter behind DJS-YYYY-NNNN. Written only by next_enquiry_ref().';


-- ---------------------------------------------------------------------
--  3. Enquiries
-- ---------------------------------------------------------------------
create table if not exists public.enquiries (
  id            uuid primary key default gen_random_uuid(),
  ref           text unique not null,
  received_on   date not null default current_date,
  source        public.enquiry_source not null default 'other',
  source_detail text,
  status        public.enquiry_status not null default 'new',

  -- customer (personal data)
  customer_name text not null check (length(customer_name) between 1 and 200),
  contact_name  text check (length(contact_name) <= 200),
  phone         text check (length(phone) <= 40),
  email         text check (length(email) <= 320),

  -- site (personal data)
  site_address_1 text,
  site_address_2 text,
  site_town      text,
  site_postcode  text,
  billing_same   boolean not null default true,
  billing_address_1 text,
  billing_town      text,
  billing_postcode  text,

  -- the job
  job_description text,
  product_type    text[] not null default '{}',
  material        text,
  approx_units    int check (approx_units >= 0),
  property_type   text,
  access_notes    text,
  building_regs_applicable boolean,

  -- survey
  survey_date             date,
  survey_slot             text check (survey_slot in ('am','pm')),
  surveyor                text,
  survey_completed_on     date,
  survey_reschedule_count int not null default 0 check (survey_reschedule_count >= 0),

  -- quote
  quote_value      numeric(10,2) check (quote_value >= 0),
  quote_sent_on    date,
  quote_expires_on date,
  probability      int check (probability between 0 and 100),

  -- what the customer is expecting
  target_install_from date,
  target_install_to   date,
  customer_deadline   date,

  -- actioning
  next_action        text,
  next_action_on     date,
  first_contacted_on date,

  -- outcome
  won_on      date,
  lost_on     date,
  lost_reason text,
  lost_to     text,
  job_id      uuid references public.jobs (id) on delete set null,

  notes      text,
  created_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- A window that runs backwards is a data-entry slip, not a preference.
  constraint enquiries_install_window_ordered
    check (target_install_to is null
           or target_install_from is null
           or target_install_to >= target_install_from)
);

comment on table public.enquiries is
  'Sales pipeline. Contains substantial personal data — names, addresses, phones, emails. See docs/GDPR.md.';
comment on column public.enquiries.ref is
  'DJS-YYYY-NNNN, generated server-side. Never set this from the client.';
comment on column public.enquiries.job_id is
  'Set when the enquiry is converted. jobs.enquiry_id is the other half of the link.';
comment on column public.enquiries.created_by is
  'Who entered it. Provenance only — access is workshop-wide, not owner-scoped.';

create index if not exists enquiries_status_idx    on public.enquiries (status);
create index if not exists enquiries_survey_idx    on public.enquiries (survey_date);
create index if not exists enquiries_received_idx  on public.enquiries (received_on);
create index if not exists enquiries_job_idx       on public.enquiries (job_id);

-- Partial: the follow-up list only ever asks about live enquiries, so
-- closed ones do not belong in the index at all.
create index if not exists enquiries_follow_up_idx on public.enquiries (next_action_on)
  where status not in ('won','lost');


-- ---------------------------------------------------------------------
--  4. Reference generator
--
--  Fires only when `ref` was not supplied, so the seed file and any
--  future import can carry their own references.
-- ---------------------------------------------------------------------
create or replace function public.next_enquiry_ref()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  y int;
  n int;
begin
  if new.ref is not null and length(trim(new.ref)) > 0 then
    return new;
  end if;

  y := extract(year from coalesce(new.received_on, current_date))::int;

  insert into public.enquiry_ref_seq as s (year, last_no)
       values (y, 1)
  on conflict (year) do update
          set last_no = s.last_no + 1
    returning s.last_no into n;

  new.ref := 'DJS-' || y::text || '-' || lpad(n::text, 4, '0');
  return new;
end;
$$;

drop trigger if exists enquiries_set_ref on public.enquiries;
create trigger enquiries_set_ref
  before insert on public.enquiries
  for each row execute function public.next_enquiry_ref();


-- ---------------------------------------------------------------------
--  5. Status history
--
--  THIS TABLE IS THE SOURCE OF TRUTH FOR EVERY CYCLE-TIME METRIC.
--
--  Do not compute durations from the date columns on `enquiries`. Those
--  can be corrected after the fact, and a correction would silently
--  rewrite history. An event row is what actually happened, when.
--
--  Written only by the trigger below, which is security definer. There
--  is deliberately no insert, update or delete policy for `authenticated`,
--  so the log cannot be forged or tidied up from the client.
-- ---------------------------------------------------------------------
create table if not exists public.enquiry_events (
  id          bigserial primary key,
  enquiry_id  uuid not null references public.enquiries (id) on delete cascade,
  from_status public.enquiry_status,
  to_status   public.enquiry_status not null,
  note        text,
  actor       uuid references auth.users (id) on delete set null,
  occurred_at timestamptz not null default now()
);

comment on table public.enquiry_events is
  'Append-only status history. Source of truth for cycle times. Written only by log_enquiry_status().';

create index if not exists enquiry_events_enquiry_idx
  on public.enquiry_events (enquiry_id, occurred_at);

-- Answering "which enquiries reached `quoted` last month" without this
-- means scanning the whole log.
create index if not exists enquiry_events_to_status_idx
  on public.enquiry_events (to_status, occurred_at);

create or replace function public.log_enquiry_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.enquiry_events (enquiry_id, from_status, to_status, actor)
    values (new.id, null, new.status, auth.uid());

  -- `after update of status` also fires when status is named in the
  -- statement but unchanged, so compare before writing. Without this a
  -- routine edit would add a phantom transition.
  elsif new.status is distinct from old.status then
    insert into public.enquiry_events (enquiry_id, from_status, to_status, actor)
    values (new.id, old.status, new.status, auth.uid());
  end if;

  return new;
end;
$$;

drop trigger if exists enquiries_log_status on public.enquiries;
create trigger enquiries_log_status
  after insert or update of status on public.enquiries
  for each row execute function public.log_enquiry_status();


-- ---------------------------------------------------------------------
--  6. updated_at
--
--  Reuses public.touch_updated_at() from the original schema.sql.
-- ---------------------------------------------------------------------
drop trigger if exists enquiries_touch_updated_at on public.enquiries;
create trigger enquiries_touch_updated_at
  before update on public.enquiries
  for each row execute function public.touch_updated_at();


-- ---------------------------------------------------------------------
--  7. Row-level security — workshop-wide
--
--  DELIBERATE DEPARTURE from the owner-scoped pattern on `jobs`.
--  Agreed 10 Sep 2026: any signed-in member of staff sees the whole
--  pipeline, because a per-user pipeline cannot produce a shared
--  dashboard. `created_by` records who entered a row; it no longer
--  controls who may read it.
--
--  `anon` gets no policy at all, so the public key reads nothing. If the
--  marketing site is ever to post enquiries directly, that must go
--  through a server route holding the service key — never an anon insert.
--
--  Migration 0002 brings `jobs` into line.
-- ---------------------------------------------------------------------
alter table public.enquiries      enable row level security;
alter table public.enquiries      force  row level security;
alter table public.enquiry_events enable row level security;
alter table public.enquiry_ref_seq enable row level security;

drop policy if exists enquiries_select_staff on public.enquiries;
create policy enquiries_select_staff on public.enquiries
  for select to authenticated using (true);

drop policy if exists enquiries_insert_staff on public.enquiries;
create policy enquiries_insert_staff on public.enquiries
  for insert to authenticated with check (true);

drop policy if exists enquiries_update_staff on public.enquiries;
create policy enquiries_update_staff on public.enquiries
  for update to authenticated using (true) with check (true);

drop policy if exists enquiries_delete_staff on public.enquiries;
create policy enquiries_delete_staff on public.enquiries
  for delete to authenticated using (true);

-- Read the history; never write it.
drop policy if exists enquiry_events_select_staff on public.enquiry_events;
create policy enquiry_events_select_staff on public.enquiry_events
  for select to authenticated using (true);

-- enquiry_ref_seq: RLS on, no policies. Only the definer function touches it.


-- ---------------------------------------------------------------------
--  8. Storage limitation (UK GDPR Art. 5(1)(e))
--
--  Lost and won enquiries should not be kept indefinitely. Nothing calls
--  this automatically — agree a period with the client first, then
--  schedule it beside purge_old_jobs().
--
--    select public.purge_old_enquiries(36);
-- ---------------------------------------------------------------------
create or replace function public.purge_old_enquiries(keep_months int default 36)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed integer;
begin
  delete from public.enquiries
   where status in ('won','lost')
     and coalesce(won_on, lost_on) is not null
     and coalesce(won_on, lost_on) < (current_date - make_interval(months => keep_months));

  get diagnostics removed = row_count;
  return removed;
end;
$$;

revoke all on function public.purge_old_enquiries(int) from public, anon, authenticated;


-- #####################################################################
-- ##  20260910_0002_jobs_workshop_wide_rls.sql
-- #####################################################################

-- =====================================================================
--  Bring `jobs` into line with the workshop-wide access decision
--
--  Agreed 10 Sep 2026. Until now every policy on `jobs` was scoped to
--  `owner_id = auth.uid()`, so a job belonged to exactly one account and
--  was invisible to every other. That was correct while only one person
--  signed in. It cannot support a shared pipeline or a shared dashboard:
--  a second member of staff would see an empty board, and any view
--  joining enquiries to jobs would silently return nothing across users.
--
--  After this migration any signed-in member of staff sees every job.
--  `owner_id` is kept, but demoted from an access control to a record of
--  who created the row.
--
--  READ BEFORE RUNNING
--  -------------------
--  * This widens who can see client names and staff names. It is a
--    deliberate, recorded decision, not a default. See docs/GDPR.md.
--  * `anon` still has no policy on this table and reads nothing.
--  * Reversible — see the down file — but note that reverting will hide
--    every job from everyone except its original creator.
-- =====================================================================

-- Existing jobs were all created by one account; nothing needs backfilling.
-- Keep the column non-null so provenance is never lost, but stop it being
-- the thing that decides visibility.
comment on column public.jobs.owner_id is
  'Who created the job. Provenance only since 10 Sep 2026 — access is workshop-wide, not owner-scoped.';

drop policy if exists jobs_select_own on public.jobs;
drop policy if exists jobs_insert_own on public.jobs;
drop policy if exists jobs_update_own on public.jobs;
drop policy if exists jobs_delete_own on public.jobs;

-- Drop the new names too, so a second run replaces them rather than
-- failing on "policy already exists".
drop policy if exists jobs_select_staff on public.jobs;
drop policy if exists jobs_insert_staff on public.jobs;
drop policy if exists jobs_update_staff on public.jobs;
drop policy if exists jobs_delete_staff on public.jobs;

create policy jobs_select_staff on public.jobs
  for select to authenticated using (true);

create policy jobs_insert_staff on public.jobs
  for insert to authenticated with check (true);

create policy jobs_update_staff on public.jobs
  for update to authenticated using (true) with check (true);

create policy jobs_delete_staff on public.jobs
  for delete to authenticated using (true);

-- The owner-scoped indexes were built for policies that no longer exist.
-- Queries now filter by deadline and recency across the whole workshop.
create index if not exists jobs_deadline_idx on public.jobs (deadline);
create index if not exists jobs_updated_idx  on public.jobs (updated_at desc);

comment on table public.jobs is
  'Workshop production schedule, visible to all signed-in staff. Contains personal data (client and staff names) — see docs/GDPR.md.';


-- #####################################################################
-- ##  20260910_0003_production_measurement.sql
-- #####################################################################

-- =====================================================================
--  Phase 2 — Close the production measurement gaps
--
--  Before this migration nothing about a job could be measured. There
--  were no actual dates, no baseline, and no history: the planner
--  rewrites `phases` in place on every drag and upserts the whole row,
--  so the previous plan was gone permanently. See docs/gaps.md.
--
--  UNIT: WHOLE DAYS, not hours
--  ---------------------------
--  The plan this work follows was written in hours. The planner has
--  never held an hour — every stage is a start date and an end date, and
--  the only durations in the system are eight hard-coded per-stage day
--  counts. Modelling capacity in hours would mean inventing numbers
--  nobody measures, so everything here is in days and named as such.
--  If the client later decides to track hours, it is a rename plus a
--  conversion factor, not a redesign.
--
--  Capacity in days still answers "how full is April", because
--  available_days is working days multiplied by how many jobs the
--  workshop can run at once. See capacity_weeks below.
--
--  NOTHING IN THE PLANNER NEEDS CHANGING
--  -------------------------------------
--  The derived columns, the baseline and the history all maintain
--  themselves from the `phases` array the planner already writes. The
--  moment this migration runs, schedule history starts accumulating.
--
--  Run in the Supabase SQL Editor. Idempotent.
--  Rollback: 20260910_0003_production_measurement_down.sql
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. Columns on `jobs`
-- ---------------------------------------------------------------------
alter table public.jobs
  add column if not exists planned_start     date,
  add column if not exists planned_end       date,
  add column if not exists baseline_start    date,
  add column if not exists baseline_end      date,
  add column if not exists actual_start      date,
  add column if not exists actual_end        date,
  add column if not exists estimated_days    numeric(6,1) check (estimated_days >= 0),
  add column if not exists actual_days       numeric(6,1) check (actual_days >= 0),
  add column if not exists reschedule_count  int not null default 0 check (reschedule_count >= 0),
  add column if not exists enquiry_id        uuid references public.enquiries (id) on delete set null,
  add column if not exists product_type      text[] not null default '{}',
  add column if not exists customer_deadline date;

comment on column public.jobs.planned_start is
  'Derived from phases[] by trigger. The current plan — moves every time a bar is dragged.';
comment on column public.jobs.baseline_start is
  'The plan as first committed. Set once, never moved. All schedule variance is measured against this.';
comment on column public.jobs.actual_start is
  'When work really began. Entered by hand; nothing infers it.';
comment on column public.jobs.customer_deadline is
  'A date the customer was actually given. NEVER auto-filled — unlike `deadline`, which the planner fills in from the end of the plan when left blank, and which therefore cannot be missed. Use this column for anything measuring lateness.';
comment on column public.jobs.enquiry_id is
  'Set at conversion. enquiries.job_id is the other half of the link.';
comment on column public.jobs.product_type is
  'Copied from the enquiry at conversion, so jobs typed straight onto the board can still carry one.';

create index if not exists jobs_enquiry_idx  on public.jobs (enquiry_id);
create index if not exists jobs_planned_idx  on public.jobs (planned_start, planned_end);
create index if not exists jobs_actual_idx   on public.jobs (actual_end);


-- ---------------------------------------------------------------------
--  2. Schedule history
--
--  Same reasoning as enquiry_events: the columns can be corrected, the
--  log is what happened. Written only by the trigger, which is security
--  definer, and there is no write policy for `authenticated`.
-- ---------------------------------------------------------------------
create table if not exists public.job_events (
  id          bigserial primary key,
  job_id      uuid not null references public.jobs (id) on delete cascade,
  kind        text not null check (kind in ('created','rescheduled','started','completed')),
  from_start  date,
  from_end    date,
  to_start    date,
  to_end      date,
  days_moved  int,
  actor       uuid references auth.users (id) on delete set null,
  occurred_at timestamptz not null default now()
);

comment on table public.job_events is
  'Append-only schedule history. Every reschedule of the plan, with how far it moved.';

create index if not exists job_events_job_idx
  on public.job_events (job_id, occurred_at);
create index if not exists job_events_kind_idx
  on public.job_events (kind, occurred_at);


-- ---------------------------------------------------------------------
--  3. Derive the plan, set the baseline once, count reschedules
--
--  BEFORE trigger so the derived values are written with the row rather
--  than in a second update.
-- ---------------------------------------------------------------------
create or replace function public.jobs_derive_plan()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  s date;
  e date;
begin
  select min((p ->> 'start')::date), max((p ->> 'end')::date)
    into s, e
    from pg_catalog.jsonb_array_elements(coalesce(new.phases, '[]'::jsonb)) as p
   where coalesce(p ->> 'start', '') <> ''
     and coalesce(p ->> 'end',   '') <> '';

  new.planned_start := s;
  new.planned_end   := e;

  -- The baseline is whatever the plan was the first time it existed.
  -- Once set it is never touched again, which is the whole point.
  if new.baseline_start is null and s is not null then
    new.baseline_start := s;
    new.baseline_end   := e;
  end if;

  if tg_op = 'UPDATE'
     and old.baseline_start is not null
     and (new.planned_start is distinct from old.planned_start
          or new.planned_end is distinct from old.planned_end) then
    new.reschedule_count := coalesce(old.reschedule_count, 0) + 1;
  end if;

  return new;
end;
$$;

drop trigger if exists jobs_derive_plan on public.jobs;
create trigger jobs_derive_plan
  before insert or update on public.jobs
  for each row execute function public.jobs_derive_plan();


-- Backfill the derived columns and baselines for jobs already on the
-- board, BEFORE the history trigger exists. Their true original plan is
-- unrecoverable — it was overwritten long ago — so the baseline is set to
-- wherever the plan stands today. Doing this first means migrating an old
-- job does not write a 'rescheduled' event for a move that never happened.
update public.jobs set updated_at = updated_at where planned_start is null;


create or replace function public.log_job_schedule()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.planned_start is not null then
      insert into public.job_events (job_id, kind, to_start, to_end, actor)
      values (new.id, 'created', new.planned_start, new.planned_end, auth.uid());
    end if;
    return new;
  end if;

  if new.planned_start is distinct from old.planned_start
     or new.planned_end is distinct from old.planned_end then
    insert into public.job_events
      (job_id, kind, from_start, from_end, to_start, to_end, days_moved, actor)
    values
      (new.id, 'rescheduled', old.planned_start, old.planned_end,
       new.planned_start, new.planned_end,
       (new.planned_end - old.planned_end), auth.uid());
  end if;

  if new.actual_start is not null and old.actual_start is null then
    insert into public.job_events (job_id, kind, to_start, actor)
    values (new.id, 'started', new.actual_start, auth.uid());
  end if;

  if new.actual_end is not null and old.actual_end is null then
    insert into public.job_events (job_id, kind, to_end, actor)
    values (new.id, 'completed', new.actual_end, auth.uid());
  end if;

  return new;
end;
$$;

drop trigger if exists jobs_log_schedule on public.jobs;
create trigger jobs_log_schedule
  after insert or update on public.jobs
  for each row execute function public.log_job_schedule();

-- ---------------------------------------------------------------------
--  4. Capacity
--
--  available_days is job-days, not calendar days: working days in the
--  week multiplied by how many jobs the workshop can run at once. A
--  five-day week running three jobs in parallel is 15.
--
--  Deliberately not a resource-level model. The question is "how full is
--  April", not "which bench is Dave on at 2pm".
-- ---------------------------------------------------------------------
create table if not exists public.capacity_weeks (
  week_start     date primary key,
  available_days numeric(6,1) not null check (available_days >= 0),
  note           text,
  updated_at     timestamptz not null default now(),
  constraint capacity_weeks_is_monday check (extract(isodow from week_start) = 1)
);

comment on table public.capacity_weeks is
  'Workshop capacity per ISO week, in job-days. Weeks with no row fall back to the default in v_weekly_capacity.';

drop trigger if exists capacity_weeks_touch_updated_at on public.capacity_weeks;
create trigger capacity_weeks_touch_updated_at
  before update on public.capacity_weeks
  for each row execute function public.touch_updated_at();


-- ---------------------------------------------------------------------
--  5. Row-level security
-- ---------------------------------------------------------------------
alter table public.job_events    enable row level security;
alter table public.capacity_weeks enable row level security;
alter table public.capacity_weeks force  row level security;

drop policy if exists job_events_select_staff on public.job_events;
create policy job_events_select_staff on public.job_events
  for select to authenticated using (true);
-- No write policy: the log is written only by the definer trigger.

drop policy if exists capacity_select_staff on public.capacity_weeks;
create policy capacity_select_staff on public.capacity_weeks
  for select to authenticated using (true);

drop policy if exists capacity_write_staff on public.capacity_weeks;
create policy capacity_write_staff on public.capacity_weeks
  for all to authenticated using (true) with check (true);


-- #####################################################################
-- ##  20260910_0004_analytics_views.sql
-- #####################################################################

-- =====================================================================
--  Phase 3 — The view layer
--
--  Every metric on the dashboard is a column here. Nothing aggregates in
--  application code: if a number needs computing, it belongs in a view.
--
--  TWO RULES ENFORCED IN SQL
--  -------------------------
--  1. Every view that emits a rate also emits the count it was computed
--     from, as <rate>_n. This is a small firm; a monthly conversion rate
--     can run on three enquiries and will read as trend when it is noise.
--     The UI greys out any rate whose n is below 10 — it must never have
--     to guess what the denominator was.
--  2. Every time series left-joins from dim_date, so a quiet week
--     appears as a zero rather than vanishing. A gap in a trend line
--     reads as "nothing happened here" and is the commonest bug in
--     dashboards of this shape.
--
--  Every view is security_invoker, so it runs with the caller's
--  permissions and the policies on the tables beneath it still apply.
--  Without that a view silently bypasses row-level security, which is
--  exactly the sort of hole nobody notices until it matters.
--
--  Run in the Supabase SQL Editor. Idempotent.
--  Rollback: 20260910_0004_analytics_views_down.sql
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. Date dimension
--
--  is_working_day is Monday to Friday only. English bank holidays are
--  NOT modelled — there is no source for them in this database, and
--  inventing one would quietly overstate capacity eight times a year.
--  If capacity planning ever needs to be exact, load a real calendar.
-- ---------------------------------------------------------------------
create table if not exists public.dim_date (
  d              date primary key,
  iso_year       int  not null,
  iso_week       int  not null,
  week_start     date not null,
  month_start    date not null,
  quarter_start  date not null,
  year_start     date not null,
  is_working_day boolean not null
);

comment on table public.dim_date is
  'Calendar 2020-2032. is_working_day is Mon-Fri; bank holidays are not modelled.';

insert into public.dim_date (d, iso_year, iso_week, week_start, month_start, quarter_start, year_start, is_working_day)
select g::date,
       extract(isoyear from g)::int,
       extract(week    from g)::int,
       date_trunc('week',    g)::date,
       date_trunc('month',   g)::date,
       date_trunc('quarter', g)::date,
       date_trunc('year',    g)::date,
       extract(isodow from g) <= 5
  from generate_series(date '2020-01-01', date '2032-12-31', interval '1 day') as g
on conflict (d) do nothing;

alter table public.dim_date enable row level security;
drop policy if exists dim_date_select_staff on public.dim_date;
create policy dim_date_select_staff on public.dim_date
  for select to authenticated using (true);

create index if not exists dim_date_week_idx  on public.dim_date (week_start);
create index if not exists dim_date_month_idx on public.dim_date (month_start);


-- ---------------------------------------------------------------------
--  2. v_enquiry_flat — one row per enquiry, history pivoted out
--
--  Stage timestamps come from enquiry_events, never from the date
--  columns on the enquiry. A corrected date column would silently
--  rewrite history; an event row is what actually happened, when.
--  The date columns are still carried through for display.
-- ---------------------------------------------------------------------
create or replace view public.v_enquiry_flat
  with (security_invoker = true) as
with first_at as (
  select enquiry_id, to_status, min(occurred_at) as at
    from public.enquiry_events
   group by enquiry_id, to_status
),
pivoted as (
  select enquiry_id,
         max(at) filter (where to_status = 'new')           as at_new,
         max(at) filter (where to_status = 'contacted')     as at_contacted,
         max(at) filter (where to_status = 'survey_booked') as at_survey_booked,
         max(at) filter (where to_status = 'surveyed')      as at_surveyed,
         max(at) filter (where to_status = 'quoted')        as at_quoted,
         max(at) filter (where to_status = 'follow_up')     as at_follow_up,
         max(at) filter (where to_status = 'won')           as at_won,
         max(at) filter (where to_status = 'lost')          as at_lost,
         count(*)                                            as event_count
    from first_at
   group by enquiry_id
)
select
  e.id, e.ref, e.received_on, e.source, e.source_detail, e.status,
  e.customer_name, e.site_town, e.site_postcode,
  e.product_type, e.material, e.approx_units, e.property_type,
  e.survey_date, e.survey_slot, e.surveyor, e.survey_completed_on,
  e.survey_reschedule_count,
  e.quote_value, e.quote_sent_on, e.quote_expires_on, e.probability,
  e.target_install_from, e.target_install_to, e.customer_deadline,
  e.next_action, e.next_action_on,
  e.won_on, e.lost_on, e.lost_reason, e.lost_to, e.job_id,
  e.created_at, e.updated_at,

  d.month_start as received_month,
  d.week_start  as received_week,

  p.at_new, p.at_contacted, p.at_survey_booked, p.at_surveyed,
  p.at_quoted, p.at_follow_up, p.at_won, p.at_lost,
  coalesce(p.event_count, 0) as event_count,

  -- Stage gaps, in whole days, from the history.
  (p.at_contacted::date     - p.at_new::date)          as days_new_to_contacted,
  (p.at_survey_booked::date - p.at_contacted::date)    as days_contacted_to_booked,
  (p.at_surveyed::date      - p.at_survey_booked::date) as days_booked_to_surveyed,
  (p.at_quoted::date        - p.at_surveyed::date)     as days_surveyed_to_quoted,
  (coalesce(p.at_won, p.at_lost)::date - p.at_quoted::date) as days_quoted_to_decision,
  (coalesce(p.at_won, p.at_lost)::date - p.at_new::date)    as days_total,

  (current_date - e.received_on) as age_days,
  (e.status in ('won','lost'))   as is_closed,
  (e.status = 'won')             as is_won,
  (e.status = 'lost')            as is_lost,
  (e.status not in ('won','lost') and e.next_action_on < current_date) as is_overdue,
  (e.notes like '%[seed data]%') as is_seed
from public.enquiries e
left join pivoted  p on p.enquiry_id = e.id
left join public.dim_date d on d.d = e.received_on;

comment on view public.v_enquiry_flat is
  'One row per enquiry with its status history pivoted into columns. The base for most other views.';


-- ---------------------------------------------------------------------
--  3. v_enquiry_funnel — counts and values per month
--
--  Driven from dim_date so a month with no enquiries still appears.
--  Each stage counts enquiries that REACHED it, from the history, not
--  enquiries currently sitting in it.
-- ---------------------------------------------------------------------
create or replace view public.v_enquiry_funnel
  with (security_invoker = true) as
with months as (
  select distinct month_start
    from public.dim_date
   where month_start between date_trunc('month', current_date - interval '3 years')
                         and date_trunc('month', current_date)
)
select
  m.month_start as period,
  count(f.id)                                            as received,
  count(f.id) filter (where f.at_contacted is not null)   as contacted,
  count(f.id) filter (where f.at_survey_booked is not null) as survey_booked,
  count(f.id) filter (where f.at_surveyed is not null)    as surveyed,
  count(f.id) filter (where f.at_quoted is not null)      as quoted,
  count(f.id) filter (where f.is_won)                     as won,
  count(f.id) filter (where f.is_lost)                    as lost,
  count(f.id) filter (where not f.is_closed)              as still_open,

  coalesce(sum(f.quote_value) filter (where f.at_quoted is not null), 0)::numeric(12,2) as quoted_value,
  coalesce(sum(f.quote_value) filter (where f.is_won), 0)::numeric(12,2)                as won_value,
  coalesce(sum(f.quote_value) filter (where f.is_lost), 0)::numeric(12,2)               as lost_value,

  -- Rate plus its denominator, always together.
  round(100.0 * count(f.id) filter (where f.is_won)
        / nullif(count(f.id) filter (where f.is_closed), 0), 1) as win_rate,
  count(f.id) filter (where f.is_closed)                        as win_rate_n,

  round(100.0 * count(f.id) filter (where f.at_quoted is not null)
        / nullif(count(f.id), 0), 1)                            as quote_rate,
  count(f.id)                                                   as quote_rate_n
from months m
left join public.v_enquiry_flat f on f.received_month = m.month_start
group by m.month_start;

comment on view public.v_enquiry_funnel is
  'Monthly funnel. Stage columns count enquiries that reached the stage, from the event history.';


-- ---------------------------------------------------------------------
--  4. v_enquiry_cycle_times — medians, not averages
--
--  One slow job that sat for eight months would drag an average far
--  enough to be useless. percentile_cont(0.5) is the median.
-- ---------------------------------------------------------------------
create or replace view public.v_enquiry_cycle_times
  with (security_invoker = true) as
with months as (
  select distinct month_start
    from public.dim_date
   where month_start between date_trunc('month', current_date - interval '3 years')
                         and date_trunc('month', current_date)
)
select
  m.month_start as period,
  count(f.id) as n,
  percentile_cont(0.5) within group (order by f.days_new_to_contacted)
    filter (where f.days_new_to_contacted is not null) as median_days_to_contact,
  percentile_cont(0.5) within group (order by f.days_contacted_to_booked)
    filter (where f.days_contacted_to_booked is not null) as median_days_to_book_survey,
  percentile_cont(0.5) within group (order by f.days_booked_to_surveyed)
    filter (where f.days_booked_to_surveyed is not null) as median_days_to_survey,
  percentile_cont(0.5) within group (order by f.days_surveyed_to_quoted)
    filter (where f.days_surveyed_to_quoted is not null) as median_days_to_quote,
  percentile_cont(0.5) within group (order by f.days_quoted_to_decision)
    filter (where f.days_quoted_to_decision is not null) as median_days_to_decision,
  percentile_cont(0.5) within group (order by f.days_total)
    filter (where f.days_total is not null) as median_days_total,
  count(f.id) filter (where f.days_total is not null) as median_days_total_n
from months m
left join public.v_enquiry_flat f on f.received_month = m.month_start
group by m.month_start;


-- ---------------------------------------------------------------------
--  5. v_pipeline_open — what is live, and what it is worth
-- ---------------------------------------------------------------------
create or replace view public.v_pipeline_open
  with (security_invoker = true) as
select
  f.id, f.ref, f.customer_name, f.site_town, f.status, f.source,
  f.product_type, f.approx_units,
  f.received_on, f.age_days,
  f.survey_date, f.survey_slot, f.surveyor,
  f.quote_value, f.quote_sent_on, f.quote_expires_on, f.probability,
  f.next_action, f.next_action_on,
  f.target_install_from, f.target_install_to,

  round(coalesce(f.quote_value, 0) * coalesce(f.probability, 0) / 100.0, 2) as weighted_value,
  greatest(current_date - f.next_action_on, 0)                              as days_overdue,
  f.is_overdue,
  (f.quote_expires_on is not null and f.quote_expires_on < current_date)    as quote_expired,
  (current_date - coalesce(f.at_quoted, f.at_surveyed, f.at_contacted, f.at_new)::date)
                                                                            as days_since_last_event,
  -- Rough production load this would add if it lands, so the capacity
  -- chart can show pipeline against committed work.
  coalesce(f.approx_units, 1) * 1.5                                         as est_production_days
from public.v_enquiry_flat f
where f.status not in ('won','lost');

comment on view public.v_pipeline_open is
  'Live enquiries only. est_production_days is a rough 1.5 days per unit for the capacity chart, not a quote.';


-- ---------------------------------------------------------------------
--  6. v_lost_analysis — why work is lost, and what it was worth
-- ---------------------------------------------------------------------
create or replace view public.v_lost_analysis
  with (security_invoker = true) as
select
  d.month_start                       as period,
  coalesce(f.lost_reason, 'Not recorded') as lost_reason,
  count(*)                            as lost_count,
  coalesce(sum(f.quote_value), 0)::numeric(12,2)      as lost_value,
  round(avg(f.quote_value), 2)                         as avg_lost_value,
  count(*) filter (where f.lost_to is not null)        as lost_to_named_competitor
from public.v_enquiry_flat f
join public.dim_date d on d.d = f.lost_on
where f.is_lost
group by d.month_start, coalesce(f.lost_reason, 'Not recorded');


-- ---------------------------------------------------------------------
--  7. v_job_performance — baseline against plan against reality
--
--  Variance is measured against baseline_start / baseline_end, never
--  against planned_*. The plan moves every time a bar is dragged, so
--  measuring against it makes adherence read as 100% forever.
-- ---------------------------------------------------------------------
create or replace view public.v_job_performance
  with (security_invoker = true) as
select
  j.id, j.ref, j.name, j.client, j.enquiry_id, j.product_type,
  j.baseline_start, j.baseline_end,
  j.planned_start,  j.planned_end,
  j.actual_start,   j.actual_end,
  j.customer_deadline,
  j.estimated_days, j.actual_days,
  j.reschedule_count,

  (j.planned_start - j.baseline_start) as plan_start_drift_days,
  (j.planned_end   - j.baseline_end)   as plan_end_drift_days,
  (j.actual_start  - j.baseline_start) as actual_start_variance_days,
  (j.actual_end    - j.baseline_end)   as actual_end_variance_days,
  (j.actual_days   - j.estimated_days) as days_variance,

  case when j.estimated_days > 0
       then round(j.actual_days / j.estimated_days, 3) end as estimate_ratio,

  (j.actual_end is not null)                              as is_complete,
  (j.actual_end is not null and j.customer_deadline is not null
     and j.actual_end > j.customer_deadline)              as delivered_late,
  d.month_start                                           as completed_month,
  jsonb_array_length(coalesce(j.phases, '[]'::jsonb))     as stage_count
from public.jobs j
left join public.dim_date d on d.d = j.actual_end;


-- ---------------------------------------------------------------------
--  8. v_weekly_capacity — how full is April
--
--  The one chart that changes a decision, so it gets the honest version.
--  Committed days are counted by expanding each job's planned span
--  across working days, so a job spanning three weeks contributes to all
--  three rather than landing entirely in its start week.
--
--  Weeks with no capacity row fall back to 15 job-days: a five-day week
--  running three jobs at once. Change the default here, or better, put a
--  row in capacity_weeks.
-- ---------------------------------------------------------------------
create or replace view public.v_weekly_capacity
  with (security_invoker = true) as
with weeks as (
  select distinct week_start
    from public.dim_date
   where week_start between date_trunc('week', current_date - interval '12 months')
                        and date_trunc('week', current_date + interval '9 months')
),
committed as (
  select d.week_start, count(*)::numeric as days
    from public.jobs j
    join public.dim_date d
      on d.d between j.planned_start and j.planned_end
     and d.is_working_day
   where j.planned_start is not null
   group by d.week_start
),
pipeline as (
  select d.week_start, sum(p.est_production_days * coalesce(p.probability, 0) / 100.0)::numeric as weighted_days
    from public.v_pipeline_open p
    join public.dim_date d
      on d.d between coalesce(p.target_install_from, current_date + 30)
                 and coalesce(p.target_install_to,   current_date + 60)
     and d.is_working_day
   group by d.week_start
)
select
  w.week_start,
  coalesce(c.available_days, 15.0)                       as available_days,
  coalesce(cm.days, 0)                                   as committed_days,
  coalesce(pl.weighted_days, 0)::numeric(8,1)            as weighted_pipeline_days,
  greatest(coalesce(c.available_days, 15.0) - coalesce(cm.days, 0), 0) as free_days,
  round(100.0 * coalesce(cm.days, 0)
        / nullif(coalesce(c.available_days, 15.0), 0), 1) as utilisation_rate,
  coalesce(c.available_days, 15.0)                        as utilisation_rate_n,
  (coalesce(cm.days, 0) > coalesce(c.available_days, 15.0)) as over_capacity,
  (c.week_start is null)                                   as using_default_capacity,
  c.note                                                   as capacity_note
from weeks w
left join public.capacity_weeks c  on c.week_start  = w.week_start
left join committed             cm on cm.week_start = w.week_start
left join pipeline              pl on pl.week_start = w.week_start;

comment on view public.v_weekly_capacity is
  'Available against committed job-days per ISO week. using_default_capacity flags weeks with no capacity_weeks row.';


-- ---------------------------------------------------------------------
--  9. v_promise_vs_delivery — did we do it when we said
-- ---------------------------------------------------------------------
create or replace view public.v_promise_vs_delivery
  with (security_invoker = true) as
select
  j.id as job_id, j.ref, j.name, j.client,
  coalesce(pt.product, 'Not recorded') as product_type,
  e.ref as enquiry_ref,
  e.target_install_from, e.target_install_to,
  j.customer_deadline,
  j.actual_end,
  d.month_start as completed_month,
  (j.actual_end - coalesce(j.customer_deadline, e.target_install_to)) as days_late,
  (j.actual_end is not null
     and coalesce(j.customer_deadline, e.target_install_to) is not null
     and j.actual_end <= coalesce(j.customer_deadline, e.target_install_to)) as on_time
from public.jobs j
left join public.enquiries e on e.id = j.enquiry_id
left join public.dim_date  d on d.d  = j.actual_end
left join lateral (
  select p as product
    from unnest(case when cardinality(j.product_type) > 0
                     then j.product_type else e.product_type end) as p
   limit 1
) pt on true
where j.actual_end is not null;


-- ---------------------------------------------------------------------
--  10. v_estimate_accuracy — do we know how long our own work takes
-- ---------------------------------------------------------------------
create or replace view public.v_estimate_accuracy
  with (security_invoker = true) as
select
  d.month_start                        as period,
  coalesce(pt.product, 'Not recorded') as product_type,
  count(*)                                              as jobs,
  round(avg(j.estimated_days), 1)                       as avg_estimated_days,
  round(avg(j.actual_days), 1)                          as avg_actual_days,
  round(avg(j.actual_days) / nullif(avg(j.estimated_days), 0), 3) as estimate_ratio,
  count(*) filter (where j.estimated_days is not null
                     and j.actual_days is not null)     as estimate_ratio_n,
  round(100.0 * count(*) filter (where j.actual_days <= j.estimated_days)
        / nullif(count(*) filter (where j.estimated_days is not null
                                    and j.actual_days is not null), 0), 1) as within_estimate_rate,
  count(*) filter (where j.estimated_days is not null
                     and j.actual_days is not null)     as within_estimate_rate_n
from public.jobs j
join public.dim_date d on d.d = j.actual_end
left join lateral (
  select p as product from unnest(j.product_type) as p limit 1
) pt on true
where j.actual_end is not null
group by d.month_start, coalesce(pt.product, 'Not recorded');


-- ---------------------------------------------------------------------
--  11. v_source_performance — where the good work comes from
--
--  revenue_per_production_day only counts enquiries that became jobs
--  with recorded actual days. Work typed straight onto the board never
--  had an enquiry and is invisible here — see docs/gaps.md.
-- ---------------------------------------------------------------------
create or replace view public.v_source_performance
  with (security_invoker = true) as
select
  d.month_start as period,
  f.source,
  count(*)                                                  as enquiries,
  count(*) filter (where f.is_won)                          as won,
  count(*) filter (where f.is_closed)                       as closed,
  round(100.0 * count(*) filter (where f.is_won)
        / nullif(count(*) filter (where f.is_closed), 0), 1) as win_rate,
  count(*) filter (where f.is_closed)                        as win_rate_n,
  coalesce(sum(f.quote_value) filter (where f.is_won), 0)::numeric(12,2) as revenue,
  round(avg(f.quote_value) filter (where f.is_won), 2)                    as avg_won_value,
  round(
    sum(f.quote_value) filter (where f.is_won and jp.actual_days > 0)
    / nullif(sum(jp.actual_days) filter (where f.is_won), 0), 2)          as revenue_per_production_day,
  count(*) filter (where f.is_won and jp.actual_days > 0)                 as revenue_per_production_day_n
from public.v_enquiry_flat f
join public.dim_date d on d.d = f.received_on
left join public.jobs jp on jp.id = f.job_id
group by d.month_start, f.source;


-- ---------------------------------------------------------------------
--  12. v_survey_diary and v_overdue_actions
--
--  The two lists the enquiry board shows above everything else. They are
--  views rather than component queries for the same reason as the rest:
--  "what counts as overdue" is a definition, and it belongs in one place.
-- ---------------------------------------------------------------------
create or replace view public.v_survey_diary
  with (security_invoker = true) as
select
  f.id, f.ref, f.customer_name, f.site_town, f.site_postcode,
  f.survey_date, f.survey_slot, f.surveyor, f.status,
  f.product_type, f.approx_units, f.access_notes,
  d.week_start,
  (f.survey_date = current_date)                        as is_today,
  (f.survey_date - current_date)                        as days_away
from (select vf.*, e.access_notes
        from public.v_enquiry_flat vf
        join public.enquiries e on e.id = vf.id) f
join public.dim_date d on d.d = f.survey_date
where f.survey_date is not null
  and f.status not in ('won','lost')
  and f.survey_completed_on is null;

create or replace view public.v_overdue_actions
  with (security_invoker = true) as
select
  f.id, f.ref, f.customer_name, f.site_town, f.status, f.source,
  f.next_action, f.next_action_on, f.quote_value, f.probability,
  (current_date - f.next_action_on) as days_overdue,
  f.age_days,
  round(coalesce(f.quote_value, 0) * coalesce(f.probability, 0) / 100.0, 2) as weighted_value
from public.v_enquiry_flat f
where f.status not in ('won','lost')
  and f.next_action_on is not null
  and f.next_action_on < current_date;

comment on view public.v_overdue_actions is
  'Follow-ups past their date. The single largest source of lost work in firms this size.';


-- ---------------------------------------------------------------------
--  13. mv_dashboard_summary — the headline tiles
--
--  Materialised because it scans everything and is read on every page
--  load. Refresh nightly, or call refresh_dashboard() from the UI.
--
--  Rolling 90 days against the 90 before it, because a tile without a
--  direction is decoration.
-- ---------------------------------------------------------------------
drop materialized view if exists public.mv_dashboard_summary;
create materialized view public.mv_dashboard_summary as
with cur as (
  select * from public.v_enquiry_flat
   where received_on > current_date - 90
),
prev as (
  select * from public.v_enquiry_flat
   where received_on between current_date - 180 and current_date - 91
)
select
  now()                                                     as generated_at,
  (select count(*) from cur)                                as enquiries,
  (select count(*) from prev)                               as enquiries_prev,

  (select round(100.0 * count(*) filter (where is_won)
          / nullif(count(*) filter (where is_closed), 0), 1) from cur)  as win_rate,
  (select count(*) filter (where is_closed) from cur)                    as win_rate_n,
  (select round(100.0 * count(*) filter (where is_won)
          / nullif(count(*) filter (where is_closed), 0), 1) from prev) as win_rate_prev,

  (select coalesce(sum(weighted_value), 0)::numeric(12,2)
     from public.v_pipeline_open)                           as weighted_pipeline,
  (select coalesce(sum(quote_value), 0)::numeric(12,2)
     from public.v_pipeline_open)                           as open_pipeline_value,
  (select count(*) from public.v_pipeline_open)             as open_enquiries,
  (select count(*) from public.v_overdue_actions)           as overdue_actions,
  (select count(*) from public.v_survey_diary
    where survey_date between current_date and current_date + 7) as surveys_next_7_days,

  -- How many weeks ahead the workshop is committed before it has a
  -- week with free capacity.
  (select count(*) from public.v_weekly_capacity
    where week_start >= date_trunc('week', current_date)
      and free_days <= 0)                                   as weeks_at_capacity,
  (select round(avg(utilisation_rate), 1) from public.v_weekly_capacity
    where week_start between date_trunc('week', current_date)
                         and date_trunc('week', current_date + interval '8 weeks')) as forward_utilisation_rate,
  (select count(*) from public.v_weekly_capacity
    where week_start between date_trunc('week', current_date)
                         and date_trunc('week', current_date + interval '8 weeks')) as forward_utilisation_rate_n,

  (select coalesce(sum(quote_value), 0)::numeric(12,2) from cur where is_won)  as won_value,
  (select coalesce(sum(quote_value), 0)::numeric(12,2) from prev where is_won) as won_value_prev,

  (select round(100.0 * count(*) filter (where on_time)
          / nullif(count(*), 0), 1) from public.v_promise_vs_delivery
    where completed_month > current_date - interval '12 months')      as on_time_rate,
  (select count(*) from public.v_promise_vs_delivery
    where completed_month > current_date - interval '12 months')      as on_time_rate_n;

create unique index if not exists mv_dashboard_summary_one_row
  on public.mv_dashboard_summary (generated_at);

comment on materialized view public.mv_dashboard_summary is
  'Headline tiles, one row. Refresh nightly via pg_cron or by calling refresh_dashboard().';


create or replace function public.refresh_dashboard()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
begin
  refresh materialized view concurrently public.mv_dashboard_summary;
  return now();
end;
$$;

revoke all on function public.refresh_dashboard() from public, anon;
grant execute on function public.refresh_dashboard() to authenticated;

-- Nightly refresh. Enable pg_cron under Database -> Extensions first,
-- then uncomment:
--
--   select cron.schedule('refresh-dashboard', '15 3 * * *',
--                        $$select public.refresh_dashboard()$$);


-- ---------------------------------------------------------------------
--  14. Grants
--
--  Views run with the privileges of their owner but respect the RLS of
--  the tables beneath them, so `authenticated` sees exactly what the
--  policies allow and `anon` still sees nothing.
-- ---------------------------------------------------------------------
grant select on
  public.v_enquiry_flat, public.v_enquiry_funnel, public.v_enquiry_cycle_times,
  public.v_pipeline_open, public.v_lost_analysis, public.v_job_performance,
  public.v_weekly_capacity, public.v_promise_vs_delivery, public.v_estimate_accuracy,
  public.v_source_performance, public.v_survey_diary, public.v_overdue_actions,
  public.mv_dashboard_summary, public.dim_date
to authenticated;


-- #####################################################################
-- ##  20260910_0005_transition_rules.sql
-- #####################################################################

-- =====================================================================
--  Phase 4 — Status transition rules and enquiry conversion
--
--  The plan puts these rules in a server action. This build has no server
--  runtime, and row-level security lets any signed-in member of staff
--  update an enquiry directly, so a rule that lives only in the client is
--  not a rule. They are enforced here as a trigger, where nothing can go
--  round them.
--
--  Cheap to write, and it is the only thing that makes the analytics
--  worth anything twelve months from now: a quoted enquiry with no quote
--  value poisons every conversion and value metric downstream.
--
--  Run in the Supabase SQL Editor. Idempotent.
--  Rollback: 20260910_0005_transition_rules_down.sql
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. What each status requires before an enquiry may enter it
--
--    contacted      first_contacted_on
--    survey_booked  survey_date, surveyor
--    surveyed       survey_completed_on
--    quoted         quote_value, quote_sent_on
--    won            quote_value
--    lost           lost_reason
--
--  The error names the missing field, so the UI can open the drawer
--  focused on it rather than saying "invalid".
-- ---------------------------------------------------------------------
create or replace function public.check_enquiry_transition()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  missing text[] := '{}';
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  case new.status
    when 'contacted' then
      if new.first_contacted_on is null then missing := missing || 'first_contacted_on'; end if;

    when 'survey_booked' then
      if new.survey_date is null then missing := missing || 'survey_date'; end if;
      if coalesce(trim(new.surveyor), '') = '' then missing := missing || 'surveyor'; end if;

    when 'surveyed' then
      if new.survey_completed_on is null then missing := missing || 'survey_completed_on'; end if;

    when 'quoted' then
      if new.quote_value is null then missing := missing || 'quote_value'; end if;
      if new.quote_sent_on is null then missing := missing || 'quote_sent_on'; end if;

    when 'won' then
      if new.quote_value is null then missing := missing || 'quote_value'; end if;

    when 'lost' then
      if coalesce(trim(new.lost_reason), '') = '' then missing := missing || 'lost_reason'; end if;

    else
      null;   -- new, follow_up and on_hold require nothing
  end case;

  if array_length(missing, 1) > 0 then
    raise exception
      'Cannot move % to %: missing %',
      coalesce(new.ref, 'enquiry'), new.status, array_to_string(missing, ', ')
      using errcode   = 'check_violation',
            hint      = array_to_string(missing, ','),
            detail    = new.status::text;
  end if;

  -- Keep the outcome dates honest without making the caller supply them.
  if new.status = 'won'  and new.won_on  is null then new.won_on  := current_date; end if;
  if new.status = 'lost' and new.lost_on is null then new.lost_on := current_date; end if;

  return new;
end;
$$;

drop trigger if exists enquiries_check_transition on public.enquiries;
create trigger enquiries_check_transition
  before insert or update of status on public.enquiries
  for each row execute function public.check_enquiry_transition();


-- ---------------------------------------------------------------------
--  2. Convert a won enquiry into a job
--
--  Does both halves of the link in one transaction. A job created from
--  an enquiry without the link is worse than no job at all: it silently
--  breaks every cross-domain metric, and nothing later can tell that it
--  should have been connected.
--
--  estimated_days is seeded from what this product type has actually
--  taken before, falling back to a fortnight when there is no history.
-- ---------------------------------------------------------------------
create or replace function public.convert_enquiry_to_job(
  p_enquiry_id uuid,
  p_name       text default null,
  p_start      date default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  e        public.enquiries%rowtype;
  new_id   uuid;
  est      numeric(6,1);
  job_name text;
begin
  select * into e from public.enquiries where id = p_enquiry_id;
  if not found then
    raise exception 'No enquiry with id %', p_enquiry_id using errcode = 'no_data_found';
  end if;

  if e.job_id is not null then
    raise exception 'Enquiry % already has a job', e.ref using errcode = 'unique_violation';
  end if;

  select round(avg(j.actual_days), 1) into est
    from public.jobs j
   where j.actual_days is not null
     and j.product_type && e.product_type;

  est := coalesce(est, 10.0);

  job_name := coalesce(nullif(trim(p_name), ''),
                       coalesce(e.customer_name, 'Job') || ' — ' ||
                       coalesce(e.product_type[1], 'joinery'));

  insert into public.jobs (name, client, ref, deadline, customer_deadline,
                           enquiry_id, product_type, estimated_days, phases)
  values (job_name,
          e.customer_name,
          e.ref,
          coalesce(e.customer_deadline, e.target_install_to),
          coalesce(e.customer_deadline, e.target_install_to),
          e.id,
          e.product_type,
          est,
          '[]'::jsonb)
  returning id into new_id;

  update public.enquiries set job_id = new_id where id = e.id;

  return new_id;
end;
$$;

revoke all on function public.convert_enquiry_to_job(uuid, text, date) from public, anon;
grant execute on function public.convert_enquiry_to_job(uuid, text, date) to authenticated;

comment on function public.convert_enquiry_to_job(uuid, text, date) is
  'Creates a job from a won enquiry and links both sides. Never create the job separately.';


-- #####################################################################
-- ##  20260910_0006_revoke_anon.sql
-- #####################################################################

-- =====================================================================
--  Close an anonymous read on the dashboard summary
--
--  FOUND IN PRODUCTION, 10 September 2026, minutes after install.sql ran.
--
--  Probing the live API with the publishable key returned the entire
--  mv_dashboard_summary row to an anonymous caller:
--
--    GET /rest/v1/mv_dashboard_summary   ->  200
--    [{"generated_at":"...","enquiries":0,"win_rate":null, ...}]
--
--  It was all zeros only because there was no data yet. With real
--  enquiries in it, anyone holding the publishable key — which is in the
--  browser and in this repository, by design — could have read the
--  firm's enquiry volume, win rate, weighted pipeline and revenue.
--
--  WHY IT HAPPENED
--  ---------------
--  Two things combined.
--
--  1. Supabase sets ALTER DEFAULT PRIVILEGES on the public schema so
--     that new tables and views are granted to `anon` and `authenticated`
--     automatically. Granting explicitly to `authenticated`, as the view
--     migration did, adds a grant; it does not remove the one that was
--     already there.
--
--  2. Row-level security does not apply to materialised views. Every
--     ordinary view and table here was still safe, because RLS filtered
--     anon down to nothing — which is why they all returned `[]` and
--     looked identical to a locked door. The materialised view had no
--     such backstop and simply handed the row over.
--
--  The lesson is that a 200 with an empty array is not proof of
--  anything. The only object that behaved differently was the only one
--  RLS could not protect.
--
--  Run in the Supabase SQL Editor. Idempotent.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. The actual hole
-- ---------------------------------------------------------------------
revoke all on public.mv_dashboard_summary from anon;
revoke all on public.mv_dashboard_summary from public;
grant select on public.mv_dashboard_summary to authenticated;


-- ---------------------------------------------------------------------
--  2. Belt and braces on everything else
--
--  These are all protected by RLS already, so anon reads nothing from
--  them today. The grant should not be sitting there regardless: it is
--  one accidental `disable row level security`, or one permissive policy
--  written in a hurry, away from being live. Take the grant away and the
--  mistake has to be made twice.
-- ---------------------------------------------------------------------
revoke all on public.enquiries       from anon;
revoke all on public.enquiry_events  from anon;
revoke all on public.enquiry_ref_seq from anon;
revoke all on public.job_events      from anon;
revoke all on public.capacity_weeks  from anon;
revoke all on public.dim_date        from anon;
revoke all on public.jobs            from anon;

revoke all on public.v_enquiry_flat        from anon;
revoke all on public.v_enquiry_funnel      from anon;
revoke all on public.v_enquiry_cycle_times from anon;
revoke all on public.v_pipeline_open       from anon;
revoke all on public.v_lost_analysis       from anon;
revoke all on public.v_job_performance     from anon;
revoke all on public.v_weekly_capacity     from anon;
revoke all on public.v_promise_vs_delivery from anon;
revoke all on public.v_estimate_accuracy   from anon;
revoke all on public.v_source_performance  from anon;
revoke all on public.v_survey_diary        from anon;
revoke all on public.v_overdue_actions     from anon;


-- ---------------------------------------------------------------------
--  3. Stop the next object inheriting the same grant
--
--  Without this, the next table or view added to this schema arrives
--  readable by anon all over again.
-- ---------------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon;


-- ---------------------------------------------------------------------
--  4. Prove it
--
--  Should return no rows. Any row here is an object `anon` can still
--  read; check it is one you meant to publish.
-- ---------------------------------------------------------------------
select table_name, privilege_type
  from information_schema.role_table_grants
 where grantee = 'anon'
   and table_schema = 'public'
 order by table_name, privilege_type;


-- #####################################################################
-- ##  20260910_0007_owner_id_optional.sql
-- #####################################################################

-- =====================================================================
--  Let a job exist without an owner
--
--  `jobs.owner_id` is `not null default auth.uid()`. That was right when
--  it decided who could see the row. Migration 0002 demoted it to a
--  record of who created the job, and a not-null provenance column that
--  can only be filled by a signed-in browser is a contradiction:
--  `auth.uid()` returns null anywhere else, so the insert fails.
--
--  Found by the acceptance script, which creates a test job from the SQL
--  Editor and got:
--
--    23502: null value in column "owner_id" of relation "jobs"
--
--  The same would happen to a data import, an admin fix, a scheduled
--  task, or anything server-side that ever needs to create a job. It
--  never showed up before because the planner is the only thing that has
--  ever written to this table, and it always runs as a signed-in user.
--
--  Nothing depends on the column being populated: row-level security
--  stopped reading it in 0002, and no view or index requires it.
--
--  Run in the Supabase SQL Editor. Idempotent.
-- =====================================================================

alter table public.jobs alter column owner_id drop not null;

comment on column public.jobs.owner_id is
  'Who created the job, when a signed-in user did. Provenance only since 10 Sep 2026 — access is workshop-wide, not owner-scoped. Nullable since jobs can also be created by an import or a scheduled task, where there is no auth.uid() to record.';


-- #####################################################################
-- ##  20260910_0008_fix_pipeline_spread.sql
-- #####################################################################

-- =====================================================================
--  Fix the weighted pipeline in v_weekly_capacity
--
--  The capacity chart showed a pipeline line peaking at 178 job-days
--  against a workshop capacity of 15, which flattened every bar into an
--  unreadable strip along the bottom. The pipeline was not large. The
--  sum was wrong, twice.
--
--  1. EVERY DAY COUNTED THE WHOLE JOB
--     The view joined each open enquiry to every day in its install
--     window and summed the full weighted figure on each one. An
--     enquiry with a five-week window contributed its entire weighted
--     value twenty-five times over. The fix spreads the weighted days
--     evenly across the working days of the window, so an enquiry
--     contributes its own size in total and no more, distributed across
--     the weeks it might actually land in.
--
--  2. OPEN WORK WAS PLOTTED IN THE PAST
--     target_install_from comes off the quote, so an enquiry quoted in
--     June with a window in August is still open today and was being
--     drawn into August — weeks that have already gone. Nothing can be
--     built in the past. Any window that has slipped behind today is now
--     clamped forward to this week, which is where that work would
--     actually have to go.
--
--  The bug was invisible until there was enough seeded data to make the
--  scale absurd. With three enquiries it looked like a plausible line.
--
--  Run in the Supabase SQL Editor. Idempotent.
-- =====================================================================

create or replace view public.v_weekly_capacity
  with (security_invoker = true) as
with weeks as (
  select distinct week_start
    from public.dim_date
   where week_start between date_trunc('week', current_date - interval '12 months')
                        and date_trunc('week', current_date + interval '9 months')
),
committed as (
  select d.week_start, count(*)::numeric as days
    from public.jobs j
    join public.dim_date d
      on d.d between j.planned_start and j.planned_end
     and d.is_working_day
   where j.planned_start is not null
   group by d.week_start
),
-- Each open enquiry, its weighted size, and the window it could land in,
-- never earlier than today.
windows as (
  select
    p.id,
    greatest(p.est_production_days * coalesce(p.probability, 0) / 100.0, 0) as weighted_days,
    greatest(coalesce(p.target_install_from, current_date + 30), current_date) as win_from,
    greatest(
      greatest(coalesce(p.target_install_to, current_date + 60), current_date + 10),
      greatest(coalesce(p.target_install_from, current_date + 30), current_date)
    ) as win_to
  from public.v_pipeline_open p
),
-- One row per working day of each window, carrying how many days that
-- window has, so the weight can be divided rather than repeated.
spread as (
  select
    w.id,
    w.weighted_days,
    d.week_start,
    count(*) over (partition by w.id) as days_in_window
  from windows w
  join public.dim_date d
    on d.d between w.win_from and w.win_to
   and d.is_working_day
),
pipeline as (
  select week_start,
         sum(weighted_days / nullif(days_in_window, 0))::numeric as weighted_days
    from spread
   group by week_start
)
-- COLUMN ORDER AND TYPES ARE FIXED BY THE EXISTING VIEW.
-- `create or replace view` refuses to retype a column or slot a new one
-- into the middle, and mv_dashboard_summary depends on this view, so
-- dropping it would take the summary with it. weighted_pipeline_days
-- therefore keeps its numeric(8,1), and the new column goes on the end.
select
  w.week_start,
  coalesce(c.available_days, 15.0)                        as available_days,
  coalesce(cm.days, 0)                                    as committed_days,
  round(coalesce(pl.weighted_days, 0), 1)::numeric(8,1)   as weighted_pipeline_days,
  greatest(coalesce(c.available_days, 15.0) - coalesce(cm.days, 0), 0) as free_days,
  round(100.0 * coalesce(cm.days, 0)
        / nullif(coalesce(c.available_days, 15.0), 0), 1) as utilisation_rate,
  coalesce(c.available_days, 15.0)                        as utilisation_rate_n,
  (coalesce(cm.days, 0) > coalesce(c.available_days, 15.0)) as over_capacity,
  (c.week_start is null)                                   as using_default_capacity,
  c.note                                                   as capacity_note,
  -- Committed work plus what the pipeline would add, against what the
  -- week can take. The number that says "do not sell into April".
  (coalesce(cm.days, 0) + coalesce(pl.weighted_days, 0)
     > coalesce(c.available_days, 15.0))                   as over_when_pipeline_lands
from weeks w
left join public.capacity_weeks c  on c.week_start  = w.week_start
left join committed             cm on cm.week_start = w.week_start
left join pipeline              pl on pl.week_start = w.week_start;

comment on view public.v_weekly_capacity is
  'Available against committed job-days per ISO week. Weighted pipeline is spread across the working days of each install window, never repeated per day, and never plotted before today.';

grant select on public.v_weekly_capacity to authenticated;
revoke all on public.v_weekly_capacity from anon;

select public.refresh_dashboard();

-- What the chart will now draw. weighted_pipeline_days should sit in the
-- same range as committed_days, not ten times it.
select week_start, available_days, committed_days, weighted_pipeline_days,
       over_capacity, over_when_pipeline_lands
  from public.v_weekly_capacity
 where week_start between date_trunc('week', current_date - interval '4 weeks')
                      and date_trunc('week', current_date + interval '16 weeks')
 order by week_start;


