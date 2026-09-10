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
