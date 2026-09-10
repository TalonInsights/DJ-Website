-- =====================================================================
--  Seed — a year of jobs, and ten live on the board
--
--  The enquiry seed gave the pipeline something to show. This gives the
--  production side the same, which is what the capacity chart, schedule
--  variance, estimate accuracy and delivered-on-time panels all need —
--  without a single job they are correct and empty, which looks like a
--  bug.
--
--  What it creates:
--    * 90 further enquiries across the last 12 months, so monthly rates
--      have a real denominator instead of being greyed out at n=3
--    * 26 completed jobs spread over the past year, with baselines that
--      differ from the plan, real actual dates, and estimates that were
--      sometimes wrong — otherwise every variance chart is a single bar
--    * 10 jobs live on the board now, running into the next few weeks
--    * both halves of the enquiry-to-job link, wherever a won enquiry
--      was available to attach
--
--  Stage durations are the workshop's own defaults from planner.js:
--  timber 3, assembly 5, sanding 2, hardware 2, prep 2, spray 3,
--  glazing 2, dispatch 1, laid consecutively across working days.
--
--  Deterministic: setseed() means re-running gives identical data.
--
--  TEARDOWN, two commands:
--     delete from public.jobs       where ref like 'TEST-%';
--     delete from public.enquiries  where notes like '%[seed data]%';
--
--  Never load this into production.
-- =====================================================================


-- ---------------------------------------------------------------------
--  Working-day helpers. Temporary, so they disappear with the session.
-- ---------------------------------------------------------------------
create or replace function pg_temp.next_wd(d date)
returns date language plpgsql as $$
declare c date := d;
begin
  while extract(isodow from c) > 5 loop c := c + 1; end loop;
  return c;
end $$;

create or replace function pg_temp.add_wd(d date, n int)
returns date language plpgsql as $$
declare i int := 0; c date := d;
begin
  while i < n loop
    c := c + 1;
    if extract(isodow from c) <= 5 then i := i + 1; end if;
  end loop;
  return c;
end $$;

-- Lay the stages out consecutively from a start date and return the
-- phases array the planner reads, plus where it ends.
create or replace function pg_temp.build_phases(start_on date, n_stages int, who text)
returns jsonb language plpgsql as $$
declare
  stages text[] := array['timber','assembly','sanding','hardware','prep','spray','glazing','dispatch'];
  durs   int[]  := array[3,5,2,2,2,3,2,1];
  ph jsonb := '[]'::jsonb;
  cur date := pg_temp.next_wd(start_on);
  s date; e date; k int;
begin
  for k in 1..greatest(n_stages, 1) loop
    s := pg_temp.next_wd(cur);
    e := pg_temp.add_wd(s, durs[k] - 1);
    ph := ph || jsonb_build_array(jsonb_build_object(
      'key', stages[k], 'start', s::text, 'end', e::text, 'who', who));
    cur := pg_temp.add_wd(e, 1);
  end loop;
  return ph;
end $$;


-- ---------------------------------------------------------------------
--  1. Another 90 enquiries, concentrated in the last 12 months
--
--  Same shape as the first seed, but denser and more recent, so the
--  monthly funnel and win rate stop running on single-digit
--  denominators. Everything the analytics greys out below n=10 becomes
--  readable, which is the point of test data.
-- ---------------------------------------------------------------------
do $seed$
declare
  towns      text[] := array['Ironbridge','Shrewsbury','Much Wenlock','Telford','Broseley',
                             'Coalbrookdale','Bridgnorth','Newport','Albrighton','Shifnal',
                             'Wellington','Church Stretton'];
  products   text[] := array['Sliding sash windows','Casement windows','Entrance doors',
                             'French doors','Bi-fold doors','Bespoke joinery','Staircase'];
  materials  text[] := array['Accoya','Oak','Sapele','Idigbo','Redwood'];
  properties text[] := array['Listed building','In a conservation area','Period property, not listed',
                             'Modern property','Commercial or trade project'];
  surveyors  text[] := array['Harry','David'];
  lost_why   text[] := array['Price','Went elsewhere','Project postponed','No response',
                             'Outside our area','Timescale too long'];
  firstnames text[] := array['Margaret','Peter','Sarah','John','Elizabeth','David','Susan','Andrew',
                             'Catherine','Michael','Helen','Richard','Anne','Thomas','Ruth','Gerald'];
  surnames   text[] := array['Whitmore','Bagley','Corfield','Pryce','Hollins','Weaver','Lloyd','Marston',
                             'Tudor','Bickerton','Rowley','Nash','Garbett','Mytton','Icke','Beddoes'];
  i int; e_id uuid; r numeric; recv date; town text; prod text;
  reach int; n_units int; val numeric(10,2);
  d_contact date; d_survey date; d_quoted date; d_closed date;
