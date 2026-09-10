-- =====================================================================
--  Close an anonymous read on the dashboard summary
--
--  FOUND IN PRODUCTION, 10 September 2026, minutes after install.sql ran.
--
--  Probing the live API with the publishable key returned the entire
--  mv_dashboard_summary row to an anonymous caller:
--
--    GET /rest/v1/mv_dashboard_summary   ->  200
--    [{"generated_at":"...","enquiries":0,"win_rate":null, ...}]
--
--  It was all zeros only because there was no data yet. With real
--  enquiries in it, anyone holding the publishable key — which is in the
--  browser and in this repository, by design — could have read the
--  firm's enquiry volume, win rate, weighted pipeline and revenue.
--
--  WHY IT HAPPENED
--  ---------------
--  Two things combined.
--
--  1. Supabase sets ALTER DEFAULT PRIVILEGES on the public schema so
--     that new tables and views are granted to `anon` and `authenticated`
--     automatically. Granting explicitly to `authenticated`, as the view
--     migration did, adds a grant; it does not remove the one that was
--     already there.
--
--  2. Row-level security does not apply to materialised views. Every
--     ordinary view and table here was still safe, because RLS filtered
--     anon down to nothing — which is why they all returned `[]` and
--     looked identical to a locked door. The materialised view had no
--     such backstop and simply handed the row over.
--
--  The lesson is that a 200 with an empty array is not proof of
--  anything. The only object that behaved differently was the only one
--  RLS could not protect.
--
--  Run in the Supabase SQL Editor. Idempotent.
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. The actual hole
-- ---------------------------------------------------------------------
revoke all on public.mv_dashboard_summary from anon;
revoke all on public.mv_dashboard_summary from public;
grant select on public.mv_dashboard_summary to authenticated;


-- ---------------------------------------------------------------------
--  2. Belt and braces on everything else
--
--  These are all protected by RLS already, so anon reads nothing from
--  them today. The grant should not be sitting there regardless: it is
--  one accidental `disable row level security`, or one permissive policy
--  written in a hurry, away from being live. Take the grant away and the
--  mistake has to be made twice.
-- ---------------------------------------------------------------------
revoke all on public.enquiries       from anon;
revoke all on public.enquiry_events  from anon;
revoke all on public.enquiry_ref_seq from anon;
revoke all on public.job_events      from anon;
revoke all on public.capacity_weeks  from anon;
revoke all on public.dim_date        from anon;
revoke all on public.jobs            from anon;

revoke all on public.v_enquiry_flat        from anon;
revoke all on public.v_enquiry_funnel      from anon;
revoke all on public.v_enquiry_cycle_times from anon;
revoke all on public.v_pipeline_open       from anon;
revoke all on public.v_lost_analysis       from anon;
revoke all on public.v_job_performance     from anon;
revoke all on public.v_weekly_capacity     from anon;
revoke all on public.v_promise_vs_delivery from anon;
revoke all on public.v_estimate_accuracy   from anon;
revoke all on public.v_source_performance  from anon;
revoke all on public.v_survey_diary        from anon;
revoke all on public.v_overdue_actions     from anon;


-- ---------------------------------------------------------------------
--  3. Stop the next object inheriting the same grant
--
--  Without this, the next table or view added to this schema arrives
--  readable by anon all over again.
-- ---------------------------------------------------------------------
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke all on functions from anon;


-- ---------------------------------------------------------------------
--  4. Prove it
--
--  Should return no rows. Any row here is an object `anon` can still
--  read; check it is one you meant to publish.
-- ---------------------------------------------------------------------
select table_name, privilege_type
  from information_schema.role_table_grants
 where grantee = 'anon'
   and table_schema = 'public'
 order by table_name, privilege_type;
