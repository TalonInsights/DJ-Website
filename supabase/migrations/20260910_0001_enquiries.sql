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
