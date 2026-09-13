-- =====================================================================
--  Keep the figures, drop the paperwork
--
--  THE PROBLEM THIS SOLVES, HONESTLY STATED
--  ----------------------------------------
--  This workshop books somewhere near 40 jobs and 200 enquiries a year.
--  Postgres would not notice a century of that, so nobody should pretend
--  the database is straining. Three real problems do exist:
--
--    1. GDPR. Enquiries hold names, addresses, phone numbers and email
--       addresses. Keeping them for ever is the thing the law actually
--       objects to, and "we need it for our statistics" is not a defence
--       when the statistics do not need the names.
--
--    2. The planner was fetching every job ever recorded on every load,
--       including work finished two years ago that it never draws.
--
--    3. Anything measured only from live detail can only reach back as
--       far as the detail is kept. Delete the detail and the trend line
--       goes with it, which is exactly why firms never delete anything.
--
--  All three dissolve the same way: compute the month's figures ONCE,
--  while the detail is still there, and keep those. A month of trading
--  becomes one row of counts and sums with no personal data in it at
--  all. Twenty years of history is then about 240 rows, and the rows
--  that carry a person's name can be deleted on a schedule without
--  losing a single figure on the dashboard.
--
--  THE SHAPE
--  ---------
--    roll up  ->  the month's figures are written to fact_month
--    seal     ->  the month is declared final; views read the fact row
--                 from here on and stop recomputing it
--    purge    ->  the personal detail for that month is deleted
--
--  Sealing is the important step and it is deliberately separate from
--  purging. A sealed month is frozen: still_open stops moving, and the
--  views switch to the stored figures. That is right only once every
--  enquiry from that month has been decided, which is why the default
--  waits thirteen months rather than twelve - a year plus a margin, so
--  the figure a reader sees for last September is the same figure they
--  saw in March.
--
--  MEDIANS ARE WHY THIS HAS TO BE DONE IN ADVANCE
--  ----------------------------------------------
--  A median cannot be recovered from stored totals. Averages and counts
--  can be re-derived from other aggregates; percentile_cont cannot. If
--  the detail is deleted before the median is computed, that month's
--  cycle time is gone for good. So the rollup stores the medians, and
--  purging refuses to run on a month that has not been rolled up.
--
--  Run in the Supabase SQL Editor. Idempotent.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. Retention settings
--
--  One row. The numbers are Harry's to set, not the developer's: how
--  long a joinery firm should keep an unsuccessful enquirer's details is
--  a business and legal question, not a technical one. These defaults
--  are deliberately cautious - nothing is deleted for two years - and
--  purging never happens on its own. Someone has to call it.
-- ---------------------------------------------------------------------
create table if not exists public.analytics_retention (
  only_row                  boolean primary key default true check (only_row),
  seal_after_months         int not null default 13
    check (seal_after_months between 3 and 60),
  purge_detail_after_months int not null default 24
    check (purge_detail_after_months between 6 and 120),
  updated_at                timestamptz not null default now()
);

insert into public.analytics_retention (only_row) values (true)
on conflict (only_row) do nothing;

-- Purging earlier than sealing would delete the detail before the
-- figures were taken from it. The database refuses that outright.
alter table public.analytics_retention
  drop constraint if exists retention_order;
alter table public.analytics_retention
  add constraint retention_order
  check (purge_detail_after_months >= seal_after_months);

comment on table public.analytics_retention is
  'One row. How long detail is kept before a month is frozen, and before its personal data is deleted. Harry sets these.';


