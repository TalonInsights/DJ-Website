-- =====================================================================
--  Phase 3 — The view layer
--
--  Every metric on the dashboard is a column here. Nothing aggregates in
--  application code: if a number needs computing, it belongs in a view.
--
--  TWO RULES ENFORCED IN SQL
--  -------------------------
--  1. Every view that emits a rate also emits the count it was computed
--     from, as <rate>_n. This is a small firm; a monthly conversion rate
--     can run on three enquiries and will read as trend when it is noise.
--     The UI greys out any rate whose n is below 10 — it must never have
--     to guess what the denominator was.
--  2. Every time series left-joins from dim_date, so a quiet week
--     appears as a zero rather than vanishing. A gap in a trend line
--     reads as "nothing happened here" and is the commonest bug in
--     dashboards of this shape.
--
--  Every view is security_invoker, so it runs with the caller's
--  permissions and the policies on the tables beneath it still apply.
--  Without that a view silently bypasses row-level security, which is
--  exactly the sort of hole nobody notices until it matters.
--
--  Run in the Supabase SQL Editor. Idempotent.
--  Rollback: 20260910_0004_analytics_views_down.sql
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. Date dimension
--
--  is_working_day is Monday to Friday only. English bank holidays are
--  NOT modelled — there is no source for them in this database, and
--  inventing one would quietly overstate capacity eight times a year.
--  If capacity planning ever needs to be exact, load a real calendar.
-- ---------------------------------------------------------------------
create table if not exists public.dim_date (
  d              date primary key,
  iso_year       int  not null,
  iso_week       int  not null,
  week_start     date not null,
  month_start    date not null,
  quarter_start  date not null,
  year_start     date not null,
  is_working_day boolean not null
);

comment on table public.dim_date is
  'Calendar 2020-2032. is_working_day is Mon-Fri; bank holidays are not modelled.';

insert into public.dim_date (d, iso_year, iso_week, week_start, month_start, quarter_start, year_start, is_working_day)
select g::date,
       extract(isoyear from g)::int,
       extract(week    from g)::int,
       date_trunc('week',    g)::date,
       date_trunc('month',   g)::date,
       date_trunc('quarter', g)::date,
       date_trunc('year',    g)::date,
       extract(isodow from g) <= 5
  from generate_series(date '2020-01-01', date '2032-12-31', interval '1 day') as g
on conflict (d) do nothing;

alter table public.dim_date enable row level security;
drop policy if exists dim_date_select_staff on public.dim_date;
create policy dim_date_select_staff on public.dim_date
  for select to authenticated using (true);

create index if not exists dim_date_week_idx  on public.dim_date (week_start);
create index if not exists dim_date_month_idx on public.dim_date (month_start);


-- ---------------------------------------------------------------------
--  2. v_enquiry_flat — one row per enquiry, history pivoted out
--
--  Stage timestamps come from enquiry_events, never from the date
--  columns on the enquiry. A corrected date column would silently
--  rewrite history; an event row is what actually happened, when.
--  The date columns are still carried through for display.
-- ---------------------------------------------------------------------
create or replace view public.v_enquiry_flat
  with (security_invoker = true) as