begin
  perform setseed(0.7714);

  for i in 1..90 loop
    recv    := current_date - (random() * 365)::int;
    town    := towns[1 + floor(random() * array_length(towns,1))::int];
    prod    := products[1 + floor(random() * array_length(products,1))::int];
    n_units := 1 + floor(random() * 14)::int;
    val     := round((n_units * (900 + random() * 1700) + random() * 3000)::numeric, 2);

    r := random();
    if recv > current_date - 45 then
      reach := 1 + floor(r * 4)::int;
    elsif recv > current_date - 110 then
      reach := 2 + floor(r * 5)::int;
    else
      reach := case when r < 0.38 then 7 when r < 0.86 then 8 else 6 end;
    end if;

    d_contact := recv + (1 + floor(random() * 4))::int;
    d_survey  := d_contact + (3 + floor(random() * 12))::int;
    d_quoted  := d_survey + (2 + floor(random() * 9))::int;
    d_closed  := d_quoted + (5 + floor(random() * 40))::int;

    insert into public.enquiries (
      received_on, source, status, customer_name, phone, email,
      site_address_1, site_town, site_postcode, job_description,
      product_type, material, approx_units, property_type, notes
    ) values (
      recv,
      (array['website','website','website','website','phone','phone','phone','phone',
             'referral','repeat','email','trade','walk_in','other'])
        [1 + floor(random() * 14)::int]::public.enquiry_source,
      'new',
      firstnames[1 + floor(random()*array_length(firstnames,1))::int] || ' ' ||
      surnames[1 + floor(random()*array_length(surnames,1))::int],
      '01952 ' || (100000 + floor(random() * 899999))::int,
      'test' || i::text || '@example.com',
      (1 + floor(random() * 80))::int || ' ' ||
        (array['High Street','Church Road','Severn Bank','Mill Lane','The Wharf','Park Terrace'])
        [1 + floor(random() * 6)::int],
      town,
      'TF' || (1 + floor(random() * 9))::int || ' ' || (1 + floor(random() * 9))::int ||
        chr(65 + floor(random()*26)::int) || chr(65 + floor(random()*26)::int),
      prod || ' for a property in ' || town || '.',
      array[prod],
      materials[1 + floor(random()*array_length(materials,1))::int],
      n_units,
      properties[1 + floor(random()*array_length(properties,1))::int],
      '[seed data]'
    ) returning id into e_id;

    if reach >= 2 then
      update public.enquiries set status='contacted', first_contacted_on=d_contact where id=e_id;
    end if;
    if reach >= 3 then
      update public.enquiries set status='survey_booked', survey_date=d_survey,
             survey_slot=(array['am','pm'])[1+floor(random()*2)::int],
             surveyor=surveyors[1+floor(random()*2)::int] where id=e_id;
    end if;
    if reach >= 4 then
      update public.enquiries set status='surveyed', survey_completed_on=d_survey where id=e_id;
    end if;
    if reach >= 5 then
      update public.enquiries set status='quoted', quote_value=val, quote_sent_on=d_quoted,
             quote_expires_on=d_quoted+30,
             probability=(array[20,30,40,50,60,70,80])[1+floor(random()*7)::int],
             target_install_from=d_quoted+40, target_install_to=d_quoted+75 where id=e_id;
    end if;

    if reach = 6 then
      update public.enquiries set status='follow_up', next_action='Chase the quote',
             next_action_on=d_quoted+14 where id=e_id;
    elsif reach = 7 then
      update public.enquiries set status='won', won_on=d_closed where id=e_id;
    elsif reach = 8 then
      update public.enquiries set status='lost', lost_on=d_closed,
             lost_reason=lost_why[1+floor(random()*array_length(lost_why,1))::int] where id=e_id;
    end if;

    if reach between 1 and 6 then
      update public.enquiries
         set next_action    = coalesce(next_action,'Call back'),
             next_action_on = coalesce(next_action_on,
               case when random() < 0.25 then current_date - (1+floor(random()*21))::int
                    else current_date + (1+floor(random()*21))::int end)
       where id = e_id;
    end if;
  end loop;

  -- Backdate the history, or every cycle time reads as zero days.
  update public.enquiry_events ev
     set occurred_at = (
       case ev.to_status
         when 'new'           then e.received_on
         when 'contacted'     then coalesce(e.first_contacted_on, e.received_on + 2)
         when 'survey_booked' then coalesce(e.first_contacted_on, e.received_on) + 2
         when 'surveyed'      then coalesce(e.survey_completed_on, e.survey_date, e.received_on + 12)
         when 'quoted'        then coalesce(e.quote_sent_on, e.received_on + 20)
         when 'follow_up'     then coalesce(e.quote_sent_on, e.received_on + 20) + 14
         when 'won'           then coalesce(e.won_on,  e.received_on + 45)
         when 'lost'          then coalesce(e.lost_on, e.received_on + 45)
         else e.received_on
       end)::timestamptz + interval '10 hours'
    from public.enquiries e
   where e.id = ev.enquiry_id
     and e.notes like '%[seed data]%'
     and ev.occurred_at > now() - interval '1 hour';