-- ---------------------------------------------------------------------
--  2. The facts
--
--  Counts and sums only. No name, no address, no phone number, no email
--  and no free text - that is the whole point, and it is what makes
--  keeping these for ever defensible.
--
--  Stored as bigint and numeric to match what count() and sum() hand
--  back, so the views can union stored rows against live ones without a
--  cast fight.
-- ---------------------------------------------------------------------
create table if not exists public.fact_month (
  month            date primary key,

  -- funnel
  received         bigint not null default 0,
  contacted        bigint not null default 0,
  survey_booked    bigint not null default 0,
  surveyed         bigint not null default 0,
  quoted           bigint not null default 0,
  won              bigint not null default 0,
  lost             bigint not null default 0,
  closed           bigint not null default 0,
  still_open       bigint not null default 0,

  quoted_value     numeric(12,2) not null default 0,
  won_value        numeric(12,2) not null default 0,
  lost_value       numeric(12,2) not null default 0,

  -- cycle times. Medians, which is why they are stored rather than
  -- recomputed: see the header.
  median_days_to_contact      numeric,
  median_days_to_book_survey  numeric,
  median_days_to_survey       numeric,
  median_days_to_quote        numeric,
  median_days_to_decision     numeric,
  median_days_total           numeric,
  median_days_total_n         bigint not null default 0,
  cycle_n                     bigint not null default 0,

  -- production
  jobs_completed      bigint not null default 0,
  jobs_with_promise   bigint not null default 0,
  jobs_on_time        bigint not null default 0,
  median_variance_days numeric,
  committed_days      numeric(10,1) not null default 0,
  available_days      numeric(10,1) not null default 0,

  -- lifecycle
  sealed           boolean not null default false,
  sealed_at        timestamptz,
  detail_purged_at timestamptz,
  computed_at      timestamptz not null default now()
);

comment on table public.fact_month is
  'One row per trading month: counts, sums and medians, no personal data. Sealed rows are final and the analytics views read them instead of recomputing.';

create index if not exists fact_month_sealed_idx on public.fact_month (sealed);

create table if not exists public.fact_month_source (
  month      date not null references public.fact_month (month) on delete cascade,
  source     public.enquiry_source not null,
  enquiries  bigint not null default 0,
  won        bigint not null default 0,
  closed     bigint not null default 0,
  revenue    numeric(12,2) not null default 0,
  primary key (month, source)
);

create table if not exists public.fact_month_product (
  month           date not null references public.fact_month (month) on delete cascade,
  product_type    text not null,
  jobs_completed  bigint not null default 0,
  on_time         bigint not null default 0,
  primary key (month, product_type)
);

create table if not exists public.fact_month_lost (
  month       date not null references public.fact_month (month) on delete cascade,
  lost_reason text not null,
  lost_count  bigint not null default 0,
  lost_value  numeric(12,2) not null default 0,
  primary key (month, lost_reason)
);


-- ---------------------------------------------------------------------
--  3. Access. Same rule as everything else here: any signed-in member of
--  staff, and nothing at all for anon. A materialised view taught this
--  project that Supabase grants new objects to anon by default and that
--  the default has to be revoked explicitly, not assumed.
-- ---------------------------------------------------------------------
alter table public.analytics_retention  enable row level security;
alter table public.fact_month           enable row level security;
alter table public.fact_month_source    enable row level security;
alter table public.fact_month_product   enable row level security;
alter table public.fact_month_lost      enable row level security;

do $$
declare t text;
begin
  foreach t in array array['analytics_retention','fact_month','fact_month_source',
                           'fact_month_product','fact_month_lost']
  loop
    execute format('drop policy if exists %I_staff_read on public.%I', t, t);
    execute format(
      'create policy %I_staff_read on public.%I for select to authenticated using (true)', t, t);
    execute format('drop policy if exists %I_staff_write on public.%I', t, t);
    execute format(
      'create policy %I_staff_write on public.%I for all to authenticated using (true) with check (true)', t, t);
    -- The rollup functions are security invoker, so the signed-in user
    -- does the writing and needs the rights to do it. Granting only
    -- select here would fail every rollup with a permission error.
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('revoke all on public.%I from anon', t);
  end loop;
end $$;

-- Nobody deletes the settings row; the check constraint keeps it alone.
revoke delete on public.analytics_retention from authenticated;


-- ---------------------------------------------------------------------
--  4. roll_up_month — take the month's figures while the detail is there
--
--  Idempotent: running it again for an open month overwrites, which is
--  what you want while the month is still settling. It refuses on a
--  month whose detail has already been purged, because the figures it
--  would compute from nothing are zeroes, and silently replacing a
--  year's real trading with zeroes is the worst thing this file could
--  possibly do.
-- ---------------------------------------------------------------------
create or replace function public.roll_up_month(p_month date)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  m date := date_trunc('month', p_month)::date;
  purged timestamptz;
