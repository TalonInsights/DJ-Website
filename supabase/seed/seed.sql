-- =====================================================================
--  Seed — the full test dataset
--
--  Replaces seed/enquiries.sql and seed/jobs.sql, both of which cut
--  corners: half the columns were never populated, `on_hold` was never
--  reached, every stage of a job had the same person on it, and the
--  schedule history was one row per job because baselines and reschedule
--  counts were written in directly instead of being earned.
--
--  WHAT "PROPERLY" MEANS HERE
--  --------------------------
--  * Every column on `enquiries` carries plausible data, including the
--    ones the board does not show yet: contact names, second address
--    lines, separate billing addresses, access notes, building-regs
--    flags, source detail, survey reschedules, quote expiry and
--    customer deadlines.
--  * Every status is reached, `on_hold` and `follow_up` included, and
--    some enquiries move backwards or stall the way real ones do.
--  * History is EARNED, never asserted. A job's baseline is set by the
--    trigger from its first plan, and the drift comes from really
--    updating the plan afterwards, so reschedule_count and job_events
--    are what the triggers actually recorded. That also means this seed
--    exercises the triggers rather than working around them.
--  * Stages carry different people, because one name across a whole job
--    is not how a workshop runs.
--  * Some jobs have no enquiry behind them, which is the repeat and
--    phone work the revenue figures cannot see. That hole is real and
--    the test data should show it rather than hide it.
--  * Capacity varies by week: summer shutdown, Christmas, a fortnight
--    down to one bench, and a couple of weeks with a hired hand.
--
--  It clears its own previous run first, so it is safe to re-run.
--
--  TEARDOWN, two commands:
--     delete from public.jobs       where ref like 'TEST-%';
--     delete from public.enquiries  where notes like '%[seed data]%';
--
--  Deterministic: setseed() means re-running gives identical data.
--  Never load this into production.
-- =====================================================================


-- ---------------------------------------------------------------------
--  0. Helpers, and a clean slate
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

-- Lay the stages consecutively across working days, with a named person
-- on each. `people` is picked from per stage, not per job.
create or replace function pg_temp.phases(start_on date, n_stages int, people text[])
returns jsonb language plpgsql as $$
declare
  stages text[] := array['timber','assembly','sanding','hardware','prep','spray','glazing','dispatch'];
  durs   int[]  := array[3,5,2,2,2,3,2,1];
  ph jsonb := '[]'::jsonb;
  cur date := pg_temp.next_wd(start_on);
  s date; e date; k int;
begin
  for k in 1..greatest(least(n_stages, 8), 1) loop
    s := pg_temp.next_wd(cur);
    e := pg_temp.add_wd(s, durs[k] - 1);
    ph := ph || jsonb_build_array(jsonb_build_object(
      'key', stages[k], 'start', s::text, 'end', e::text,
      'who', people[1 + ((k - 1) % array_length(people, 1))]));
    cur := pg_temp.add_wd(e, 1);
  end loop;
  return ph;
end $$;

-- Shift every stage of a plan by n calendar days, which is what dragging
-- a bar on the board does.
create or replace function pg_temp.shift(ph jsonb, n int)
returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'key',   p ->> 'key',
           'start', ((p ->> 'start')::date + n)::text,
           'end',   ((p ->> 'end')::date   + n)::text,
           'who',   p ->> 'who')), '[]'::jsonb)
    from jsonb_array_elements(ph) as p;
$$;

delete from public.jobs      where ref like 'TEST-%';
delete from public.enquiries where notes like '%[seed data]%';


-- ---------------------------------------------------------------------
--  1. Capacity, two years of it
--
--  Not a flat fifteen. A workshop's week varies, and a capacity chart
--  against a constant is a chart with nothing to say.
-- ---------------------------------------------------------------------
delete from public.capacity_weeks;

