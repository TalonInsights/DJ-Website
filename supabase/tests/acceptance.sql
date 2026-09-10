-- =====================================================================
--  Acceptance tests
--
--  Paste the whole file into the Supabase SQL Editor and press Run. It
--  returns ONE table: every check, with PASS, FAIL or INFO, and what it
--  actually saw, so a failure names the problem rather than going red.
--
--  Written this way because the editor only ever shows the result of the
--  last statement. A script that emits one result per check throws all
--  but the last away, and `raise notice` is no use either — the editor
--  does not surface notices. So every check writes into a temporary
--  table and the final select reads it back.
--
--  Read-only apart from sections 3, 4 and 5, which create a few rows,
--  exercise them and delete them again. They clean up after themselves
--  even when a check fails.
-- =====================================================================

drop table if exists _acc;
create temp table _acc (
  seq     serial primary key,
  area    text,
  outcome text,
  detail  text
);

-- Shorthand, so each check reads as a single line.
create or replace function pg_temp.chk(area text, ok boolean, detail text)
returns void language sql as $$
  insert into _acc (area, outcome, detail)
  values (area, case when ok then 'PASS' else 'FAIL' end, detail);
$$;

create or replace function pg_temp.info(area text, detail text)
returns void language sql as $$
  insert into _acc (area, outcome, detail) values (area, 'INFO', detail);
$$;


-- ---------------------------------------------------------------------
--  1. Structure
-- ---------------------------------------------------------------------
select pg_temp.chk('1 Structure', count(*) = 5,
       'tables present ' || count(*) || '/5: '
       || coalesce(string_agg(table_name, ', ' order by table_name), 'none'))
  from information_schema.tables
 where table_schema = 'public'
   and table_name in ('enquiries','enquiry_events','enquiry_ref_seq','job_events','capacity_weeks');

select pg_temp.chk('1 Structure', count(*) = 12,
       'measurement columns on jobs ' || count(*) || '/12')
  from information_schema.columns
 where table_schema = 'public' and table_name = 'jobs'
   and column_name in ('planned_start','planned_end','baseline_start','baseline_end',
                       'actual_start','actual_end','estimated_days','actual_days',
                       'reschedule_count','enquiry_id','product_type','customer_deadline');

select pg_temp.chk('1 Structure', count(*) = 12, 'views created ' || count(*) || '/12')
  from information_schema.views
 where table_schema = 'public' and table_name like 'v\_%';

select pg_temp.chk('1 Structure', count(*) = 1, 'dashboard summary materialised')
  from pg_matviews where schemaname = 'public' and matviewname = 'mv_dashboard_summary';

select pg_temp.chk('1 Structure', count(*) > 4000,
       'date dimension populated: ' || count(*) || ' days')
  from public.dim_date;

select pg_temp.chk('1 Structure', not exists (
         select 1 from information_schema.columns a
          where a.table_schema = 'public' and a.column_name like '%\_rate'
            and not exists (select 1 from information_schema.columns b
                             where b.table_schema = a.table_schema and b.table_name = a.table_name
                               and b.column_name = a.column_name || '_n')),
       'every _rate column has a matching _n beside it');


-- ---------------------------------------------------------------------
--  2. Access control
-- ---------------------------------------------------------------------
select pg_temp.chk('2 Access', bool_and(rowsecurity), 'row-level security on every new table')
  from pg_tables
 where schemaname = 'public'
   and tablename in ('enquiries','enquiry_events','enquiry_ref_seq','job_events','capacity_weeks');

select pg_temp.chk('2 Access', count(*) = 0, 'no policy names anon (' || count(*) || ' found)')
  from pg_policies where schemaname = 'public' and 'anon' = any(roles);

-- A policy is only half of it. Supabase's default privileges hand new
-- objects to anon, and a materialised view has no row-level security to
-- fall back on. This is the check that caught the live leak of the
-- dashboard summary on 10 September 2026.
select pg_temp.chk('2 Access', count(*) = 0,
       'anon holds no table or view grant: '
       || coalesce(string_agg(distinct table_name, ', '), 'none'))
  from information_schema.role_table_grants
 where grantee = 'anon' and table_schema = 'public';

select pg_temp.chk('2 Access', count(*) = 0,
       'history tables are read-only to staff (' || count(*) || ' write policies)')
  from pg_policies
 where schemaname = 'public' and tablename in ('enquiry_events','job_events') and cmd <> 'SELECT';