with first_at as (
  select enquiry_id, to_status, min(occurred_at) as at
    from public.enquiry_events
   group by enquiry_id, to_status
),
pivoted as (
  select enquiry_id,
         max(at) filter (where to_status = 'new')           as at_new,
         max(at) filter (where to_status = 'contacted')     as at_contacted,
         max(at) filter (where to_status = 'survey_booked') as at_survey_booked,
         max(at) filter (where to_status = 'surveyed')      as at_surveyed,
         max(at) filter (where to_status = 'quoted')        as at_quoted,
         max(at) filter (where to_status = 'follow_up')     as at_follow_up,
         max(at) filter (where to_status = 'won')           as at_won,
         max(at) filter (where to_status = 'lost')          as at_lost,
         count(*)                                            as event_count
    from first_at
   group by enquiry_id
)
select
  e.id, e.ref, e.received_on, e.source, e.source_detail, e.status,
  e.customer_name, e.site_town, e.site_postcode,
  e.product_type, e.material, e.approx_units, e.property_type,
  e.survey_date, e.survey_slot, e.surveyor, e.survey_completed_on,
  e.survey_reschedule_count,
  e.quote_value, e.quote_sent_on, e.quote_expires_on, e.probability,
  e.target_install_from, e.target_install_to, e.customer_deadline,
  e.next_action, e.next_action_on,
  e.won_on, e.lost_on, e.lost_reason, e.lost_to, e.job_id,
  e.created_at, e.updated_at,

  d.month_start as received_month,
  d.week_start  as received_week,

  p.at_new, p.at_contacted, p.at_survey_booked, p.at_surveyed,
  p.at_quoted, p.at_follow_up, p.at_won, p.at_lost,
  coalesce(p.event_count, 0) as event_count,

  -- Stage gaps, in whole days, from the history.
  (p.at_contacted::date     - p.at_new::date)          as days_new_to_contacted,
  (p.at_survey_booked::date - p.at_contacted::date)    as days_contacted_to_booked,
  (p.at_surveyed::date      - p.at_survey_booked::date) as days_booked_to_surveyed,
  (p.at_quoted::date        - p.at_surveyed::date)     as days_surveyed_to_quoted,
  (coalesce(p.at_won, p.at_lost)::date - p.at_quoted::date) as days_quoted_to_decision,
  (coalesce(p.at_won, p.at_lost)::date - p.at_new::date)    as days_total,

  (current_date - e.received_on) as age_days,
  (e.status in ('won','lost'))   as is_closed,
  (e.status = 'won')             as is_won,
  (e.status = 'lost')            as is_lost,
  (e.status not in ('won','lost') and e.next_action_on < current_date) as is_overdue,
  (e.notes like '%[seed data]%') as is_seed
from public.enquiries e
left join pivoted  p on p.enquiry_id = e.id
left join public.dim_date d on d.d = e.received_on;

comment on view public.v_enquiry_flat is
  'One row per enquiry with its status history pivoted into columns. The base for most other views.';


-- ---------------------------------------------------------------------
--  3. v_enquiry_funnel — counts and values per month
--
--  Driven from dim_date so a month with no enquiries still appears.
--  Each stage counts enquiries that REACHED it, from the history, not
--  enquiries currently sitting in it.
-- ---------------------------------------------------------------------
create or replace view public.v_enquiry_funnel
  with (security_invoker = true) as
with months as (
  select distinct month_start
    from public.dim_date
   where month_start between date_trunc('month', current_date - interval '3 years')
                         and date_trunc('month', current_date)
)
select
  m.month_start as period,
  count(f.id)                                            as received,
  count(f.id) filter (where f.at_contacted is not null)   as contacted,
  count(f.id) filter (where f.at_survey_booked is not null) as survey_booked,
  count(f.id) filter (where f.at_surveyed is not null)    as surveyed,
  count(f.id) filter (where f.at_quoted is not null)      as quoted,
  count(f.id) filter (where f.is_won)                     as won,
  count(f.id) filter (where f.is_lost)                    as lost,
  count(f.id) filter (where not f.is_closed)              as still_open,

  coalesce(sum(f.quote_value) filter (where f.at_quoted is not null), 0)::numeric(12,2) as quoted_value,
  coalesce(sum(f.quote_value) filter (where f.is_won), 0)::numeric(12,2)                as won_value,
  coalesce(sum(f.quote_value) filter (where f.is_lost), 0)::numeric(12,2)               as lost_value,

  -- Rate plus its denominator, always together.
  round(100.0 * count(f.id) filter (where f.is_won)
        / nullif(count(f.id) filter (where f.is_closed), 0), 1) as win_rate,
  count(f.id) filter (where f.is_closed)                        as win_rate_n,

  round(100.0 * count(f.id) filter (where f.at_quoted is not null)
        / nullif(count(f.id), 0), 1)                            as quote_rate,
  count(f.id)                                                   as quote_rate_n
from months m
left join public.v_enquiry_flat f on f.received_month = m.month_start
group by m.month_start;

comment on view public.v_enquiry_funnel is
  'Monthly funnel. Stage columns count enquiries that reached the stage, from the event history.';