insert into public.capacity_weeks (week_start, available_days, note)
select w::date,
       case
         when extract(month from w) = 8  and extract(day from w) <= 14 then 5.0
         when extract(month from w) = 12 and extract(day from w) >= 20 then 0.0
         when extract(month from w) = 1  and extract(day from w) <= 4  then 5.0
         when extract(month from w) in (4, 5) and extract(day from w) between 8 and 21 then 20.0
         when extract(week from w) % 17 = 0 then 10.0
         else 15.0
       end,
       case
         when extract(month from w) = 8  and extract(day from w) <= 14 then 'Summer shutdown, skeleton crew'
         when extract(month from w) = 12 and extract(day from w) >= 20 then 'Christmas close'
         when extract(month from w) = 1  and extract(day from w) <= 4  then 'Back gradually after Christmas'
         when extract(month from w) in (4, 5) and extract(day from w) between 8 and 21 then 'Extra pair of hands in'
         when extract(week from w) % 17 = 0 then 'One bench down'
         else null
       end
  from generate_series(date_trunc('week', current_date - interval '24 months'),
                       date_trunc('week', current_date + interval '12 months'),
                       interval '1 week') as w
on conflict (week_start) do update
  set available_days = excluded.available_days, note = excluded.note;


-- ---------------------------------------------------------------------
--  2. Enquiries — 150 across two years, every column populated
-- ---------------------------------------------------------------------
do $enq$
declare
  towns      text[] := array['Ironbridge','Shrewsbury','Much Wenlock','Telford','Broseley',
                             'Coalbrookdale','Bridgnorth','Newport','Albrighton','Shifnal',
                             'Wellington','Church Stretton','Jackfield','Madeley'];
  streets    text[] := array['High Street','Church Road','Severn Bank','Mill Lane','The Wharf',
                             'Park Terrace','Lincoln Hill','Coalport Road','Waterloo Street','Buildwas Lane'];
  addr2      text[] := array[null,null,null,'The Old Bakehouse','Flat 2','Rear of the Green','The Coach House'];
  products   text[] := array['Sliding sash windows','Casement windows','Entrance doors',
                             'French doors','Bi-fold doors','Bespoke joinery','Staircase'];
  materials  text[] := array['Accoya','Accoya','Oak','Sapele','Idigbo','Redwood'];
  properties text[] := array['Listed building','In a conservation area','Period property, not listed',
                             'Modern property','Commercial or trade project','Not sure'];
  surveyors  text[] := array['Harry','David'];
  lost_why   text[] := array['Price','Went elsewhere','Project postponed','No response',
                             'Outside our area','Timescale too long'];
  lost_whom  text[] := array['Local competitor','uPVC installer','National supplier',
                             'Builder doing it themselves',null,null];
  access     text[] := array[null,null,'Narrow access, no room for a van at the front',
                             'Scaffold already up until the end of the month',
                             'Parking on the street only, permit needed',
                             'Rear access through the garden, gate is 900mm',
                             'First floor, over a conservatory'];
  src_detail text[] := array[null,null,'Google search','Found us on the map','Recommended by a neighbour',
                             'Used us before','Passed the workshop','Architect referral','Facebook'];
  firstnames text[] := array['Margaret','Peter','Sarah','John','Elizabeth','David','Susan','Andrew',
                             'Catherine','Michael','Helen','Richard','Anne','Thomas','Ruth','Gerald',
                             'Joan','Stephen','Patricia','Alan'];
  surnames   text[] := array['Whitmore','Bagley','Corfield','Pryce','Hollins','Weaver','Lloyd','Marston',
                             'Tudor','Bickerton','Rowley','Nash','Garbett','Mytton','Icke','Beddoes',
                             'Onions','Gough','Childe','Pountney'];
  actions    text[] := array['Call back about the survey','Chase the quote','Send the glass options',
                             'Confirm the ironmongery finish','Check whether consent came through',
                             'Post the sample','Ring after the holidays','Waiting on their builder'];

  i int; e_id uuid; r numeric; recv date; town text; prod text; prod2 text;
  reach int; n_units int; val numeric(10,2); who uuid;
  d_contact date; d_survey date; d_surveyed date; d_quoted date; d_closed date;
  n_resurvey int; is_listed boolean;
