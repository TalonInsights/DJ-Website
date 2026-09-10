-- =====================================================================
--  Rollback for 20260910_0002_jobs_workshop_wide_rls.sql
--
--  Restores owner-scoped access to `jobs`.
--
--  WARNING: after this runs, every job becomes invisible to everyone
--  except the account that created it, and any dashboard joining
--  enquiries to jobs will return nothing across users.
-- =====================================================================

drop policy if exists jobs_select_staff on public.jobs;
drop policy if exists jobs_insert_staff on public.jobs;
drop policy if exists jobs_update_staff on public.jobs;
drop policy if exists jobs_delete_staff on public.jobs;

create policy jobs_select_own on public.jobs
  for select to authenticated
  using (owner_id = (select auth.uid()));

create policy jobs_insert_own on public.jobs
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

create policy jobs_update_own on public.jobs
  for update to authenticated
  using      (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

create policy jobs_delete_own on public.jobs
  for delete to authenticated
  using (owner_id = (select auth.uid()));

drop index if exists public.jobs_deadline_idx;
drop index if exists public.jobs_updated_idx;

comment on column public.jobs.owner_id is
  'Owning auth user. Enforced by RLS; a user can never see another user''s jobs.';