-- ---------------------------------------------------------------------
--  3. References and status history
-- ---------------------------------------------------------------------
do $t$
declare
  a_id uuid; b_id uuid; a_ref text; b_ref text;
  n int; y text := extract(year from current_date)::text;
begin
  insert into public.enquiries (customer_name) values ('Acceptance test A') returning id, ref into a_id, a_ref;
  insert into public.enquiries (customer_name) values ('Acceptance test B') returning id, ref into b_id, b_ref;

  perform pg_temp.chk('3 References', a_ref ~ ('^DJS-' || y || '-\d{4}$'),
                      'reference matches DJS-YYYY-NNNN: ' || a_ref);

  perform pg_temp.chk('3 References',
    (regexp_replace(b_ref, '^.*-', ''))::int = (regexp_replace(a_ref, '^.*-', ''))::int + 1,
    'references are sequential: ' || a_ref || ' then ' || b_ref);

  select count(*) into n from public.enquiry_events where enquiry_id = a_id;
  perform pg_temp.chk('3 History', n = 1, 'insert wrote exactly one event (' || n || ')');

  update public.enquiries set status = 'contacted', first_contacted_on = current_date where id = a_id;
  update public.enquiries set status = 'survey_booked',
         survey_date = current_date + 3, surveyor = 'Harry' where id = a_id;
  update public.enquiries set status = 'survey_booked', survey_slot = 'am' where id = a_id;  -- no-op
  update public.enquiries set status = 'quoted',
         quote_value = 1234.00, quote_sent_on = current_date where id = a_id;

  select count(*) into n from public.enquiry_events where enquiry_id = a_id;
  perform pg_temp.chk('3 History', n = 4,
    'three transitions wrote three events, the no-op wrote none: ' || n || ' total');

  delete from public.enquiries where id in (a_id, b_id);
  select count(*) into n from public.enquiry_events where enquiry_id = a_id;
  perform pg_temp.chk('3 History', n = 0, 'deleting an enquiry cascades its history away');
exception when others then
  perform pg_temp.chk('3 References', false, 'threw: ' || sqlerrm);
end
$t$;


-- ---------------------------------------------------------------------
--  4. Transition rules
-- ---------------------------------------------------------------------
do $t$
declare c_id uuid; blocked boolean := false; msg text;
begin
  insert into public.enquiries (customer_name) values ('Acceptance test C') returning id into c_id;
  begin
    update public.enquiries set status = 'quoted' where id = c_id;   -- deliberately no quote value
  exception when others then
    blocked := true; msg := sqlerrm;
  end;
  perform pg_temp.chk('4 Rules', blocked,
    case when blocked then 'an incomplete transition is refused: ' || msg
         else 'moving to quoted with no quote value was allowed' end);
  delete from public.enquiries where id = c_id;
exception when others then
  perform pg_temp.chk('4 Rules', false, 'threw: ' || sqlerrm);
end
$t$;


-- ---------------------------------------------------------------------
--  5. Baseline, reschedule counting and schedule history
-- ---------------------------------------------------------------------
do $t$
declare
  j_id uuid; u_id uuid;
  b_start date; b_end date; p_end date; n_resched int; n int;
begin
  -- Nothing is signed in inside the SQL Editor, so auth.uid() is null.
  select coalesce(auth.uid(), (select id from auth.users order by created_at limit 1)) into u_id;

  insert into public.jobs (name, owner_id, phases) values (
    'Acceptance test job', u_id,
    '[{"key":"assembly","start":"2026-10-05","end":"2026-10-09","who":"Harry"},
      {"key":"spray","start":"2026-10-12","end":"2026-10-14","who":"David"}]'::jsonb
  ) returning id, baseline_start, baseline_end, planned_end into j_id, b_start, b_end, p_end;

  perform pg_temp.chk('5 Baseline',
    b_start = date '2026-10-05' and b_end = date '2026-10-14' and p_end = date '2026-10-14',
    'plan derived from phases, baseline set: ' || b_start || ' to ' || b_end);

  update public.jobs set phases =
    '[{"key":"assembly","start":"2026-10-12","end":"2026-10-16","who":"Harry"},
      {"key":"spray","start":"2026-10-19","end":"2026-10-21","who":"David"}]'::jsonb where id = j_id;
  update public.jobs set phases =
    '[{"key":"assembly","start":"2026-10-19","end":"2026-10-23","who":"Harry"},
      {"key":"spray","start":"2026-10-26","end":"2026-10-28","who":"David"}]'::jsonb where id = j_id;

  select reschedule_count, baseline_start into n_resched, b_start from public.jobs where id = j_id;
  perform pg_temp.chk('5 Baseline', n_resched = 2, 'two drags counted as two reschedules: ' || n_resched);
  perform pg_temp.chk('5 Baseline', b_start = date '2026-10-05',
    'baseline did not move when the plan did: ' || b_start);

  select count(*) into n from public.job_events where job_id = j_id and kind = 'rescheduled';
  perform pg_temp.chk('5 History', n = 2, 'both reschedules are in the history: ' || n);

  delete from public.jobs where id = j_id;