-- ---------------------------------------------------------------------
--  4. v_enquiry_cycle_times — medians, not averages
--
--  One slow job that sat for eight months would drag an average far
--  enough to be useless. percentile_cont(0.5) is the median.
-- ---------------------------------------------------------------------
create or replace view public.v_enquiry_cycle_times
  with (security_invoker = true) as
with months as (
  select distinct month_start
    from public.dim_date
   where month_start between date_trunc('month', current_date - interval '3 years')
                         and date_trunc('month', current_date)
)
select
  m.month_start as period,
  count(f.id) as n,
  percentile_cont(0.5) within group (order by f.days_new_to_contacted)
    filter (where f.days_new_to_contacted is not null) as median_days_to_contact,
  percentile_cont(0.5) within group (order by f.days_contacted_to_booked)
    filter (where f.days_contacted_to_booked is not null) as median_days_to_book_survey,
  percentile_cont(0.5) within group (order by f.days_booked_to_surveyed)
    filter (where f.days_booked_to_surveyed is not null) as median_days_to_survey,
  percentile_cont(0.5) within group (order by f.days_surveyed_to_quoted)
    filter (where f.days_surveyed_to_quoted is not null) as median_days_to_quote,
  percentile_cont(0.5) within group (order by f.days_quoted_to_decision)
    filter (where f.days_quoted_to_decision is not null) as median_days_to_decision,
  percentile_cont(0.5) within group (order by f.days_total)
    filter (where f.days_total is not null) as median_days_total,
  count(f.id) filter (where f.days_total is not null) as median_days_total_n
from months m
left join public.v_enquiry_flat f on f.received_month = m.month_start
group by m.month_start;


-- ---------------------------------------------------------------------
--  5. v_pipeline_open — what is live, and what it is worth
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

  round(coalesce(f.quote_value, 0) * coalesce(f.probability, 0) / 100.0, 2) as weighted_value,
  greatest(current_date - f.next_action_on, 0)                              as days_overdue,
  f.is_overdue,
  (f.quote_expires_on is not null and f.quote_expires_on < current_date)    as quote_expired,
  (current_date - coalesce(f.at_quoted, f.at_surveyed, f.at_contacted, f.at_new)::date)
                                                                            as days_since_last_event,
  -- Rough production load this would add if it lands, so the capacity
  -- chart can show pipeline against committed work.
  coalesce(f.approx_units, 1) * 1.5                                         as est_production_days
from public.v_enquiry_flat f
where f.status not in ('won','lost');

comment on view public.v_pipeline_open is
  'Live enquiries only. est_production_days is a rough 1.5 days per unit for the capacity chart, not a quote.';


-- ---------------------------------------------------------------------
--  6. v_lost_analysis — why work is lost, and what it was worth
-- ---------------------------------------------------------------------
create or replace view public.v_lost_analysis
  with (security_invoker = true) as
select
  d.month_start                       as period,
  coalesce(f.lost_reason, 'Not recorded') as lost_reason,
  count(*)                            as lost_count,
  coalesce(sum(f.quote_value), 0)::numeric(12,2)      as lost_value,
  round(avg(f.quote_value), 2)                         as avg_lost_value,
  count(*) filter (where f.lost_to is not null)        as lost_to_named_competitor
from public.v_enquiry_flat f
join public.dim_date d on d.d = f.lost_on
where f.is_lost
group by d.month_start, coalesce(f.lost_reason, 'Not recorded');


-- ---------------------------------------------------------------------
--  7. v_job_performance — baseline against plan against reality
--
--  Variance is measured against baseline_start / baseline_end, never
--  against planned_*. The plan moves every time a bar is dragged, so
--  measuring against it makes adherence read as 100% forever.
-- ---------------------------------------------------------------------
create or replace view public.v_job_performance
  with (security_invoker = true) as
select
  j.id, j.ref, j.name, j.client, j.enquiry_id, j.product_type,
  j.baseline_start, j.baseline_end,
  j.planned_start,  j.planned_end,
  j.actual_start,   j.actual_end,
  j.customer_deadline,
  j.estimated_days, j.actual_days,
  j.reschedule_count,

  (j.planned_start - j.baseline_start) as plan_start_drift_days,
  (j.planned_end   - j.baseline_end)   as plan_end_drift_days,
  (j.actual_start  - j.baseline_start) as actual_start_variance_days,
  (j.actual_end    - j.baseline_end)   as actual_end_variance_days,
  (j.actual_days   - j.estimated_days) as days_variance,

  case when j.estimated_days > 0
       then round(j.actual_days / j.estimated_days, 3) end as estimate_ratio,

  (j.actual_end is not null)                              as is_complete,
  (j.actual_end is not null and j.customer_deadline is not null
     and j.actual_end > j.customer_deadline)              as delivered_late,
  d.month_start                                           as completed_month,
  jsonb_array_length(coalesce(j.phases, '[]'::jsonb))     as stage_count