begin
  select detail_purged_at into purged from public.fact_month where month = m;
  if purged is not null then
    raise exception
      'Month % had its detail purged on %; its figures cannot be recomputed and must not be overwritten.',
      to_char(m, 'Mon YYYY'), purged::date;
  end if;

  insert into public.fact_month as t (
    month, received, contacted, survey_booked, surveyed, quoted, won, lost, closed, still_open,
    quoted_value, won_value, lost_value,
    median_days_to_contact, median_days_to_book_survey, median_days_to_survey,
    median_days_to_quote, median_days_to_decision, median_days_total,
    median_days_total_n, cycle_n,
    jobs_completed, jobs_with_promise, jobs_on_time, median_variance_days,
    committed_days, available_days, computed_at)
  select
    m,
    count(f.id),
    count(f.id) filter (where f.at_contacted is not null),
    count(f.id) filter (where f.at_survey_booked is not null),
    count(f.id) filter (where f.at_surveyed is not null),
    count(f.id) filter (where f.at_quoted is not null),
    count(f.id) filter (where f.is_won),
    count(f.id) filter (where f.is_lost),
    count(f.id) filter (where f.is_closed),
    count(f.id) filter (where not f.is_closed),
    coalesce(sum(f.quote_value) filter (where f.at_quoted is not null), 0),
    coalesce(sum(f.quote_value) filter (where f.is_won), 0),
    coalesce(sum(f.quote_value) filter (where f.is_lost), 0),
    (percentile_cont(0.5) within group (order by f.days_new_to_contacted)
      filter (where f.days_new_to_contacted is not null))::numeric,
    (percentile_cont(0.5) within group (order by f.days_contacted_to_booked)
      filter (where f.days_contacted_to_booked is not null))::numeric,
    (percentile_cont(0.5) within group (order by f.days_booked_to_surveyed)
      filter (where f.days_booked_to_surveyed is not null))::numeric,
    (percentile_cont(0.5) within group (order by f.days_surveyed_to_quoted)
      filter (where f.days_surveyed_to_quoted is not null))::numeric,
    (percentile_cont(0.5) within group (order by f.days_quoted_to_decision)
      filter (where f.days_quoted_to_decision is not null))::numeric,
    (percentile_cont(0.5) within group (order by f.days_total)
      filter (where f.days_total is not null))::numeric,
    count(f.id) filter (where f.days_total is not null),
    count(f.id),
    (select count(*) from public.v_promise_vs_delivery pd where pd.completed_month = m),
    (select count(*) from public.v_promise_vs_delivery pd
      where pd.completed_month = m and pd.days_late is not null),
    (select count(*) from public.v_promise_vs_delivery pd
      where pd.completed_month = m and pd.on_time),
    (select (percentile_cont(0.5) within group (order by jp.actual_end_variance_days))::numeric
       from public.v_job_performance jp
       join public.dim_date dd on dd.d = jp.actual_end
      where dd.month_start = m and jp.actual_end_variance_days is not null),
    (select count(*)::numeric
       from public.jobs j
       join public.dim_date d
         on d.d between j.planned_start and j.planned_end and d.is_working_day
      where j.planned_start is not null and d.month_start = m),
    (select coalesce(sum(coalesce(c.available_days, 15.0)), 0)::numeric
       from (select distinct d.week_start from public.dim_date d where d.month_start = m) wk
       left join public.capacity_weeks c on c.week_start = wk.week_start),
    now()
  from public.v_enquiry_flat f
  where f.received_month = m
  on conflict (month) do update set
    received = excluded.received, contacted = excluded.contacted,
    survey_booked = excluded.survey_booked, surveyed = excluded.surveyed,
    quoted = excluded.quoted, won = excluded.won, lost = excluded.lost,
    closed = excluded.closed, still_open = excluded.still_open,
    quoted_value = excluded.quoted_value, won_value = excluded.won_value,
    lost_value = excluded.lost_value,
    median_days_to_contact = excluded.median_days_to_contact,
    median_days_to_book_survey = excluded.median_days_to_book_survey,
    median_days_to_survey = excluded.median_days_to_survey,
    median_days_to_quote = excluded.median_days_to_quote,
    median_days_to_decision = excluded.median_days_to_decision,
    median_days_total = excluded.median_days_total,
    median_days_total_n = excluded.median_days_total_n,
    cycle_n = excluded.cycle_n,
    jobs_completed = excluded.jobs_completed,
    jobs_with_promise = excluded.jobs_with_promise,
    jobs_on_time = excluded.jobs_on_time,
    median_variance_days = excluded.median_variance_days,
    committed_days = excluded.committed_days,
    available_days = excluded.available_days,
    computed_at = excluded.computed_at
  where t.sealed = false;

  -- A month with no enquiries still needs its row, or the breakdowns
  -- below have nothing to hang off and a quiet month vanishes from the
  -- history rather than showing as a quiet month.
  insert into public.fact_month (month) values (m) on conflict (month) do nothing;

  -- ---- breakdowns, rebuilt wholesale for the month ----
  delete from public.fact_month_source  where month = m;
  insert into public.fact_month_source (month, source, enquiries, won, closed, revenue)
  select m, f.source,
         count(*),
         count(*) filter (where f.is_won),
         count(*) filter (where f.is_closed),
         coalesce(sum(f.quote_value) filter (where f.is_won), 0)
    from public.v_enquiry_flat f
   where f.received_month = m
   group by f.source;

  delete from public.fact_month_product where month = m;
  insert into public.fact_month_product (month, product_type, jobs_completed, on_time)
  select m, pd.product_type, count(*), count(*) filter (where pd.on_time)
    from public.v_promise_vs_delivery pd
   where pd.completed_month = m
   group by pd.product_type;

  delete from public.fact_month_lost    where month = m;
  insert into public.fact_month_lost (month, lost_reason, lost_count, lost_value)
  select m, coalesce(f.lost_reason, 'Not recorded'), count(*),
         coalesce(sum(f.quote_value), 0)
    from public.v_enquiry_flat f
    join public.dim_date d on d.d = f.lost_on
   where f.is_lost and d.month_start = m
   group by coalesce(f.lost_reason, 'Not recorded');
