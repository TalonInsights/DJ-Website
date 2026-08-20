-- =====================================================================
--  David Jackson & Son — Production Planning
--  Supabase schema, row-level security and retention helpers
--
--  Run this once in the Supabase SQL Editor after creating the project.
--  Project region MUST be London (eu-west-2) — see docs/GDPR.md.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. Jobs table
--
--  Job-level fields are real columns so they can be sorted and indexed.
--  Stages live in a JSONB array because the app always reads and writes
--  a whole job at once, and the stage list is short and fixed.
--
--  Personal data held here: `client` (may be an individual's name) and
--  `phases[].who` (a member of staff). Nothing else. Do not add phone
--  numbers, addresses or emails to this table — the quoting side of the
--  website handles customer contact separately.
-- ---------------------------------------------------------------------
create table if not exists public.jobs (
  id          uuid primary key default gen_random_uuid(),
  owner_id    uuid not null default auth.uid()
                references auth.users (id) on delete cascade,

  ref         text,
  name        text not null check (length(name) between 1 and 200),
  client      text check (length(client) <= 200),
  deadline    date,
  phases      jsonb not null default '[]'::jsonb check (jsonb_typeof(phases) = 'array'),

  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table  public.jobs         is 'Workshop production schedule. Contains personal data (client and staff names) — see docs/GDPR.md.';
comment on column public.jobs.phases  is 'Array of {key, start, end, who}. `who` is a staff name and is personal data.';
comment on column public.jobs.owner_id is 'Owning auth user. Enforced by RLS; a user can never see another user''s jobs.';


-- ---------------------------------------------------------------------
--  2. Keep updated_at honest
-- ---------------------------------------------------------------------
create or replace function public.touch_updated_at()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists jobs_touch_updated_at on public.jobs;
create trigger jobs_touch_updated_at
  before update on public.jobs
  for each row execute function public.touch_updated_at();


-- ---------------------------------------------------------------------
--  3. Row-level security
--
--  Default-deny. Every policy is scoped to `authenticated` and to rows
--  the caller owns, so the public anon key cannot read anything at all.
-- ---------------------------------------------------------------------
alter table public.jobs enable row level security;
alter table public.jobs force row level security;

drop policy if exists jobs_select_own on public.jobs;
create policy jobs_select_own on public.jobs
  for select to authenticated
  using (owner_id = (select auth.uid()));

drop policy if exists jobs_insert_own on public.jobs;
create policy jobs_insert_own on public.jobs
  for insert to authenticated
  with check (owner_id = (select auth.uid()));

drop policy if exists jobs_update_own on public.jobs;
create policy jobs_update_own on public.jobs
  for update to authenticated
  using      (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()));

drop policy if exists jobs_delete_own on public.jobs;
create policy jobs_delete_own on public.jobs
  for delete to authenticated
  using (owner_id = (select auth.uid()));


-- ---------------------------------------------------------------------
--  4. Indexes
-- ---------------------------------------------------------------------
create index if not exists jobs_owner_deadline_idx on public.jobs (owner_id, deadline);
create index if not exists jobs_owner_updated_idx  on public.jobs (owner_id, updated_at desc);


-- ---------------------------------------------------------------------
--  5. Storage limitation (UK GDPR Art. 5(1)(e))
--
--  Finished jobs should not sit on the board forever. This function
--  deletes jobs whose deadline passed more than `keep_months` ago.
--  Nothing calls it automatically — schedule it with pg_cron once you
--  have agreed a retention period, or run it by hand.
--
--    select public.purge_old_jobs(24);
--
--  To schedule monthly (Database → Extensions → enable pg_cron first):
--
--    select cron.schedule(
--      'purge-old-jobs', '0 3 1 * *',
--      $$select public.purge_old_jobs(24)$$
--    );
-- ---------------------------------------------------------------------
create or replace function public.purge_old_jobs(keep_months int default 24)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  removed integer;
begin
  delete from public.jobs
   where deadline is not null
     and deadline < (current_date - make_interval(months => keep_months))
  returning 1 into removed;

  get diagnostics removed = row_count;
  return removed;
end;
$$;

revoke all on function public.purge_old_jobs(int) from public, anon, authenticated;
