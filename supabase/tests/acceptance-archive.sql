-- =====================================================================
--  Acceptance: the analytics archive
--
--  The one thing that matters here is that the stored figures equal the
--  figures they replace. Everything else in the file exists to catch the
--  two ways a union of stored and live rows goes wrong: counting a month
--  twice, and losing one between the arms.
--
--  Run AFTER 0011 has been applied. Safe to run repeatedly: it seals
--  nothing and deletes nothing. Every check writes a row into a temp
--  table and the last statement prints the lot, because the Supabase
--  editor only shows the result of the final statement.
-- =====================================================================

create temp table if not exists _arc (seq int, area text, outcome text, detail text)
  on commit preserve rows;
truncate _arc;

do $$
declare
  m           date;
  f           public.fact_month%rowtype;
  live_recv   bigint;  live_won bigint;  live_wonval numeric;
  live_median numeric; n_rows int; n_months int; n_dupes int;
  before_n    bigint;  after_n  bigint;
  bad         int;
begin

  -- ---------------------------------------------------------------
  --  1. Is there anything to test
  -- ---------------------------------------------------------------
  select count(*) into n_rows from public.fact_month;
  insert into _arc values (1, 'archive built',
    case when n_rows > 0 then 'PASS' else 'FAIL' end,
    n_rows || ' month rows in fact_month');

  if n_rows = 0 then
    insert into _arc values (2, 'everything else', 'SKIP',
      'No fact rows. Run: select * from public.archive_months();');
    return;
  end if;

  -- ---------------------------------------------------------------
  --  2. The figures equal the detail they replace
  --
  --  Picked on the most recent month that still has its detail, so the
  --  comparison is against something real rather than against zero.
  -- ---------------------------------------------------------------
  select fm.month into m
    from public.fact_month fm
   where fm.detail_purged_at is null
     and exists (select 1 from public.v_enquiry_flat f where f.received_month = fm.month)
   order by fm.month desc limit 1;

  if m is null then
    insert into _arc values (2, 'reconciliation', 'SKIP', 'No month with detail still held.');
  else
    perform public.roll_up_month(m);
    select * into f from public.fact_month where month = m;

    select count(*), count(*) filter (where is_won),
           coalesce(sum(quote_value) filter (where is_won), 0),
           (percentile_cont(0.5) within group (order by days_total)
              filter (where days_total is not null))::numeric
      into live_recv, live_won, live_wonval, live_median
      from public.v_enquiry_flat where received_month = m;

    insert into _arc values (2, 'reconciliation — counts',
      case when f.received = live_recv and f.won = live_won then 'PASS' else 'FAIL' end,
      to_char(m,'Mon YYYY') || ': stored ' || f.received || ' received / ' || f.won ||
      ' won, detail says ' || live_recv || ' / ' || live_won);

    insert into _arc values (3, 'reconciliation — money',
      case when abs(f.won_value - live_wonval) < 0.01 then 'PASS' else 'FAIL' end,
      'stored ' || f.won_value || ', detail says ' || live_wonval);

    insert into _arc values (4, 'reconciliation — median',
      case when f.median_days_total is not distinct from live_median then 'PASS' else 'FAIL' end,
      coalesce(f.median_days_total::text,'none') || ' against ' || coalesce(live_median::text,'none') ||
      '. A median cannot be rebuilt after a purge, so this is the one that must be right in advance.');
  end if;

  -- ---------------------------------------------------------------
  --  3. No month appears twice in a view that unions the two arms
  -- ---------------------------------------------------------------
  select count(*) into n_dupes from (
    select period from public.v_enquiry_funnel group by period having count(*) > 1) x;
  insert into _arc values (5, 'funnel — one row per month',
    case when n_dupes = 0 then 'PASS' else 'FAIL' end,
    case when n_dupes = 0 then 'no month counted twice'
         else n_dupes || ' month(s) appear more than once — the arms overlap' end);

  select count(*) into n_dupes from (
    select period from public.v_enquiry_cycle_times group by period having count(*) > 1) x;
  insert into _arc values (6, 'cycle times — one row per month',
    case when n_dupes = 0 then 'PASS' else 'FAIL' end, n_dupes || ' duplicated month(s)');

  -- ---------------------------------------------------------------
  --  4. Every sealed month is served by the archive, and no sealed
  --     month is also computed live. This is the partition itself.
  -- ---------------------------------------------------------------
  select count(*) into bad
    from public.v_enquiry_funnel v
    join public.fact_month fm on fm.month = v.period
   where fm.sealed and v.from_archive = false;
  insert into _arc values (7, 'sealed months come from the archive',
    case when bad = 0 then 'PASS' else 'FAIL' end,
    case when bad = 0 then 'every sealed month reads its stored row'
         else bad || ' sealed month(s) still being recomputed from detail' end);

  select count(*) into bad
    from public.v_enquiry_funnel v
    left join public.fact_month fm on fm.month = v.period
   where v.from_archive = true and coalesce(fm.sealed, false) = false;
  insert into _arc values (8, 'no unsealed month served from the archive',
    case when bad = 0 then 'PASS' else 'FAIL' end, bad || ' offending month(s)');

  -- ---------------------------------------------------------------
  --  5. Sealing does not change what the dashboard reads
  --
  --  Seals the oldest unsealed month that has detail, checks the figure
  --  is unchanged, then puts it back. If this fails, sealing rewrites
  --  history, which is the worst possible outcome for a trend line.
  -- ---------------------------------------------------------------
  select fm.month into m
    from public.fact_month fm
   where not fm.sealed and fm.detail_purged_at is null
     and fm.month < date_trunc('month', current_date)::date
   order by fm.month limit 1;

  if m is null then
    insert into _arc values (9, 'sealing is transparent', 'SKIP', 'No unsealed past month to test with.');
  else
    select received into before_n from public.v_enquiry_funnel where period = m;
    perform public.seal_month(m);
    select received into after_n  from public.v_enquiry_funnel where period = m;
    update public.fact_month set sealed = false, sealed_at = null where month = m;

    insert into _arc values (9, 'sealing is transparent',
      case when before_n is not distinct from after_n then 'PASS' else 'FAIL' end,
      to_char(m,'Mon YYYY') || ': ' || coalesce(before_n::text,'null') || ' before sealing, ' ||
      coalesce(after_n::text,'null') || ' after');
  end if;

  -- ---------------------------------------------------------------
  --  6. A purged month can never be recomputed into zeroes
  -- ---------------------------------------------------------------
  begin
    update public.fact_month set detail_purged_at = now()
     where month = (select min(month) from public.fact_month);
    perform public.roll_up_month((select min(month) from public.fact_month));
    insert into _arc values (10, 'purged month is protected', 'FAIL',
      'roll_up_month overwrote a month whose detail is gone');
  exception when others then
    insert into _arc values (10, 'purged month is protected', 'PASS',
      'refused, as it should: ' || left(sqlerrm, 90));
  end;
  update public.fact_month set detail_purged_at = null
   where month = (select min(month) from public.fact_month);

  -- ---------------------------------------------------------------
  --  7. The archive holds no personal data
  --
  --  Column names rather than values, because a column that should not
  --  exist is the thing to catch, and it catches it before anyone puts
  --  a name in one.
  -- ---------------------------------------------------------------
  select count(*) into bad
    from information_schema.columns
   where table_schema = 'public'
     and table_name in ('fact_month','fact_month_source','fact_month_product','fact_month_lost')
     and (column_name ~* 'name|email|phone|address|postcode|town|notes|ref'
          and column_name <> 'lost_reason');
  insert into _arc values (11, 'archive carries no personal data',
    case when bad = 0 then 'PASS' else 'FAIL' end,
    case when bad = 0 then 'counts, sums and medians only'
         else bad || ' column(s) look like personal data' end);

  -- ---------------------------------------------------------------
  --  8. anon cannot read any of it
  -- ---------------------------------------------------------------
  select count(*) into bad
    from information_schema.role_table_grants
   where grantee = 'anon' and table_schema = 'public'
     and table_name in ('fact_month','fact_month_source','fact_month_product',
                        'fact_month_lost','analytics_retention');
  insert into _arc values (12, 'anon has no grants',
    case when bad = 0 then 'PASS' else 'FAIL' end,
    bad || ' grant(s) to anon — a materialised view already leaked this way once');

  -- ---------------------------------------------------------------
  --  9. Retention cannot be set to purge before it seals
  -- ---------------------------------------------------------------
  begin
    update public.analytics_retention set purge_detail_after_months = 6, seal_after_months = 13;
    insert into _arc values (13, 'retention order enforced', 'FAIL',
      'accepted a purge window shorter than the sealing window');
  exception when others then
    insert into _arc values (13, 'retention order enforced', 'PASS',
      'refused: purging before sealing would delete the detail before the figures were taken');
  end;

  -- --------------------------------------------------------------
  -- 10. How much is actually being carried
  -- --------------------------------------------------------------
  select count(*) into n_months from public.fact_month;
  insert into _arc values (14, 'size of the archive', 'INFO',
    n_months || ' months stored across ' ||
    (select count(*) from public.fact_month_source) || ' source rows, ' ||
    (select count(*) from public.fact_month_product) || ' product rows, ' ||
    (select count(*) from public.fact_month_lost) || ' lost-reason rows');
end $$;

select area, outcome, detail from _arc order by seq;