end;
$$;


-- ---------------------------------------------------------------------
--  5. seal_month — declare a month final
--
--  Refuses to seal a month that has not ended, because half a month of
--  figures frozen for ever is worse than no figures.
-- ---------------------------------------------------------------------
create or replace function public.seal_month(p_month date)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare m date := date_trunc('month', p_month)::date;
begin
  if m >= date_trunc('month', current_date)::date then
    raise exception 'Refusing to seal %: the month has not finished.', to_char(m, 'Mon YYYY');
  end if;
  perform public.roll_up_month(m);
  update public.fact_month
     set sealed = true, sealed_at = coalesce(sealed_at, now())
   where month = m;
end;
$$;


-- ---------------------------------------------------------------------
--  6. archive_months — the routine call
--
--  Rolls up every month that is not yet sealed, and seals everything
--  older than the retention setting. Safe to run as often as you like;
--  running it nightly is the intention.
-- ---------------------------------------------------------------------
create or replace function public.archive_months()
returns table (rolled int, sealed int)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  cutoff date;
  m date;
  n_rolled int := 0;
  n_sealed int := 0;
begin
  select (date_trunc('month', current_date) - (seal_after_months || ' months')::interval)::date
    into cutoff from public.analytics_retention;

  for m in
    select distinct month_start from public.dim_date
     where month_start >= (select coalesce(min(received_month), current_date)
                             from public.v_enquiry_flat)
       and month_start <= date_trunc('month', current_date)::date
     order by 1
  loop
    -- never recompute a month whose detail is gone, and never a sealed one
    if not exists (select 1 from public.fact_month
                    where month = m and (sealed or detail_purged_at is not null)) then
      perform public.roll_up_month(m);
      n_rolled := n_rolled + 1;
      if m < cutoff then
        update public.fact_month set sealed = true, sealed_at = coalesce(sealed_at, now())
         where month = m;
        n_sealed := n_sealed + 1;
      end if;
    end if;
  end loop;

  return query select n_rolled, n_sealed;
