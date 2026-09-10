-- =====================================================================
--  Name the weighted pipeline in days, so it cannot be confused with
--  the weighted pipeline in pounds
--
--  The reconciliation added in 0009 compared:
--
--      sum(v_pipeline_open.weighted_value)      = 139,234
--      sum(v_weekly_capacity.weighted_pipeline_days) = 104
--
--  and reported a difference of 139,130, which looked like catastrophic
--  data loss. It was not. `weighted_value` is MONEY — quote value times
--  probability — and `weighted_pipeline_days` is WORK. The check was
--  comparing pounds to days.
--
--  The mistake was possible because the view exposed the money figure
--  under a name that could be read either way, and never exposed the
--  days figure at all: it was computed inline inside v_weekly_capacity,
--  where nothing else could see it or check it. A quantity that two
--  views need, in a unit that is easy to mistake, should be a named
--  column.
--
--  So v_pipeline_open now carries both, named for their units:
--     weighted_value  numeric  — pounds, quote value x probability
--     weighted_days   numeric  — job-days, production estimate x probability
--
--  and v_weekly_capacity divides the named column rather than repeating
--  the formula. The reconciliation then compares like with like.
--
--  Both replacements append at the end and change no existing column's
--  name, type or position, so mv_dashboard_summary is undisturbed.
--
--  Run in the Supabase SQL Editor. Idempotent.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. v_pipeline_open gains weighted_days, appended
-- ---------------------------------------------------------------------
create or replace view public.v_pipeline_open
  with (security_invoker = true) as
select
  f.id, f.ref, f.customer_name, f.site_town, f.status, f.source,
  f.product_type, f.approx_units,
  f.received_on, f.age_days,
  f.survey_date, f.survey_slot, f.surveyor,
  f.quote_value, f.quote_sent_on, f.quote_expires_on, f.probability,
  f.next_action, f.next_action_on,
  f.target_install_from, f.target_install_to,

  -- POUNDS. What the enquiry is worth, discounted by how likely it is.
  round(coalesce(f.quote_value, 0) * coalesce(f.probability, 0) / 100.0, 2) as weighted_value,
  greatest(current_date - f.next_action_on, 0)                              as days_overdue,
  f.is_overdue,
  (f.quote_expires_on is not null and f.quote_expires_on < current_date)    as quote_expired,
  (current_date - coalesce(f.at_quoted, f.at_surveyed, f.at_contacted, f.at_new)::date)
                                                                            as days_since_last_event,
  -- JOB-DAYS. A rough day and a half per unit; not a quote, just enough
  -- to ask whether the workshop could take the work if it landed.
  coalesce(f.approx_units, 1) * 1.5                                         as est_production_days,

  -- JOB-DAYS, discounted by likelihood. The figure the capacity chart
  -- spreads across the install window. Named for its unit precisely so
  -- it is never again compared against the money one.
  round(coalesce(f.approx_units, 1) * 1.5
        * coalesce(f.probability, 0) / 100.0, 2)::numeric                    as weighted_days
from public.v_enquiry_flat f
where f.status not in ('won','lost');

comment on view public.v_pipeline_open is
  'Live enquiries only. weighted_value is pounds; weighted_days is job-days. est_production_days is a rough 1.5 days per unit for the capacity chart, not a quote.';


-- ---------------------------------------------------------------------
--  2. v_weekly_capacity uses the named column
-- ---------------------------------------------------------------------
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
windows as (
  select
    p.id,
    p.weighted_days,
    case
      when p.target_install_from is not null and p.target_install_from > current_date
        then p.target_install_from
      else current_date + 21
    end as win_from,
    case
      when p.target_install_from is not null and p.target_install_from > current_date
        then greatest(coalesce(p.target_install_to, p.target_install_from + 28),
                      p.target_install_from + 14)
      else current_date + 21 + 56
    end as win_to
  from public.v_pipeline_open p
),
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

grant select on public.v_pipeline_open, public.v_weekly_capacity to authenticated;
revoke all on public.v_pipeline_open   from anon;
revoke all on public.v_weekly_capacity from anon;

select public.refresh_dashboard();


-- ---------------------------------------------------------------------
--  3. The reconciliation, now comparing like with like
--
--  Both figures are job-days. They must agree within rounding. If they
--  do not, the spread is duplicating work across the days of a window,
--  or dropping enquiries whose window falls outside the weeks the view
--  covers.
-- ---------------------------------------------------------------------
select
  round((select sum(weighted_days)          from public.v_pipeline_open),   1) as pipeline_job_days,
  round((select sum(weighted_pipeline_days) from public.v_weekly_capacity), 1) as spread_job_days,
  round(abs(coalesce((select sum(weighted_days)          from public.v_pipeline_open),   0)
          - coalesce((select sum(weighted_pipeline_days) from public.v_weekly_capacity), 0)), 1)
    as difference,
  case when abs(coalesce((select sum(weighted_days)          from public.v_pipeline_open),   0)
               - coalesce((select sum(weighted_pipeline_days) from public.v_weekly_capacity), 0)) < 2
       then 'PASS' else 'FAIL' end as outcome,
  round((select sum(weighted_value) from public.v_pipeline_open), 2) as pipeline_pounds_for_reference;