begin
  perform setseed(0.4207);
  select id into who from auth.users order by created_at limit 1;

  for i in 1..150 loop
    -- Two years, weighted towards the recent half so the last twelve
    -- months have denominators worth computing a rate from.
    recv := current_date - (case when random() < 0.62
                                 then (random() * 365)::int
                                 else (365 + random() * 365)::int end);

    town    := towns[1 + floor(random() * array_length(towns,1))::int];
    prod    := products[1 + floor(random() * array_length(products,1))::int];
    prod2   := case when random() < 0.22
                    then products[1 + floor(random() * array_length(products,1))::int] end;
    n_units := 1 + floor(random() * 14)::int;
    val     := round((n_units * (900 + random() * 1700) + random() * 3000)::numeric, 2);

    is_listed  := random() < 0.34;
    n_resurvey := case when random() < 0.14 then 1 + floor(random() * 2)::int else 0 end;

    r := random();
    if recv > current_date - 40 then
      reach := 1 + floor(r * 4)::int;                   -- still early
    elsif recv > current_date - 110 then
      reach := 2 + floor(r * 5)::int;
    else
      reach := case when r < 0.36 then 7                -- won
                    when r < 0.84 then 8                -- lost
                    when r < 0.93 then 6                -- quoted, gone quiet
                    else 9 end;                          -- on hold
    end if;

    d_contact  := recv + (1 + floor(random() * 4))::int;
    d_survey   := d_contact + (3 + floor(random() * 12))::int + (n_resurvey * 9);
    d_surveyed := d_survey;
    d_quoted   := d_surveyed + (2 + floor(random() * 9))::int;
    d_closed   := d_quoted + (5 + floor(random() * 40))::int;

    insert into public.enquiries (
      received_on, source, source_detail, status,
      customer_name, contact_name, phone, email,
      site_address_1, site_address_2, site_town, site_postcode,
      billing_same, billing_address_1, billing_town, billing_postcode,
      job_description, product_type, material, approx_units,
      property_type, access_notes, building_regs_applicable,
      customer_deadline, created_by, notes
    ) values (
      recv,
      (array['website','website','website','website','website','phone','phone','phone','phone',
             'referral','referral','repeat','email','trade','walk_in','other'])
        [1 + floor(random() * 16)::int]::public.enquiry_source,
      src_detail[1 + floor(random() * array_length(src_detail,1))::int],
      'new',
      firstnames[1 + floor(random()*array_length(firstnames,1))::int] || ' ' ||
      surnames[1 + floor(random()*array_length(surnames,1))::int],
      case when random() < 0.28
           then firstnames[1 + floor(random()*array_length(firstnames,1))::int] || ' ' ||
                surnames[1 + floor(random()*array_length(surnames,1))::int] end,
      '01952 ' || (100000 + floor(random() * 899999))::int,
      lower(surnames[1 + floor(random()*array_length(surnames,1))::int]) || i::text || '@example.com',
      (1 + floor(random() * 90))::int || ' ' || streets[1 + floor(random()*array_length(streets,1))::int],
      addr2[1 + floor(random() * array_length(addr2,1))::int],
      town,
      'TF' || (1 + floor(random() * 9))::int || ' ' || (1 + floor(random() * 9))::int ||
        chr(65 + floor(random()*26)::int) || chr(65 + floor(random()*26)::int),
      random() >= 0.18,
      case when random() < 0.18 then (1 + floor(random()*60))::int || ' ' ||
           streets[1 + floor(random()*array_length(streets,1))::int] end,
      case when random() < 0.18 then towns[1 + floor(random()*array_length(towns,1))::int] end,
      case when random() < 0.18 then 'SY' || (1+floor(random()*9))::int || ' ' ||
           (1+floor(random()*9))::int || chr(65+floor(random()*26)::int) || chr(65+floor(random()*26)::int) end,
      n_units || ' ' || lower(prod) || ' for a ' ||
        (array['cottage','farmhouse','terrace','hall','mill conversion','townhouse','former chapel'])
        [1 + floor(random() * 7)::int] || ' in ' || town ||
        case when is_listed then '. Grade II listed, so it needs to match the existing exactly.'
             else '. Like for like on the existing openings.' end,
      case when prod2 is not null and prod2 <> prod then array[prod, prod2] else array[prod] end,
      materials[1 + floor(random()*array_length(materials,1))::int],
      n_units,
      case when is_listed then 'Listed building'
           else properties[1 + floor(random()*array_length(properties,1))::int] end,
      access[1 + floor(random() * array_length(access,1))::int],
      case when random() < 0.55 then random() < 0.35 end,
      case when random() < 0.3 then recv + 120 + floor(random()*90)::int end,
      who,
      case when random() < 0.4
           then (array['Wants it done before the winter.','Neighbour had the same done last year.',
                       'Sensitive about matching the glazing bars.','Budget is tight, said so up front.',
                       'Architect is involved.','No rush, planning a full renovation.'])
                [1 + floor(random()*6)::int] || ' [seed data]'
           else '[seed data]' end
    ) returning id into e_id;

    -- ---- walk the pipeline with real updates, so every transition is
    -- ---- checked by the rules trigger and logged by the history one.
    if reach >= 2 then
      update public.enquiries
         set status = 'contacted', first_contacted_on = d_contact
       where id = e_id;
    end if;

    if reach >= 3 then
      update public.enquiries
         set status = 'survey_booked',
             survey_date = d_survey,
             survey_slot = (array['am','pm'])[1 + floor(random()*2)::int],
             surveyor    = surveyors[1 + floor(random()*2)::int],
             survey_reschedule_count = n_resurvey
       where id = e_id;
    end if;

    if reach >= 4 then
      update public.enquiries set status = 'surveyed', survey_completed_on = d_surveyed where id = e_id;
    end if;

    if reach >= 5 then
      update public.enquiries
         set status = 'quoted',
             quote_value      = val,
             quote_sent_on    = d_quoted,
             quote_expires_on = d_quoted + 30,
             probability      = (array[20,30,40,50,60,70,80,90])[1 + floor(random()*8)::int],
             target_install_from = d_quoted + 35 + floor(random()*20)::int,
             target_install_to   = d_quoted + 70 + floor(random()*30)::int
       where id = e_id;
    end if;

    -- A quote that goes quiet gets chased, and some of those come back
    -- and are won, which is what makes the history worth keeping.
    if reach in (6, 7, 8) and random() < 0.45 then
      update public.enquiries
         set status = 'follow_up',
             next_action = actions[1 + floor(random()*array_length(actions,1))::int],
             next_action_on = d_quoted + 14
       where id = e_id;
    end if;

    if reach = 6 then
      update public.enquiries
         set status = 'follow_up',
             next_action = actions[1 + floor(random()*array_length(actions,1))::int],
             next_action_on = d_quoted + 14
       where id = e_id;

    elsif reach = 7 then
      update public.enquiries set status = 'won', won_on = d_closed where id = e_id;

    elsif reach = 8 then
      update public.enquiries
         set status = 'lost', lost_on = d_closed,
             lost_reason = lost_why[1 + floor(random()*array_length(lost_why,1))::int],
             lost_to     = lost_whom[1 + floor(random()*array_length(lost_whom,1))::int]
       where id = e_id;

    elsif reach = 9 then
      update public.enquiries
         set status = 'on_hold',
             next_action = 'Waiting on listed building consent',
             next_action_on = current_date + 20 + floor(random()*40)::int
       where id = e_id;
    end if;

    -- Anything still live needs a next action, or the overdue strip has
    -- nothing to surface. A quarter are deliberately late, because that
    -- is the case the board exists to catch.
    if reach between 1 and 6 then
      update public.enquiries
         set next_action    = coalesce(next_action, actions[1 + floor(random()*array_length(actions,1))::int]),
             next_action_on = coalesce(next_action_on,
               case when random() < 0.25 then current_date - (1 + floor(random()*24))::int
                    else current_date + (1 + floor(random()*21))::int end)
       where id = e_id;
    end if;
  end loop;

  -- ---- backdate the history, or every cycle time reads as zero days
  update public.enquiry_events ev
     set occurred_at = (
       case ev.to_status
         when 'new'           then e.received_on
         when 'contacted'     then coalesce(e.first_contacted_on, e.received_on + 2)
         when 'survey_booked' then coalesce(e.first_contacted_on, e.received_on) + 2
         when 'surveyed'      then coalesce(e.survey_completed_on, e.survey_date, e.received_on + 12)
         when 'quoted'        then coalesce(e.quote_sent_on, e.received_on + 20)
         when 'follow_up'     then coalesce(e.quote_sent_on, e.received_on + 20) + 14
         when 'on_hold'       then coalesce(e.quote_sent_on, e.received_on + 20) + 7
         when 'won'           then coalesce(e.won_on,  e.received_on + 45)
         when 'lost'          then coalesce(e.lost_on, e.received_on + 45)
         else e.received_on
       end)::timestamptz + interval '10 hours'
        + (random() * interval '6 hours'),
         actor = who
    from public.enquiries e
   where e.id = ev.enquiry_id
     and e.notes like '%[seed data]%';
