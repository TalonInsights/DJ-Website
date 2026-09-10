-- =====================================================================
--  Clear every job from the schedule
--
--  DESTRUCTIVE AND IRREVERSIBLE. This removes ALL rows from public.jobs,
--  not just seeded ones. There is no undo short of point-in-time
--  recovery, which has not been confirmed as available on this plan.
--
--  Written for the state on 10 September 2026, where every job on the
--  board was made up during testing of the planner and the client
--  confirmed they could go. If there is ever real work on that board,
--  do not run this file — use the targeted teardown instead:
--
--      delete from public.jobs where ref like 'TEST-%';
--
--  WHAT ELSE MOVES
--    * job_events cascades, so the schedule history goes with the jobs.
--    * enquiries.job_id is ON DELETE SET NULL, so any linked enquiry
--      survives and simply becomes unlinked. Nothing in the pipeline is
--      lost, and those enquiries become available for the jobs seed to
--      attach to again.
--
--  It prints what it removed, so there is a record of what was there.
-- =====================================================================

-- Keep a copy of what is about to go, so the result is a list rather
-- than a number. Temporary, so it disappears with the session.
drop table if exists _removed_jobs;
create temp table _removed_jobs as
select id, ref, name, client, planned_start, planned_end, actual_end, enquiry_id
  from public.jobs;

delete from public.jobs;

-- Every row of the result carries the two counts, so a single glance
-- confirms the table is empty and nothing in the pipeline was harmed.
select
  (select count(*) from public.jobs)                                as jobs_remaining,
  (select count(*) from public.enquiries)                           as enquiries_untouched,
  coalesce(r.ref, '(no reference)')                                 as removed_ref,
  r.name                                                            as removed_name,
  r.client,
  r.planned_start,
  r.planned_end
from _removed_jobs r
order by r.name;