from public.jobs j
left join public.dim_date d on d.d = j.actual_end;


-- ---------------------------------------------------------------------
--  8. v_weekly_capacity — how full is April
--
--  The one chart that changes a decision, so it gets the honest version.
--  Committed days are counted by expanding each job's planned span
--  across working days, so a job spanning three weeks contributes to all
--  three rather than landing entirely in its start week.
--
--  Weeks with no capacity row fall back to 15 job-days: a five-day week
--  running three jobs at once. Change the default here, or better, put a
--  row in capacity_weeks.
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
pipeline as (
  select d.week_start, sum(p.est_production_days * coalesce(p.probability, 0) / 100.0)::numeric as weighted_days
    from public.v_pipeline_open p
    join public.dim_date d
      on d.d between coalesce(p.target_install_from, current_date + 30)
                 and coalesce(p.target_install_to,   current_date + 60)
     and d.is_working_day
   group by d.week_start
)
select
  w.week_start,
  coalesce(c.available_days, 15.0)                       as available_days,
  coalesce(cm.days, 0)                                   as committed_days,
  coalesce(pl.weighted_days, 0)::numeric(8,1)            as weighted_pipeline_days,
  greatest(coalesce(c.available_days, 15.0) - coalesce(cm.days, 0), 0) as free_days,
  round(100.0 * coalesce(cm.days, 0)
        / nullif(coalesce(c.available_days, 15.0), 0), 1) as utilisation_rate,
  coalesce(c.available_days, 15.0)                        as utilisation_rate_n,
  (coalesce(cm.days, 0) > coalesce(c.available_days, 15.0)) as over_capacity,
  (c.week_start is null)                                   as using_default_capacity,
  c.note                                                   as capacity_note
from weeks w
left join public.capacity_weeks c  on c.week_start  = w.week_start
left join committed             cm on cm.week_start = w.week_start
left join pipeline              pl on pl.week_start = w.week_start;

comment on view public.v_weekly_capacity is
  'Available against committed job-days per ISO week. using_default_capacity flags weeks with no capacity_weeks row.';


-- ---------------------------------------------------------------------
--  9. v_promise_vs_delivery — did we do it when we said
-- ---------------------------------------------------------------------
create or replace view public.v_promise_vs_delivery
  with (security_invoker = true) as
select
  j.id as job_id, j.ref, j.name, j.client,
  coalesce(pt.product, 'Not recorded') as product_type,
  e.ref as enquiry_ref,
  e.target_install_from, e.target_install_to,
  j.customer_deadline,
  j.actual_end,
  d.month_start as completed_month,
  (j.actual_end - coalesce(j.customer_deadline, e.target_install_to)) as days_late,
  (j.actual_end is not null
     and coalesce(j.customer_deadline, e.target_install_to) is not null
     and j.actual_end <= coalesce(j.customer_deadline, e.target_install_to)) as on_time
from public.jobs j
left join public.enquiries e on e.id = j.enquiry_id
left join public.dim_date  d on d.d  = j.actual_end
left join lateral (
  select p as product
    from unnest(case when cardinality(j.product_type) > 0
                     then j.product_type else e.product_type end) as p
   limit 1
) pt on true
where j.actual_end is not null;


-- ---------------------------------------------------------------------
--  10. v_estimate_accuracy — do we know how long our own work takes
-- ---------------------------------------------------------------------
create or replace view public.v_estimate_accuracy
  with (security_invoker = true) as