end
$seed$;


-- ---------------------------------------------------------------------
--  2. Twenty-six completed jobs across the past year
--
--  The baseline is set deliberately EARLIER than the plan on many of
--  them, because that is what a year of dragged bars looks like and it
--  is the only way the schedule variance chart shows a spread rather
--  than one bar on zero. Estimates are wrong in both directions, so
--  estimate accuracy has something to say.
-- ---------------------------------------------------------------------
do $jobs$
declare
  owner uuid;
  i int; j_id uuid; e record;
  ph jsonb; start_on date; p_start date; p_end date;
  drift int; est numeric(6,1); act numeric(6,1); n_stages int;
  who text; prod text;
  whos text[] := array['Harry','David','Harry','David','Tom'];
begin
  perform setseed(0.3312);
  select coalesce(auth.uid(), (select id from auth.users order by created_at limit 1)) into owner;

  for i in 1..26 loop
    -- Spread completions across the last twelve months.
    start_on := current_date - (30 + (i * 13) + floor(random() * 9)::int);
    n_stages := 5 + floor(random() * 4)::int;
    who      := whos[1 + floor(random() * 5)::int];

    -- Attach a won enquiry that has no job yet, where one exists.
    select * into e
      from public.enquiries
     where status = 'won' and job_id is null and notes like '%[seed data]%'
     order by won_on
     limit 1;

    prod := coalesce(e.product_type[1], (array['Sliding sash windows','Casement windows',
             'Entrance doors','French doors','Bespoke joinery'])[1 + floor(random()*5)::int]);

    ph := pg_temp.build_phases(start_on, n_stages, who);
    p_start := (ph -> 0 ->> 'start')::date;
    p_end   := (ph -> (jsonb_array_length(ph) - 1) ->> 'end')::date;

    -- How far the plan moved from where it was first committed.
    drift := (array[0,0,0,1,2,3,5,7,-2,-1,10,14])[1 + floor(random() * 12)::int];

    est := (n_stages * 2.2 + random() * 3)::numeric(6,1);
    act := greatest((est + (random() * 6 - 2.4))::numeric(6,1), 1.0);

    insert into public.jobs (
      name, client, ref, owner_id, phases,
      baseline_start, baseline_end,
      actual_start, actual_end,
      estimated_days, actual_days, reschedule_count,
      deadline, customer_deadline, product_type, enquiry_id
    ) values (
      coalesce(e.customer_name, 'Test customer ' || i) || ' — ' || prod,
      coalesce(e.customer_name, 'Test customer ' || i),
      'TEST-' || lpad(i::text, 3, '0'),
      owner,
      ph,
      p_start - drift, p_end - drift,
      pg_temp.next_wd(p_start + (floor(random() * 3))::int),
      pg_temp.next_wd(p_end + (array[-2,-1,0,0,0,1,2,4,6,9])[1 + floor(random()*10)::int]),
      est, act,
      case when drift = 0 then 0 else 1 + floor(random() * 3)::int end,
      p_end + 3,
      p_end + (array[-1,0,0,2,3,5])[1 + floor(random()*6)::int],
      array[prod],
      e.id
    ) returning id into j_id;

    if e.id is not null then
      update public.enquiries set job_id = j_id where id = e.id;
    end if;
  end loop;
