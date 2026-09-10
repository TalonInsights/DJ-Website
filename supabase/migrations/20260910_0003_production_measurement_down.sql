-- =====================================================================
--  Rollback for 20260910_0003_production_measurement.sql
--
--  DESTRUCTIVE. Drops all schedule history and every baseline.
--  That history cannot be reconstructed afterwards — the planner
--  overwrites its own plan — so only run this on a scratch database.
-- =====================================================================

drop trigger  if exists jobs_log_schedule on public.jobs;
drop trigger  if exists jobs_derive_plan  on public.jobs;
drop trigger  if exists capacity_weeks_touch_updated_at on public.capacity_weeks;

drop function if exists public.log_job_schedule();
drop function if exists public.jobs_derive_plan();

drop table if exists public.job_events;
drop table if exists public.capacity_weeks;

alter table public.jobs
  drop column if exists planned_start,
  drop column if exists planned_end,
  drop column if exists baseline_start,
  drop column if exists baseline_end,
  drop column if exists actual_start,
  drop column if exists actual_end,
  drop column if exists estimated_days,
  drop column if exists actual_days,
  drop column if exists reschedule_count,
  drop column if exists enquiry_id,
  drop column if exists product_type,
  drop column if exists customer_deadline;

drop index if exists public.jobs_enquiry_idx;
drop index if exists public.jobs_planned_idx;
drop index if exists public.jobs_actual_idx;