end;
$$;


-- ---------------------------------------------------------------------
--  7. purge_detail_before — delete the personal data, keep the figures
--
--  Deliberately never called automatically. Deleting a customer's
--  record is not something a cron job should decide, and the figures are
--  already safe whether or not this ever runs.
--
--  Guards, in order:
--    the month must be sealed, so the figures are taken and frozen;
--    a job must be finished, so live work is never touched however old
--    its start date is;
--    an enquiry must be closed and have no live job hanging off it.
-- ---------------------------------------------------------------------
create or replace function public.purge_detail_before(p_cutoff date default null)
returns table (month date, enquiries_deleted int, jobs_deleted int)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  cutoff date;
  m date;
  e_n int;
  j_n int;
begin
  if p_cutoff is not null then
    cutoff := date_trunc('month', p_cutoff)::date;
  else
    select (date_trunc('month', current_date) - (purge_detail_after_months || ' months')::interval)::date
      into cutoff from public.analytics_retention;
  end if;

  for m in
    select f.month from public.fact_month f
     where f.sealed and f.detail_purged_at is null and f.month < cutoff
     order by f.month
  loop
    delete from public.jobs j
     where j.actual_end is not null
       and date_trunc('month', j.actual_end)::date = m;
    get diagnostics j_n = row_count;

    delete from public.enquiries e
     where date_trunc('month', e.received_on)::date = m
       and e.status in ('won','lost')
       and not exists (select 1 from public.jobs j2
                        where j2.enquiry_id = e.id and j2.actual_end is null);
    get diagnostics e_n = row_count;

    update public.fact_month set detail_purged_at = now() where fact_month.month = m;

    month := m; enquiries_deleted := e_n; jobs_deleted := j_n;
    return next;
  end loop;
end;
$$;


-- ---------------------------------------------------------------------
--  8. The views, reading facts for sealed months and detail for the rest
--
--  The partition is the whole correctness argument: a month is either
--  sealed or it is not, the fact arm emits only sealed months and the
--  live arm excludes them, so nothing can be counted twice and nothing
--  can fall between. This project has already shipped one aggregate that
--  duplicated every row twenty-five times, so the rule now is that any
--  union of stored and live figures partitions on a single flag that
--  both arms read.
--
--  Rates are derived once, outside the union, from counts that both arms
--  supply. Storing a rate beside its own numerator is how two screens
--  end up disagreeing about what a win rate is.
--
--  Dropped and recreated rather than replaced, because the column types
--  change and create-or-replace cannot do that. Nothing depends on these
--  four: mv_dashboard_summary reads v_enquiry_flat, v_overdue_actions,
--  v_pipeline_open, v_promise_vs_delivery, v_survey_diary and
--  v_weekly_capacity, none of which are touched here.
-- ---------------------------------------------------------------------
drop view if exists public.v_enquiry_funnel;
create view public.v_enquiry_funnel
  with (security_invoker = true) as
with sealed as (select month from public.fact_month where sealed),
raw as (
  select
    f.month as period, f.received, f.contacted, f.survey_booked, f.surveyed,
    f.quoted, f.won, f.lost, f.closed, f.still_open,
    f.quoted_value, f.won_value, f.lost_value, true as from_archive
  from public.fact_month f
  where f.sealed
  union all
  select
    m.month_start,
    count(f.id),
    count(f.id) filter (where f.at_contacted is not null),
    count(f.id) filter (where f.at_survey_booked is not null),
    count(f.id) filter (where f.at_surveyed is not null),
    count(f.id) filter (where f.at_quoted is not null),
    count(f.id) filter (where f.is_won),
    count(f.id) filter (where f.is_lost),
    count(f.id) filter (where f.is_closed),
    count(f.id) filter (where not f.is_closed),
    coalesce(sum(f.quote_value) filter (where f.at_quoted is not null), 0)::numeric(12,2),
    coalesce(sum(f.quote_value) filter (where f.is_won), 0)::numeric(12,2),
    coalesce(sum(f.quote_value) filter (where f.is_lost), 0)::numeric(12,2),
    false
  from (select distinct month_start from public.dim_date
         where month_start between date_trunc('month', current_date - interval '5 years')
                               and date_trunc('month', current_date)) m
  left join public.v_enquiry_flat f on f.received_month = m.month_start
  where m.month_start not in (select month from sealed)
  group by m.month_start
)
select
  period, received, contacted, survey_booked, surveyed, quoted, won, lost, still_open,
  quoted_value, won_value, lost_value,
  round(100.0 * won / nullif(closed, 0), 1) as win_rate,
  closed                                    as win_rate_n,
  round(100.0 * quoted / nullif(received, 0), 1) as quote_rate,
  received                                  as quote_rate_n,
  from_archive