end
$jobs$;


-- ---------------------------------------------------------------------
--  3. Ten jobs live on the board now
--
--  Staggered so they overlap the way real work does, which is what puts
--  committed days into the capacity chart and produces a week or two
--  running over. Two are already under way; none has finished.
-- ---------------------------------------------------------------------
do $live$
declare
  owner uuid;
  i int; j_id uuid; e record;
  ph jsonb; start_on date; p_start date; p_end date;
  n_stages int; who text; prod text;
  whos text[] := array['Harry','David','Harry','David','Tom'];
begin
  perform setseed(0.5091);
  select coalesce(auth.uid(), (select id from auth.users order by created_at limit 1)) into owner;

  for i in 1..10 loop
    -- Two started a fortnight ago, the rest run out into the next weeks.
    start_on := current_date + ((i - 3) * 6) + floor(random() * 4)::int;
    n_stages := 5 + floor(random() * 4)::int;
    who      := whos[1 + floor(random() * 5)::int];

    select * into e
      from public.enquiries
     where status = 'won' and job_id is null and notes like '%[seed data]%'
     order by won_on desc
     limit 1;

    prod := coalesce(e.product_type[1], (array['Sliding sash windows','Casement windows',
             'Entrance doors','French doors','Bespoke joinery'])[1 + floor(random()*5)::int]);

    ph := pg_temp.build_phases(start_on, n_stages, who);
    p_start := (ph -> 0 ->> 'start')::date;
    p_end   := (ph -> (jsonb_array_length(ph) - 1) ->> 'end')::date;

    insert into public.jobs (
      name, client, ref, owner_id, phases,
      actual_start, estimated_days, reschedule_count,
      deadline, customer_deadline, product_type, enquiry_id
    ) values (
      coalesce(e.customer_name, 'Live customer ' || i) || ' — ' || prod,
      coalesce(e.customer_name, 'Live customer ' || i),
      'TEST-L' || lpad(i::text, 2, '0'),
      owner,
      ph,
      case when p_start < current_date then p_start else null end,
      (n_stages * 2.2 + random() * 3)::numeric(6,1),
      case when random() < 0.3 then 1 else 0 end,
      p_end + 5,
      p_end + (array[2,4,5,7,10])[1 + floor(random()*5)::int],
      array[prod],
      e.id
    ) returning id into j_id;

    if e.id is not null then
      update public.enquiries set job_id = j_id where id = e.id;
    end if;
  end loop;
end
$live$;


-- ---------------------------------------------------------------------
--  4. Rebuild the summary and report what landed
-- ---------------------------------------------------------------------
select public.refresh_dashboard();

select 'enquiries'          as thing, count(*) as n from public.enquiries where notes like '%[seed data]%'
union all select 'jobs, total',       count(*) from public.jobs where ref like 'TEST-%'
union all select 'jobs, live now',    count(*) from public.jobs where ref like 'TEST-L%'
union all select 'jobs, completed',   count(*) from public.jobs where ref like 'TEST-%' and actual_end is not null
union all select 'enquiries linked to a job', count(*) from public.enquiries where job_id is not null
union all select 'weeks over capacity', count(*) from public.v_weekly_capacity where over_capacity
union all select 'enquiry events',     count(*) from public.enquiry_events
union all select 'job events',         count(*) from public.job_events;