end
$enq$;


-- ---------------------------------------------------------------------
--  3. Jobs
--
--  Built the way a job really accumulates: an original plan, then the
--  plan moves, then work starts, then it finishes. The baseline and the
--  reschedule count are whatever the triggers made of that, never
--  written in directly, so this section is also a test of them.
-- ---------------------------------------------------------------------
do $jobs$
declare
  owner uuid;
  crew  text[] := array['Harry','David','Tom','Harry','David'];
  i int; j_id uuid;
  e public.enquiries%rowtype;   -- %rowtype, never `record`: see the null assignment below
  ph jsonb; start_on date; p_start date; p_end date;
  n_stages int; drift int; est numeric(6,1); act numeric(6,1);
  prod text; people text[]; started date; finished date;
  n_completed int := 30;
  n_live      int := 10;
  n_noenq     int := 0;
begin
  perform setseed(0.3312);
  select id into owner from auth.users order by created_at limit 1;

  -- ---- completed, across the past fourteen months -------------------
  for i in 1..n_completed loop
    start_on := current_date - (25 + (i * 14) + floor(random() * 8)::int);
    n_stages := 5 + floor(random() * 4)::int;
    people   := array[crew[1 + floor(random()*5)::int],
                      crew[1 + floor(random()*5)::int],
                      crew[1 + floor(random()*5)::int]];

    -- One in six is work that never was an enquiry: repeat custom or a
    -- phone call typed straight onto the board. These are the jobs the
    -- revenue figures cannot see, and the test data should show that.
    -- A typed null row, not a bare null. Assigning null to a plain
    -- `record` leaves it with no tuple structure at all, and the next
    -- e.field raises "record is not assigned yet".
    if i % 6 = 0 then
      e := null::public.enquiries;
      n_noenq := n_noenq + 1;
    else
      select * into e from public.enquiries
       where status = 'won' and job_id is null and notes like '%[seed data]%'
       order by won_on limit 1;
      if not found then e := null::public.enquiries; end if;
    end if;

    prod := coalesce(e.product_type[1], (array['Sliding sash windows','Casement windows',
             'Entrance doors','French doors','Bespoke joinery'])[1 + floor(random()*5)::int]);

    ph := pg_temp.phases(start_on, n_stages, people);
    est := round((n_stages * 2.2 + random() * 3)::numeric, 1);

    insert into public.jobs (name, client, ref, owner_id, phases,
                             estimated_days, deadline, customer_deadline,
                             product_type, enquiry_id)
    values (
      coalesce(e.customer_name, 'Repeat customer ' || i) || ' — ' || prod,
      coalesce(e.customer_name, 'Repeat customer ' || i),
      'TEST-' || lpad(i::text, 3, '0'),
      owner, ph, est,
      ((ph -> (jsonb_array_length(ph)-1) ->> 'end')::date) + 3,
      ((ph -> (jsonb_array_length(ph)-1) ->> 'end')::date)
        + (array[-1,0,0,2,3,5,8])[1 + floor(random()*7)::int],
      array[prod], e.id
    ) returning id into j_id;

    if e.id is not null then
      update public.enquiries set job_id = j_id where id = e.id;
    end if;

    -- The plan moves. Each of these is a drag on the board, and each one
    -- earns a reschedule and a row in the history.
    drift := (array[0,0,0,3,5,7,10,14,-2,21])[1 + floor(random()*10)::int];
    if drift <> 0 then
      update public.jobs set phases = pg_temp.shift(phases, drift) where id = j_id;
      if random() < 0.4 then
        update public.jobs set phases = pg_temp.shift(phases, 7) where id = j_id;
      end if;
    end if;

    select planned_start, planned_end into p_start, p_end from public.jobs where id = j_id;

    started  := pg_temp.next_wd(p_start + (array[-1,0,0,1,2])[1 + floor(random()*5)::int]);
    finished := pg_temp.next_wd(p_end + (array[-3,-1,0,0,0,1,2,4,7,11])[1 + floor(random()*10)::int]);
    act      := greatest(round((est + (random() * 6 - 2.4))::numeric, 1), 1.0);

    update public.jobs set actual_start = started where id = j_id;
    update public.jobs set actual_end = finished, actual_days = act where id = j_id;
  end loop;

  -- ---- ten live on the board now ------------------------------------
  for i in 1..n_live loop
    -- Nine days apart, not six. At six the ten live jobs overlapped four
    -- deep against a fifteen job-day week, so the chart was brass from
    -- end to end and the over-capacity signal stopped meaning anything.
    start_on := current_date + ((i - 3) * 9) + floor(random() * 5)::int;
    n_stages := 5 + floor(random() * 4)::int;
    people   := array[crew[1 + floor(random()*5)::int],
                      crew[1 + floor(random()*5)::int],
                      crew[1 + floor(random()*5)::int]];

    select * into e from public.enquiries
     where status = 'won' and job_id is null and notes like '%[seed data]%'
     order by won_on desc limit 1;
    if not found then e := null::public.enquiries; end if;

    prod := coalesce(e.product_type[1], (array['Sliding sash windows','Casement windows',
             'Entrance doors','French doors','Bespoke joinery'])[1 + floor(random()*5)::int]);

    ph := pg_temp.phases(start_on, n_stages, people);

    insert into public.jobs (name, client, ref, owner_id, phases,
                             estimated_days, deadline, customer_deadline,
                             product_type, enquiry_id)
    values (
      coalesce(e.customer_name, 'Live customer ' || i) || ' — ' || prod,
      coalesce(e.customer_name, 'Live customer ' || i),
      'TEST-L' || lpad(i::text, 2, '0'),
      owner, ph,
      round((n_stages * 2.2 + random() * 3)::numeric, 1),
      ((ph -> (jsonb_array_length(ph)-1) ->> 'end')::date) + 5,
      ((ph -> (jsonb_array_length(ph)-1) ->> 'end')::date)
        + (array[2,4,5,7,10])[1 + floor(random()*5)::int],
      array[prod], e.id
    ) returning id into j_id;

    if e.id is not null then
      update public.enquiries set job_id = j_id where id = e.id;
    end if;

    -- A third of live jobs have already slipped once.
    if random() < 0.33 then
      update public.jobs set phases = pg_temp.shift(phases, 7) where id = j_id;
    end if;

    -- Anything that should already have started, has.
    select planned_start into p_start from public.jobs where id = j_id;
    if p_start < current_date then
      update public.jobs set actual_start = pg_temp.next_wd(p_start) where id = j_id;
    end if;
  end loop;

  -- ---- backdate the schedule history to match the work --------------
  update public.job_events ev
     set occurred_at = (
       case ev.kind
         when 'created'     then coalesce(j.baseline_start, j.planned_start) - 21
         when 'rescheduled' then coalesce(ev.from_start, j.baseline_start, j.planned_start) - 7
         when 'started'     then coalesce(j.actual_start, j.planned_start)
         when 'completed'   then coalesce(j.actual_end, j.planned_end)
         else coalesce(j.planned_start, current_date)
       end)::timestamptz + interval '9 hours',
         actor = owner
    from public.jobs j
   where j.id = ev.job_id and j.ref like 'TEST-%';

  raise notice 'jobs: % completed, % live, % with no enquiry behind them',
    n_completed, n_live, n_noenq;