from raw;

comment on view public.v_enquiry_funnel is
  'Monthly funnel. Sealed months come from fact_month; the rest are computed from detail. from_archive says which.';


drop view if exists public.v_enquiry_cycle_times;
create view public.v_enquiry_cycle_times
  with (security_invoker = true) as
with sealed as (select month from public.fact_month where sealed)
select
  f.month as period, f.cycle_n as n,
  f.median_days_to_contact, f.median_days_to_book_survey, f.median_days_to_survey,
  f.median_days_to_quote, f.median_days_to_decision, f.median_days_total,
  f.median_days_total_n, true as from_archive
from public.fact_month f
where f.sealed
union all
select
  m.month_start, count(f.id),
  (percentile_cont(0.5) within group (order by f.days_new_to_contacted)
    filter (where f.days_new_to_contacted is not null))::numeric,
  (percentile_cont(0.5) within group (order by f.days_contacted_to_booked)
    filter (where f.days_contacted_to_booked is not null))::numeric,
  (percentile_cont(0.5) within group (order by f.days_booked_to_surveyed)
    filter (where f.days_booked_to_surveyed is not null))::numeric,
  (percentile_cont(0.5) within group (order by f.days_surveyed_to_quoted)
    filter (where f.days_surveyed_to_quoted is not null))::numeric,
  (percentile_cont(0.5) within group (order by f.days_quoted_to_decision)
    filter (where f.days_quoted_to_decision is not null))::numeric,
  (percentile_cont(0.5) within group (order by f.days_total)
    filter (where f.days_total is not null))::numeric,
  count(f.id) filter (where f.days_total is not null),
  false
from (select distinct month_start from public.dim_date
       where month_start between date_trunc('month', current_date - interval '5 years')
                             and date_trunc('month', current_date)) m
left join public.v_enquiry_flat f on f.received_month = m.month_start
where m.month_start not in (select month from sealed)
group by m.month_start;


drop view if exists public.v_lost_analysis;
create view public.v_lost_analysis
  with (security_invoker = true) as
with sealed as (select month from public.fact_month where sealed)
select
  l.month as period, l.lost_reason, l.lost_count, l.lost_value,
  round(l.lost_value / nullif(l.lost_count, 0), 2) as avg_lost_value,
  true as from_archive
from public.fact_month_lost l
join public.fact_month f on f.month = l.month and f.sealed
union all
select
  d.month_start,
  coalesce(f.lost_reason, 'Not recorded'),
  count(*),
  coalesce(sum(f.quote_value), 0)::numeric(12,2),
  round(avg(f.quote_value), 2),
  false
from public.v_enquiry_flat f
join public.dim_date d on d.d = f.lost_on
where f.is_lost
  and d.month_start not in (select month from sealed)
group by d.month_start, coalesce(f.lost_reason, 'Not recorded');


drop view if exists public.v_source_performance;
create view public.v_source_performance
  with (security_invoker = true) as
