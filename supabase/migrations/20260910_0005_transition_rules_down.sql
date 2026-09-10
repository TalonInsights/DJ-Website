-- Rollback for 20260910_0005_transition_rules.sql
drop trigger  if exists enquiries_check_transition on public.enquiries;
drop function if exists public.check_enquiry_transition();
drop function if exists public.convert_enquiry_to_job(uuid, text, date);
