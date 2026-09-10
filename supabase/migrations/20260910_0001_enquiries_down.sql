-- =====================================================================
--  Rollback for 20260910_0001_enquiries.sql
--
--  DESTRUCTIVE. Drops every enquiry and its whole history.
--  Intended for a scratch database while proving the migration applies
--  clean. Do not run this against real data.
-- =====================================================================

drop trigger  if exists enquiries_log_status        on public.enquiries;
drop trigger  if exists enquiries_set_ref           on public.enquiries;
drop trigger  if exists enquiries_touch_updated_at  on public.enquiries;

drop function if exists public.purge_old_enquiries(int);
drop function if exists public.log_enquiry_status();
drop function if exists public.next_enquiry_ref();

drop table if exists public.enquiry_events;
drop table if exists public.enquiries;
drop table if exists public.enquiry_ref_seq;

drop type  if exists public.enquiry_status;
drop type  if exists public.enquiry_source;

-- Note: public.touch_updated_at() is deliberately left in place. It came
-- from the original schema.sql and `jobs` still uses it.
