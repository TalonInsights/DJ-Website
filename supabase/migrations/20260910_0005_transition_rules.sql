-- =====================================================================
--  Phase 4 — Status transition rules and enquiry conversion
--
--  The plan puts these rules in a server action. This build has no server
--  runtime, and row-level security lets any signed-in member of staff
--  update an enquiry directly, so a rule that lives only in the client is
--  not a rule. They are enforced here as a trigger, where nothing can go
--  round them.
--
--  Cheap to write, and it is the only thing that makes the analytics
--  worth anything twelve months from now: a quoted enquiry with no quote
--  value poisons every conversion and value metric downstream.
--
--  Run in the Supabase SQL Editor. Idempotent.
--  Rollback: 20260910_0005_transition_rules_down.sql
-- =====================================================================


-- ---------------------------------------------------------------------
--  1. What each status requires before an enquiry may enter it
--
--    contacted      first_contacted_on
--    survey_booked  survey_date, surveyor
--    surveyed       survey_completed_on
--    quoted         quote_value, quote_sent_on
--    won            quote_value
--    lost           lost_reason
--
--  The error names the missing field, so the UI can open the drawer
--  focused on it rather than saying "invalid".
-- ---------------------------------------------------------------------
create or replace function public.check_enquiry_transition()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  missing text[] := '{}';
begin
  if tg_op = 'UPDATE' and new.status is not distinct from old.status then
    return new;
  end if;

  case new.status
    when 'contacted' then
      if new.first_contacted_on is null then missing := missing || 'first_contacted_on'; end if;

    when 'survey_booked' then
      if new.survey_date is null then missing := missing || 'survey_date'; end if;
      if coalesce(trim(new.surveyor), '') = '' then missing := missing || 'surveyor'; end if;

    when 'surveyed' then
      if new.survey_completed_on is null then missing := missing || 'survey_completed_on'; end if;

    when 'quoted' then
      if new.quote_value is null then missing := missing || 'quote_value'; end if;
      if new.quote_sent_on is null then missing := missing || 'quote_sent_on'; end if;

    when 'won' then
      if new.quote_value is null then missing := missing || 'quote_value'; end if;

    when 'lost' then
      if coalesce(trim(new.lost_reason), '') = '' then missing := missing || 'lost_reason'; end if;

    else
      null;   -- new, follow_up and on_hold require nothing
  end case;

  if array_length(missing, 1) > 0 then
    raise exception
      'Cannot move % to %: missing %',
      coalesce(new.ref, 'enquiry'), new.status, array_to_string(missing, ', ')
      using errcode   = 'check_violation',
            hint      = array_to_string(missing, ','),
            detail    = new.status::text;
  end if;

  -- Keep the outcome dates honest without making the caller supply them.
  if new.status = 'won'  and new.won_on  is null then new.won_on  := current_date; end if;
  if new.status = 'lost' and new.lost_on is null then new.lost_on := current_date; end if;

  return new;
end;
$$;

drop trigger if exists enquiries_check_transition on public.enquiries;
create trigger enquiries_check_transition
  before insert or update of status on public.enquiries
  for each row execute function public.check_enquiry_transition();


-- ---------------------------------------------------------------------
--  2. Convert a won enquiry into a job
--
--  Does both halves of the link in one transaction. A job created from
--  an enquiry without the link is worse than no job at all: it silently
--  breaks every cross-domain metric, and nothing later can tell that it
--  should have been connected.
--
--  estimated_days is seeded from what this product type has actually
--  taken before, falling back to a fortnight when there is no history.
-- ---------------------------------------------------------------------
create or replace function public.convert_enquiry_to_job(
  p_enquiry_id uuid,
  p_name       text default null,
  p_start      date default null
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  e        public.enquiries%rowtype;
  new_id   uuid;
  est      numeric(6,1);
  job_name text;
begin
  select * into e from public.enquiries where id = p_enquiry_id;
  if not found then
    raise exception 'No enquiry with id %', p_enquiry_id using errcode = 'no_data_found';
  end if;

  if e.job_id is not null then
    raise exception 'Enquiry % already has a job', e.ref using errcode = 'unique_violation';
  end if;

  select round(avg(j.actual_days), 1) into est
    from public.jobs j
   where j.actual_days is not null
     and j.product_type && e.product_type;

  est := coalesce(est, 10.0);

  job_name := coalesce(nullif(trim(p_name), ''),
                       coalesce(e.customer_name, 'Job') || ' — ' ||
                       coalesce(e.product_type[1], 'joinery'));

  insert into public.jobs (name, client, ref, deadline, customer_deadline,
                           enquiry_id, product_type, estimated_days, phases)
  values (job_name,
          e.customer_name,
          e.ref,
          coalesce(e.customer_deadline, e.target_install_to),
          coalesce(e.customer_deadline, e.target_install_to),
          e.id,
          e.product_type,
          est,
          '[]'::jsonb)
  returning id into new_id;

  update public.enquiries set job_id = new_id where id = e.id;

  return new_id;
end;
$$;

revoke all on function public.convert_enquiry_to_job(uuid, text, date) from public, anon;
grant execute on function public.convert_enquiry_to_job(uuid, text, date) to authenticated;

comment on function public.convert_enquiry_to_job(uuid, text, date) is
  'Creates a job from a won enquiry and links both sides. Never create the job separately.';