with sealed as (select month from public.fact_month where sealed),
raw as (
  select s.month as period, s.source, s.enquiries, s.won, s.closed, s.revenue,
         true as from_archive
    from public.fact_month_source s
    join public.fact_month f on f.month = s.month and f.sealed
  union all
  select d.month_start, f.source,
         count(*),
         count(*) filter (where f.is_won),
         count(*) filter (where f.is_closed),
         coalesce(sum(f.quote_value) filter (where f.is_won), 0)::numeric(12,2),
         false
    from public.v_enquiry_flat f
    join public.dim_date d on d.d = f.received_on
   where d.month_start not in (select month from sealed)
   group by d.month_start, f.source
)
select
  period, source, enquiries, won, closed, revenue,
  round(100.0 * won / nullif(closed, 0), 1) as win_rate,
  closed                                    as win_rate_n,
  round(revenue / nullif(won, 0), 2)        as avg_won_value,
  from_archive
from raw;


-- ---------------------------------------------------------------------
--  9. Delivery by product, per month, and the aggregate over a period
--
--  The dashboard was grouping promise-versus-delivery rows by product in
--  JavaScript, which breaks this project's rule that no metric is
--  computed in the client, and could not have survived a purge either.
--  The view carries the month so a period can be filtered; the function
--  does the arithmetic, so the rate has exactly one definition.
-- ---------------------------------------------------------------------
create or replace view public.v_delivery_month_product
  with (security_invoker = true) as
with sealed as (select month from public.fact_month where sealed)
select p.month, p.product_type, p.jobs_completed, p.on_time
  from public.fact_month_product p
  join public.fact_month f on f.month = p.month and f.sealed
union all
select pd.completed_month, pd.product_type, count(*), count(*) filter (where pd.on_time)
  from public.v_promise_vs_delivery pd
 where pd.completed_month is not null
   and pd.completed_month not in (select month from sealed)
 group by pd.completed_month, pd.product_type;

create or replace function public.delivery_by_product(p_from date, p_to date)
returns table (product_type text, n bigint, on_time bigint,
               on_time_rate numeric, on_time_rate_n bigint)
language sql
security invoker
set search_path = ''
as $$
  select
    v.product_type,
    sum(v.jobs_completed)::bigint,
    sum(v.on_time)::bigint,
    round(100.0 * sum(v.on_time) / nullif(sum(v.jobs_completed), 0), 1),
    sum(v.jobs_completed)::bigint
  from public.v_delivery_month_product v
  where v.month >= date_trunc('month', p_from)::date
    and v.month <= p_to
  group by v.product_type
  order by sum(v.jobs_completed) desc;
$$;


-- ---------------------------------------------------------------------
--  10. What the archive holds, in one readable row per month
-- ---------------------------------------------------------------------
create or replace view public.v_archive_status
  with (security_invoker = true) as
select
  f.month,
  f.received, f.won, f.won_value, f.jobs_completed,
  case when f.detail_purged_at is not null then 'figures only'
       when f.sealed                       then 'sealed'
       else 'open' end                                as state,
  f.sealed_at::date                                   as sealed_on,
  f.detail_purged_at::date                            as purged_on,
  (select count(*) from public.enquiries e
    where date_trunc('month', e.received_on)::date = f.month) as enquiry_rows_still_held
from public.fact_month f
order by f.month desc;


grant select on
  public.v_enquiry_funnel, public.v_enquiry_cycle_times, public.v_lost_analysis,
  public.v_source_performance, public.v_delivery_month_product, public.v_archive_status
  to authenticated;

revoke all on
  public.v_enquiry_funnel, public.v_enquiry_cycle_times, public.v_lost_analysis,
  public.v_source_performance, public.v_delivery_month_product, public.v_archive_status
  from anon;

revoke all on function public.delivery_by_product(date, date) from anon;
grant execute on function public.delivery_by_product(date, date) to authenticated;

revoke all on function public.purge_detail_before(date) from anon;
revoke all on function public.roll_up_month(date)       from anon;
revoke all on function public.seal_month(date)          from anon;
revoke all on function public.archive_months()          from anon;
grant execute on function public.roll_up_month(date), public.seal_month(date),
                          public.archive_months() to authenticated;
grant execute on function public.purge_detail_before(date) to authenticated;


-- ---------------------------------------------------------------------
--  11. Build the archive from everything on record, then report
-- ---------------------------------------------------------------------
select * from public.archive_months();

select month, state, received, won, won_value, jobs_completed, enquiry_rows_still_held
  from public.v_archive_status
 limit 40;
