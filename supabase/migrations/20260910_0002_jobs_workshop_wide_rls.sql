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