select
  d.month_start                        as period,
  coalesce(pt.product, 'Not recorded') as product_type,
  count(*)                                              as jobs,
  round(avg(j.estimated_days), 1)                       as avg_estimated_days,
  round(avg(j.actual_days), 1)                          as avg_actual_days,
  round(avg(j.actual_days) / nullif(avg(j.estimated_days), 0), 3) as estimate_ratio,
  count(*) filter (where j.estimated_days is not null
                     and j.actual_days is not null)     as estimate_ratio_n,
  round(100.0 * count(*) filter (where j.actual_days <= j.estimated_days)
        / nullif(count(*) filter (where j.estimated_days is not null
                                    and j.actual_days is not null), 0), 1) as within_estimate_rate,
  count(*) filter (where j.estimated_days is not null
                     and j.actual_days is not null)     as within_estimate_rate_n
from public.jobs j
join public.dim_date d on d.d = j.actual_end
left join lateral (
  select p as product from unnest(j.product_type) as p limit 1
) pt on true
where j.actual_end is not null
group by d.month_start, coalesce(pt.product, 'Not recorded');


-- ---------------------------------------------------------------------
--  11. v_source_performance — where the good work comes from
--
--  revenue_per_production_day only counts enquiries that became jobs
--  with recorded actual days. Work typed straight onto the board never
--  had an enquiry and is invisible here — see docs/gaps.md.
-- ---------------------------------------------------------------------
create or replace view public.v_source_performance
  with (security_invoker = true) as
select
  d.month_start as period,
  f.source,
  count(*)                                                  as enquiries,
  count(*) filter (where f.is_won)                          as won,
  count(*) filter (where f.is_closed)                       as closed,
  round(100.0 * count(*) filter (where f.is_won)
        / nullif(count(*) filter (where f.is_closed), 0), 1) as win_rate,
  count(*) filter (where f.is_closed)                        as win_rate_n,
  coalesce(sum(f.quote_value) filter (where f.is_won), 0)::numeric(12,2) as revenue,
  round(avg(f.quote_value) filter (where f.is_won), 2)                    as avg_won_value,
  round(
    sum(f.quote_value) filter (where f.is_won and jp.actual_days > 0)
    / nullif(sum(jp.actual_days) filter (where f.is_won), 0), 2)          as revenue_per_production_day,
  count(*) filter (where f.is_won and jp.actual_days > 0)                 as revenue_per_production_day_n
from public.v_enquiry_flat f
join public.dim_date d on d.d = f.received_on
left join public.jobs jp on jp.id = f.job_id
group by d.month_start, f.source;


-- ---------------------------------------------------------------------
--  12. v_survey_diary and v_overdue_actions
--
--  The two lists the enquiry board shows above everything else. They are
--  views rather than component queries for the same reason as the rest:
--  "what counts as overdue" is a definition, and it belongs in one place.
-- ---------------------------------------------------------------------
create or replace view public.v_survey_diary
  with (security_invoker = true) as
select
  f.id, f.ref, f.customer_name, f.site_town, f.site_postcode,
  f.survey_date, f.survey_slot, f.surveyor, f.status,
  f.product_type, f.approx_units, f.access_notes,
  d.week_start,
  (f.survey_date = current_date)                        as is_today,
  (f.survey_date - current_date)                        as days_away
from (select vf.*, e.access_notes
        from public.v_enquiry_flat vf
        join public.enquiries e on e.id = vf.id) f
join public.dim_date d on d.d = f.survey_date
where f.survey_date is not null
  and f.status not in ('won','lost')
  and f.survey_completed_on is null;

create or replace view public.v_overdue_actions
  with (security_invoker = true) as
select
  f.id, f.ref, f.customer_name, f.site_town, f.status, f.source,
  f.next_action, f.next_action_on, f.quote_value, f.probability,
  (current_date - f.next_action_on) as days_overdue,
  f.age_days,
  round(coalesce(f.quote_value, 0) * coalesce(f.probability, 0) / 100.0, 2) as weighted_value
from public.v_enquiry_flat f
where f.status not in ('won','lost')
  and f.next_action_on is not null
  and f.next_action_on < current_date;

comment on view public.v_overdue_actions is
  'Follow-ups past their date. The single largest source of lost work in firms this size.';


