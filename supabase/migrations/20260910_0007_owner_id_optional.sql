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