end
$jobs$;


-- ---------------------------------------------------------------------
--  4. Rebuild the summary and report exactly what landed
-- ---------------------------------------------------------------------
select public.refresh_dashboard();

select thing, n from (
  select 1 as ord, 'enquiries'                as thing, count(*) as n from public.enquiries where notes like '%[seed data]%'
  union all select 2, '  of those, still open',   count(*) from public.v_pipeline_open
  union all select 3, '  of those, overdue',      count(*) from public.v_overdue_actions
  union all select 4, '  statuses reached',       count(distinct status) from public.enquiries where notes like '%[seed data]%'
  union all select 5, '  with a second product',  count(*) from public.enquiries where notes like '%[seed data]%' and cardinality(product_type) > 1
  union all select 6, '  with separate billing',  count(*) from public.enquiries where notes like '%[seed data]%' and billing_same = false
  union all select 7, '  with access notes',      count(*) from public.enquiries where notes like '%[seed data]%' and access_notes is not null
  union all select 8, '  survey rescheduled',     count(*) from public.enquiries where notes like '%[seed data]%' and survey_reschedule_count > 0
  union all select 9, 'enquiry events',           count(*) from public.enquiry_events
  union all select 10,'jobs, total',              count(*) from public.jobs where ref like 'TEST-%'
  union all select 11,'  live now',               count(*) from public.jobs where ref like 'TEST-L%'
  union all select 12,'  completed',              count(*) from public.jobs where ref like 'TEST-%' and actual_end is not null
  union all select 13,'  rescheduled at least once', count(*) from public.jobs where ref like 'TEST-%' and reschedule_count > 0
  union all select 14,'  with no enquiry behind them', count(*) from public.jobs where ref like 'TEST-%' and enquiry_id is null
  union all select 15,'  distinct people on stages', count(distinct p ->> 'who')
              from public.jobs j, jsonb_array_elements(j.phases) p where j.ref like 'TEST-%'
  union all select 16,'job events',                count(*) from public.job_events
  union all select 17,'  of those, reschedules',   count(*) from public.job_events where kind = 'rescheduled'
  union all select 18,'capacity weeks set',        count(*) from public.capacity_weeks
  union all select 19,'  not the default 15 days', count(*) from public.capacity_weeks where available_days <> 15
  union all select 20,'weeks over capacity now',   count(*) from public.v_weekly_capacity where over_capacity
  union all select 21,'weeks over if pipeline lands', count(*) from public.v_weekly_capacity where over_when_pipeline_lands
) s order by ord;