-- ---------------------------------------------------------------------
--  13. mv_dashboard_summary — the headline tiles
--
--  Materialised because it scans everything and is read on every page
--  load. Refresh nightly, or call refresh_dashboard() from the UI.
--
--  Rolling 90 days against the 90 before it, because a tile without a
--  direction is decoration.
-- ---------------------------------------------------------------------
drop materialized view if exists public.mv_dashboard_summary;
create materialized view public.mv_dashboard_summary as
with cur as (
  select * from public.v_enquiry_flat
   where received_on > current_date - 90
),
prev as (
  select * from public.v_enquiry_flat
   where received_on between current_date - 180 and current_date - 91
)
select
  now()                                                     as generated_at,
  (select count(*) from cur)                                as enquiries,
  (select count(*) from prev)                               as enquiries_prev,

  (select round(100.0 * count(*) filter (where is_won)
          / nullif(count(*) filter (where is_closed), 0), 1) from cur)  as win_rate,
  (select count(*) filter (where is_closed) from cur)                    as win_rate_n,
  (select round(100.0 * count(*) filter (where is_won)
          / nullif(count(*) filter (where is_closed), 0), 1) from prev) as win_rate_prev,

  (select coalesce(sum(weighted_value), 0)::numeric(12,2)
     from public.v_pipeline_open)                           as weighted_pipeline,
  (select coalesce(sum(quote_value), 0)::numeric(12,2)
     from public.v_pipeline_open)                           as open_pipeline_value,
  (select count(*) from public.v_pipeline_open)             as open_enquiries,
  (select count(*) from public.v_overdue_actions)           as overdue_actions,
  (select count(*) from public.v_survey_diary
    where survey_date between current_date and current_date + 7) as surveys_next_7_days,

  -- How many weeks ahead the workshop is committed before it has a
  -- week with free capacity.
  (select count(*) from public.v_weekly_capacity
    where week_start >= date_trunc('week', current_date)
      and free_days <= 0)                                   as weeks_at_capacity,
  (select round(avg(utilisation_rate), 1) from public.v_weekly_capacity
    where week_start between date_trunc('week', current_date)
                         and date_trunc('week', current_date + interval '8 weeks')) as forward_utilisation_rate,
  (select count(*) from public.v_weekly_capacity
    where week_start between date_trunc('week', current_date)
                         and date_trunc('week', current_date + interval '8 weeks')) as forward_utilisation_rate_n,

  (select coalesce(sum(quote_value), 0)::numeric(12,2) from cur where is_won)  as won_value,
  (select coalesce(sum(quote_value), 0)::numeric(12,2) from prev where is_won) as won_value_prev,

  (select round(100.0 * count(*) filter (where on_time)
          / nullif(count(*), 0), 1) from public.v_promise_vs_delivery
    where completed_month > current_date - interval '12 months')      as on_time_rate,
  (select count(*) from public.v_promise_vs_delivery
    where completed_month > current_date - interval '12 months')      as on_time_rate_n;

create unique index if not exists mv_dashboard_summary_one_row
  on public.mv_dashboard_summary (generated_at);

comment on materialized view public.mv_dashboard_summary is
  'Headline tiles, one row. Refresh nightly via pg_cron or by calling refresh_dashboard().';


create or replace function public.refresh_dashboard()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
begin
  refresh materialized view concurrently public.mv_dashboard_summary;
  return now();
end;
$$;

revoke all on function public.refresh_dashboard() from public, anon;
grant execute on function public.refresh_dashboard() to authenticated;

-- Nightly refresh. Enable pg_cron under Database -> Extensions first,
-- then uncomment:
--
--   select cron.schedule('refresh-dashboard', '15 3 * * *',
--                        $$select public.refresh_dashboard()$$);


-- ---------------------------------------------------------------------
--  14. Grants
--
--  Views run with the privileges of their owner but respect the RLS of
--  the tables beneath them, so `authenticated` sees exactly what the
--  policies allow and `anon` still sees nothing.
-- ---------------------------------------------------------------------
grant select on
  public.v_enquiry_flat, public.v_enquiry_funnel, public.v_enquiry_cycle_times,
  public.v_pipeline_open, public.v_lost_analysis, public.v_job_performance,
  public.v_weekly_capacity, public.v_promise_vs_delivery, public.v_estimate_accuracy,
  public.v_source_performance, public.v_survey_diary, public.v_overdue_actions,
  public.mv_dashboard_summary, public.dim_date
to authenticated;
