-- =====================================================================
--  Stop stale install windows piling onto one week
--
--  Migration 0008 fixed the arithmetic but introduced a pile-up. Any
--  enquiry whose install window had already passed was clamped forward
--  to "today until today plus ten days", so every stale quote landed in
--  the same ten-day block. Two weeks read 29.0 and 72.5 job-days while
--  every other week read under 1.5, against a capacity of 15.
--
--  The clamp was answering the wrong question. A quote from four months
--  ago with a window that has gone by does not tell us the work must
--  happen this fortnight. It tells us we no longer know when it would
--  land. Squeezing it into the nearest ten days invents a certainty that
--  is not there, and makes the one chart meant to guide planning point
--  at the wrong month.
--
--  WHAT IT DOES NOW
--    * A window still in the future is used exactly as given.
--    * A window that has passed, or was never set, is spread across a
--      default planning horizon — three weeks out, over eight weeks —
--      because "soon, but we do not know when" is the honest answer.
--    * The horizon keeps a minimum width, so a two-day window cannot
--      concentrate a whole job into a single day.
--
--  Nothing is excluded. Every open enquiry still contributes exactly its
--  own weighted size, so the chart continues to agree with the weighted
--  pipeline tile on the dashboard. Only WHEN it is drawn has changed.
--
--  Column order and types are unchanged from 0008, so this replaces
--  cleanly without disturbing mv_dashboard_summary.
--
--  Run in the Supabase SQL Editor. Idempotent.
-- =====================================================================

create or replace view public.v_weekly_capacity
  with (security_invoker = true) as
with weeks as (
  select distinct week_start
    from public.dim_date
   where week_start between date_trunc('week', current_date - interval '12 months')
                        and date_trunc('week', current_date + interval '9 months')
),
committed as (
  select d.week_start, count(*)::numeric as days
    from public.jobs j
    join public.dim_date d
      on d.d between j.planned_start and j.planned_end
     and d.is_working_day
   where j.planned_start is not null
   group by d.week_start
),
-- Each open enquiry, its weighted size, and the window it might land in.
windows as (
  select
    p.id,
    greatest(p.est_production_days * coalesce(p.probability, 0) / 100.0, 0) as weighted_days,
    case
      when p.target_install_from is not null and p.target_install_from > current_date
        then p.target_install_from
      else current_date + 21          -- no usable date: start of the horizon
    end as win_from,
    case
      when p.target_install_from is not null and p.target_install_from > current_date
        then greatest(coalesce(p.target_install_to, p.target_install_from + 28),
                      p.target_install_from + 14)   -- never narrower than a fortnight
      else current_date + 21 + 56      -- eight weeks of horizon
    end as win_to
  from public.v_pipeline_open p
),
-- One row per working day of each window, carrying how many days that
-- window has, so the weight is divided across it rather than repeated.
spread as (
  select
    w.id,
    w.weighted_days,
    d.week_start,
    count(*) over (partition by w.id) as days_in_window
  from windows w
  join public.dim_date d
    on d.d between w.win_from and w.win_to
   and d.is_working_day
),
pipeline as (
  select week_start,
         sum(weighted_days / nullif(days_in_window, 0))::numeric as weighted_days
    from spread
   group by week_start
)
select
  w.week_start,
  coalesce(c.available_days, 15.0)                        as available_days,
  coalesce(cm.days, 0)                                    as committed_days,
  round(coalesce(pl.weighted_days, 0), 1)::numeric(8,1)   as weighted_pipeline_days,
  greatest(coalesce(c.available_days, 15.0) - coalesce(cm.days, 0), 0) as free_days,
  round(100.0 * coalesce(cm.days, 0)
        / nullif(coalesce(c.available_days, 15.0), 0), 1) as utilisation_rate,
  coalesce(c.available_days, 15.0)                        as utilisation_rate_n,
  (coalesce(cm.days, 0) > coalesce(c.available_days, 15.0)) as over_capacity,
  (c.week_start is null)                                   as using_default_capacity,
  c.note                                                   as capacity_note,
  (coalesce(cm.days, 0) + coalesce(pl.weighted_days, 0)
     > coalesce(c.available_days, 15.0))                   as over_when_pipeline_lands
from weeks w
left join public.capacity_weeks c  on c.week_start  = w.week_start
left join committed             cm on cm.week_start = w.week_start
left join pipeline              pl on pl.week_start = w.week_start;

comment on view public.v_weekly_capacity is
  'Available against committed job-days per ISO week. Each open enquiry contributes its weighted size once, spread across its install window; a window that has passed or was never set is spread across a default horizon three weeks out rather than piled onto the current week.';

grant select on public.v_weekly_capacity to authenticated;
revoke all on public.v_weekly_capacity from anon;

select public.refresh_dashboard();


-- ---------------------------------------------------------------------
--  Two checks, in one result.
--
--  The first rows are the sanity test: total weighted pipeline in the
--  view must equal the total on the open enquiries, give or take
--  rounding. If it does not, the spread is losing or duplicating work
--  again. The rest is what the chart will draw.
-- ---------------------------------------------------------------------
select 'CHECK' as week_start, null::numeric as available_days, null::numeric as committed_days,
       round((select sum(weighted_value) from public.v_pipeline_open), 1) as weighted_pipeline_days,
       'total weighted value on open enquiries' as note
union all
select 'CHECK', null, null,
       round((select sum(weighted_pipeline_days) from public.v_weekly_capacity), 1),
       'total spread across the weeks — should match the size of the pipeline, not multiply it'
union all
select to_char(week_start, 'YYYY-MM-DD'), available_days, committed_days, weighted_pipeline_days,
       case when over_capacity then 'over on committed work alone'
            when over_when_pipeline_lands then 'would go over if the pipeline lands'
            else coalesce(capacity_note, '') end
  from public.v_weekly_capacity
 where week_start between date_trunc('week', current_date - interval '2 weeks')
                      and date_trunc('week', current_date + interval '20 weeks')
 order by 1;