exception when others then
  perform pg_temp.chk('5 Baseline', false, 'threw: ' || sqlerrm);
end
$t$;


-- ---------------------------------------------------------------------
--  6. Seed and funnel
-- ---------------------------------------------------------------------
select pg_temp.chk('6 Seed', count(*) = 60,
       'seed loaded: ' || count(*) || ' enquiries (expects 60)')
  from public.enquiries where notes like '%[seed data]%';

select pg_temp.info('6 Seed',
       'funnel: ' || coalesce(string_agg(status || ' ' || n, ', ' order by n desc), 'empty'))
  from (select status::text as status, count(*) as n
          from public.enquiries where notes like '%[seed data]%' group by status) f;

select pg_temp.chk('6 Seed', coalesce(min(occurred_at) < now() - interval '60 days', false),
       'history is backdated, oldest event ' || coalesce(date(min(occurred_at))::text, 'none'))
  from public.enquiry_events ev
  join public.enquiries e on e.id = ev.enquiry_id
 where e.notes like '%[seed data]%';

select pg_temp.chk('6 Seed', count(*) > 0,
       'overdue follow-ups exist for the action strip: ' || count(*))
  from public.enquiries
 where notes like '%[seed data]%' and next_action_on < current_date and status not in ('won','lost');

select pg_temp.info('6 Seed', 'open pipeline: ' || count(*) || ' enquiries, weighted '
       || coalesce(round(sum(weighted_value))::text, '0'))
  from public.v_pipeline_open;

select pg_temp.info('6 Seed', 'capacity weeks configured: ' || count(*)) from public.capacity_weeks;


-- ---------------------------------------------------------------------
--  7. The capacity spread reconciles
--
--  Every open enquiry must contribute its weighted size to the weekly
--  view exactly once. If the totals diverge, the spread is duplicating
--  work across the days of its window or losing it. This one comparison
--  would have caught a twenty-five-fold duplication that shipped and had
--  to be found by eye on a chart.
-- ---------------------------------------------------------------------
select pg_temp.chk('7 Capacity',
       abs(coalesce((select sum(weighted_value)         from public.v_pipeline_open), 0)
         - coalesce((select sum(weighted_pipeline_days) from public.v_weekly_capacity), 0)) < 1.0,
       'pipeline spread matches its own total: '
       || round(coalesce((select sum(weighted_value)         from public.v_pipeline_open), 0), 1)
       || ' on open enquiries vs '
       || round(coalesce((select sum(weighted_pipeline_days) from public.v_weekly_capacity), 0), 1)
       || ' spread across the weeks');

select pg_temp.info('7 Capacity', 'weeks over on committed work alone: ' || count(*))
  from public.v_weekly_capacity where over_capacity;

select pg_temp.info('7 Capacity', 'weeks that would go over if the pipeline lands: ' || count(*))
  from public.v_weekly_capacity where over_when_pipeline_lands and not over_capacity;


-- ---------------------------------------------------------------------
--  8. The dashboard summary
-- ---------------------------------------------------------------------
select pg_temp.info('8 Dashboard', 'summary rebuilt at ' || public.refresh_dashboard());

select pg_temp.chk('8 Dashboard', enquiries is not null,
       'summary has figures: ' || coalesce(enquiries::text, 'null')
       || ' enquiries in 90 days, win rate ' || coalesce(win_rate::text, 'null')
       || '% from ' || coalesce(win_rate_n::text, '0') || ' decided')
  from public.mv_dashboard_summary;


-- ---------------------------------------------------------------------
--  The one result the editor will show
-- ---------------------------------------------------------------------
select area, outcome, detail from _acc order by seq;
