-- =====================================================================
--  Fix the weighted pipeline in v_weekly_capacity
--
--  The capacity chart showed a pipeline line peaking at 178 job-days
--  against a workshop capacity of 15, which flattened every bar into an
--  unreadable strip along the bottom. The pipeline was not large. The
--  sum was wrong, twice.
--
--  1. EVERY DAY COUNTED THE WHOLE JOB
--     The view joined each open enquiry to every day in its install
--     window and summed the full weighted figure on each one. An
--     enquiry with a five-week window contributed its entire weighted
--     value twenty-five times over. The fix spreads the weighted days
--     evenly across the working days of the window, so an enquiry
--     contributes its own size in total and no more, distributed across
--     the weeks it might actually land in.
--
--  2. OPEN WORK WAS PLOTTED IN THE PAST
--     target_install_from comes off the quote, so an enquiry quoted in
--     June with a window in August is still open today and was being
--     drawn into August — weeks that have already gone. Nothing can be
--     built in the past. Any window that has slipped behind today is now
--     clamped forward to this week, which is where that work would
--     actually have to go.
--
--  The bug was invisible until there was enough seeded data to make the
--  scale absurd. With three enquiries it looked like a plausible line.
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
-- Each open enquiry, its weighted size, and the window it could land in,
-- never earlier than today.
windows as (
  select
    p.id,
    greatest(p.est_production_days * coalesce(p.probability, 0) / 100.0, 0) as weighted_days,
    greatest(coalesce(p.target_install_from, current_date + 30), current_date) as win_from,
    greatest(
      greatest(coalesce(p.target_install_to, current_date + 60), current_date + 10),
      greatest(coalesce(p.target_install_from, current_date + 30), current_date)
    ) as win_to
  from public.v_pipeline_open p
),
-- One row per working day of each window, carrying how many days that
-- window has, so the weight can be divided rather than repeated.
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
-- COLUMN ORDER AND TYPES ARE FIXED BY THE EXISTING VIEW.
-- `create or replace view` refuses to retype a column or slot a new one
-- into the middle, and mv_dashboard_summary depends on this view, so
-- dropping it would take the summary with it. weighted_pipeline_days
-- therefore keeps its numeric(8,1), and the new column goes on the end.
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
  -- Committed work plus what the pipeline would add, against what the
  -- week can take. The number that says "do not sell into April".
  (coalesce(cm.days, 0) + coalesce(pl.weighted_days, 0)
     > coalesce(c.available_days, 15.0))                   as over_when_pipeline_lands
from weeks w
left join public.capacity_weeks c  on c.week_start  = w.week_start
left join committed             cm on cm.week_start = w.week_start
left join pipeline              pl on pl.week_start = w.week_start;

comment on view public.v_weekly_capacity is
  'Available against committed job-days per ISO week. Weighted pipeline is spread across the working days of each install window, never repeated per day, and never plotted before today.';

grant select on public.v_weekly_capacity to authenticated;
revoke all on public.v_weekly_capacity from anon;

select public.refresh_dashboard();

-- What the chart will now draw. weighted_pipeline_days should sit in the
-- same range as committed_days, not ten times it.
select week_start, available_days, committed_days, weighted_pipeline_days,
       over_capacity, over_when_pipeline_lands
  from public.v_weekly_capacity
 where week_start between date_trunc('week', current_date - interval '4 weeks')
                      and date_trunc('week', current_date + interval '16 weeks')
 order by week_start;
