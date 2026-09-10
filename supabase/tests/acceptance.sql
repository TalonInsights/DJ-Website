-- =====================================================================
--  Acceptance tests
--
--  Paste into the Supabase SQL Editor after running the migrations and
--  the seed. Every check prints PASS or FAIL with what it actually saw,
--  so a failure names the problem rather than just going red.
--
--  Written for the Supabase SQL Editor, which does not support psql
--  meta-commands, so section headers are plain selects.
--
--  Read-only apart from §2, which creates one enquiry, walks it through
--  three statuses and deletes it again. It cleans up after itself even
--  if a check fails.
-- =====================================================================

select '--- 1. Structure ---' as section;

select case when count(*) = 5 then 'PASS' else 'FAIL' end || '  tables present ('
       || count(*) || '/5: ' || string_agg(table_name, ', ' order by table_name) || ')'
  from information_schema.tables
 where table_schema = 'public'
   and table_name in ('enquiries','enquiry_events','enquiry_ref_seq','job_events','capacity_weeks');

select case when count(*) = 12 then 'PASS' else 'FAIL' end
       || '  measurement columns on jobs (' || count(*) || '/12)'
  from information_schema.columns
 where table_schema = 'public' and table_name = 'jobs'
   and column_name in ('planned_start','planned_end','baseline_start','baseline_end',
                       'actual_start','actual_end','estimated_days','actual_days',
                       'reschedule_count','enquiry_id','product_type','customer_deadline');

select case when bool_and(rowsecurity) then 'PASS' else 'FAIL' end
       || '  row-level security enabled on every new table'
  from pg_tables
 where schemaname = 'public'
   and tablename in ('enquiries','enquiry_events','enquiry_ref_seq','job_events','capacity_weeks');

select case when count(*) = 0 then 'PASS' else 'FAIL' end
       || '  no policy grants anon anything (' || count(*) || ' found)'
  from pg_policies
 where schemaname = 'public' and 'anon' = any(roles);

-- A policy is only half of it. Supabase's default privileges hand new
-- objects to anon, and a materialised view has no row-level security to
-- fall back on, so the grant itself has to be checked. This caught a live
-- leak of the whole dashboard summary on 10 Sep 2026.
select case when count(*) = 0 then 'PASS' else 'FAIL' end
       || '  anon holds no table or view grant ('
       || coalesce(string_agg(distinct table_name, ', '), 'none') || ')'
  from information_schema.role_table_grants
 where grantee = 'anon' and table_schema = 'public';

select case when count(*) = 0 then 'PASS' else 'FAIL' end
       || '  history tables are read-only to staff (' || count(*) || ' write policies found)'
  from pg_policies
 where schemaname = 'public'
   and tablename in ('enquiry_events','job_events')
   and cmd <> 'SELECT';


select '--- 2. Reference generation and status history ---' as section;

do $t$
declare
  a_id uuid; b_id uuid;
  a_ref text; b_ref text;
  n_events int;
  y text := extract(year from current_date)::text;
begin
  insert into public.enquiries (customer_name) values ('Acceptance test A') returning id, ref into a_id, a_ref;
  insert into public.enquiries (customer_name) values ('Acceptance test B') returning id, ref into b_id, b_ref;

  if a_ref ~ ('^DJS-' || y || '-\d{4}$') then
    raise notice 'PASS  ref matches DJS-YYYY-NNNN (%)', a_ref;
  else
    raise notice 'FAIL  ref was %', a_ref;
  end if;

  if (regexp_replace(b_ref, '^.*-', ''))::int = (regexp_replace(a_ref, '^.*-', ''))::int + 1 then
    raise notice 'PASS  refs are sequential (% then %)', a_ref, b_ref;
  else
    raise notice 'FAIL  refs not sequential: % then %', a_ref, b_ref;
  end if;

  select count(*) into n_events from public.enquiry_events where enquiry_id = a_id;
  if n_events = 1 then
    raise notice 'PASS  insert wrote exactly one event';
  else
    raise notice 'FAIL  insert wrote % events', n_events;
  end if;

  -- Three real transitions, plus one update that names status without
  -- changing it, which must not add a phantom row.
  update public.enquiries set status = 'contacted', first_contacted_on = current_date where id = a_id;
  update public.enquiries set status = 'survey_booked',
         survey_date = current_date + 3, surveyor = 'Harry' where id = a_id;
  update public.enquiries set status = 'survey_booked', survey_slot = 'am' where id = a_id;  -- no-op transition
  update public.enquiries set status = 'quoted',
         quote_value = 1234.00, quote_sent_on = current_date where id = a_id;

  select count(*) into n_events from public.enquiry_events where enquiry_id = a_id;
  if n_events = 4 then
    raise notice 'PASS  three transitions wrote three events, the no-op wrote none (4 total)';
  else
    raise notice 'FAIL  expected 4 events, found %', n_events;
  end if;

  delete from public.enquiries where id in (a_id, b_id);

  select count(*) into n_events from public.enquiry_events where enquiry_id = a_id;
  if n_events = 0 then
    raise notice 'PASS  deleting an enquiry cascades its history away';
  else
    raise notice 'FAIL  % orphaned events remain', n_events;
  end if;
end
$t$;


select '--- 3. Job baseline, reschedule counting and history ---' as section;

do $t$
declare
  j_id uuid;
  u_id uuid;
  b_start date; b_end date; p_end date;
  n_resched int; n_events int;
begin
  -- There is no signed-in user in the SQL Editor, so auth.uid() is null.
  -- Borrow a real account for the test row rather than relying on the
  -- column default, and record the owner explicitly.
  select coalesce(auth.uid(), (select id from auth.users order by created_at limit 1))
    into u_id;

  insert into public.jobs (name, owner_id, phases) values (
    'Acceptance test job',
    u_id,
    '[{"key":"assembly","start":"2026-10-05","end":"2026-10-09","who":"Harry"},
      {"key":"spray","start":"2026-10-12","end":"2026-10-14","who":"David"}]'::jsonb
  ) returning id, baseline_start, baseline_end, planned_end into j_id, b_start, b_end, p_end;

  if b_start = date '2026-10-05' and b_end = date '2026-10-14' and p_end = date '2026-10-14' then
    raise notice 'PASS  plan derived from phases and baseline set (% to %)', b_start, b_end;
  else
    raise notice 'FAIL  derived % to %, planned end %', b_start, b_end, p_end;
  end if;

  -- Drag the whole job a week later, twice.
  update public.jobs set phases =
    '[{"key":"assembly","start":"2026-10-12","end":"2026-10-16","who":"Harry"},
      {"key":"spray","start":"2026-10-19","end":"2026-10-21","who":"David"}]'::jsonb
   where id = j_id;
  update public.jobs set phases =
    '[{"key":"assembly","start":"2026-10-19","end":"2026-10-23","who":"Harry"},
      {"key":"spray","start":"2026-10-26","end":"2026-10-28","who":"David"}]'::jsonb
   where id = j_id;

  select reschedule_count, baseline_start, baseline_end into n_resched, b_start, b_end
    from public.jobs where id = j_id;

  if n_resched = 2 then
    raise notice 'PASS  two drags counted as two reschedules';
  else
    raise notice 'FAIL  reschedule_count is %', n_resched;
  end if;

  if b_start = date '2026-10-05' then
    raise notice 'PASS  baseline did not move when the plan did';
  else
    raise notice 'FAIL  baseline moved to %', b_start;
  end if;

  select count(*) into n_events from public.job_events
   where job_id = j_id and kind = 'rescheduled';
  if n_events = 2 then
    raise notice 'PASS  both reschedules are in the history';
  else
    raise notice 'FAIL  % reschedule events logged', n_events;
  end if;

  delete from public.jobs where id = j_id;
end
$t$;


select '--- 4. Seed and funnel ---' as section;

select case when count(*) = 60 then 'PASS' else 'FAIL' end
       || '  seed loaded (' || count(*) || ' enquiries)'
  from public.enquiries where notes like '%[seed data]%';

select 'INFO  funnel: ' || string_agg(status || ' ' || n, ', ' order by n desc)
  from (select status::text as status, count(*) as n
          from public.enquiries where notes like '%[seed data]%'
         group by status) f;

select case when min(occurred_at) < now() - interval '60 days' then 'PASS' else 'FAIL' end
       || '  history is backdated (oldest event ' || date(min(occurred_at)) || ')'
  from public.enquiry_events ev
  join public.enquiries e on e.id = ev.enquiry_id
 where e.notes like '%[seed data]%';

select case when count(*) > 0 then 'PASS' else 'FAIL' end
       || '  overdue follow-ups exist for the action strip (' || count(*) || ')'
  from public.enquiries
 where notes like '%[seed data]%'
   and next_action_on < current_date
   and status not in ('won','lost');


select '--- 4b. Transition rules ---' as section;

do $t$
declare c_id uuid; msg text; blocked boolean := false;
begin
  insert into public.enquiries (customer_name) values ('Acceptance test C') returning id into c_id;
  begin
    update public.enquiries set status = 'quoted' where id = c_id;   -- no quote value
  exception when others then
    blocked := true; msg := sqlerrm;
  end;
  if blocked then
    raise notice 'PASS  an invalid transition is refused, and says why: %', msg;
  else
    raise notice 'FAIL  moving to quoted with no quote value was allowed';
  end if;
  delete from public.enquiries where id = c_id;
end
$t$;

select '--- 5. Views ---' as section;

select case when count(*) = 12 then 'PASS' else 'FAIL' end
       || '  views created (' || count(*) || '/12)'
  from information_schema.views
 where table_schema = 'public' and table_name like 'v\_%';

select case when count(*) = 1 then 'PASS' else 'FAIL' end || '  dashboard summary materialised'
  from pg_matviews where schemaname = 'public' and matviewname = 'mv_dashboard_summary';

select case when count(*) > 4000 then 'PASS' else 'FAIL' end
       || '  date dimension populated (' || count(*) || ' days)'
  from public.dim_date;

-- Every rate must carry the count it was computed from.
select case when count(*) = 0 then 'PASS' else 'FAIL' end
       || '  every _rate column has a matching _n (' || coalesce(string_agg(c, ', '), 'none missing') || ')'
  from (
    select column_name as c
      from information_schema.columns a
     where table_schema = 'public' and column_name like '%\_rate'
       and not exists (
         select 1 from information_schema.columns b
          where b.table_schema = a.table_schema and b.table_name = a.table_name
            and b.column_name = a.column_name || '_n')
  ) missing;

select '--- done ---' as section;
