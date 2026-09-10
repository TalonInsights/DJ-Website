-- =====================================================================
--  Seed — 60 enquiries across 18 months
--
--  Analytics work is untestable without this. Every row is invented, but
--  the shape is not: sources are weighted the way this firm's actually
--  are (45% website form, ~45% phone, the rest referral and repeat),
--  values sit in the range heritage joinery really quotes, and the funnel
--  drops off at each stage rather than marching everyone to 'won'.
--
--  The status walk is done with real UPDATEs, so the history trigger
--  fires for every transition and enquiry_events ends up populated the
--  way it would be in use. The event timestamps are then backdated to
--  match, otherwise every cycle time would read as zero days.
--
--  Deterministic: setseed() means re-running gives identical data.
--
--  TEARDOWN, one command:
--     delete from public.enquiries where notes like '%[seed data]%';
--
--  Never load this into production.
-- =====================================================================

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
  lost_whom  text[] := array['Local competitor','uPVC installer','National supplier',NULL,NULL];
  firstnames text[] := array['Margaret','Peter','Sarah','John','Elizabeth','David','Susan',
                             'Andrew','Catherine','Michael','Helen','Richard','Anne','Thomas'];
  surnames   text[] := array['Whitmore','Bagley','Corfield','Pryce','Hollins','Weaver','Lloyd',
                             'Marston','Tudor','Bickerton','Rowley','Nash','Garbett','Mytton'];

  i           int;
  e_id        uuid;
  r           numeric;
  recv        date;
  town        text;
  prod        text;
  reach       int;      -- how far down the funnel this one got
  n_units     int;
  val         numeric(10,2);
  d_contact   date;
  d_survey    date;
  d_surveyed  date;
  d_quoted    date;
  d_closed    date;
  seeded      int := 0;
begin
  perform setseed(0.4207);

  for i in 1..60 loop
    -- Spread across the last 18 months, denser recently, the way a
    -- growing enquiry book actually looks.
    recv  := current_date - (random() * 545)::int;
    town  := towns[1 + floor(random() * array_length(towns, 1))::int];
    prod  := products[1 + floor(random() * array_length(products, 1))::int];
    n_units := 1 + floor(random() * 14)::int;

    -- Value scales with units, with real spread on top.
    val := round((n_units * (900 + random() * 1700) + random() * 3000)::numeric, 2);

    -- Funnel depth. Older enquiries have had time to resolve; recent
    -- ones are still in flight, which is what makes the open pipeline
    -- look believable.
    r := random();
    if recv > current_date - 45 then
      reach := 1 + floor(r * 4)::int;                    -- new .. surveyed
    elsif recv > current_date - 120 then
      reach := 2 + floor(r * 5)::int;
    else
      reach := case when r < 0.34 then 7 when r < 0.88 then 8 else 6 end;  -- won / lost / stalled at quoted
    end if;

    d_contact  := recv + (1 + floor(random() * 4))::int;
    d_survey   := d_contact + (3 + floor(random() * 12))::int;
    d_surveyed := d_survey;
    d_quoted   := d_surveyed + (2 + floor(random() * 9))::int;
    d_closed   := d_quoted + (5 + floor(random() * 40))::int;

    insert into public.enquiries (
      received_on, source, status, customer_name, contact_name, phone, email,
      site_address_1, site_town, site_postcode, billing_same,
      job_description, product_type, material, approx_units, property_type,
      building_regs_applicable, notes
    ) values (
      recv,
      (array['website','website','website','website','phone','phone','phone','phone',
             'referral','repeat','email','trade','walk_in','other'])
        [1 + floor(random() * 14)::int]::public.enquiry_source,
      'new',
      firstnames[1 + floor(random() * array_length(firstnames,1))::int] || ' ' ||
      surnames[1 + floor(random() * array_length(surnames,1))::int],
      null,
      '01952 ' || (100000 + floor(random() * 899999))::int,
      lower(surnames[1 + floor(random() * array_length(surnames,1))::int]) || i::text || '@example.com',
      (1 + floor(random() * 80))::int || ' ' ||
        (array['High Street','Church Road','Severn Bank','Mill Lane','The Wharf','Park Terrace'])
        [1 + floor(random() * 6)::int],
      town,
      'TF' || (1 + floor(random() * 9))::int || ' ' || (1 + floor(random() * 9))::int ||
        chr(65 + floor(random() * 26)::int) || chr(65 + floor(random() * 26)::int),
      true,
      prod || ' for a ' ||
        (array['cottage','farmhouse','terrace','hall','mill conversion','townhouse'])
        [1 + floor(random() * 6)::int] || ' in ' || town || '.',
      array[prod],
      materials[1 + floor(random() * array_length(materials,1))::int],
      n_units,
      properties[1 + floor(random() * array_length(properties,1))::int],
      random() < 0.3,
      '[seed data]'
    )
    returning id into e_id;

    seeded := seeded + 1;

    -- Walk the status forward with real updates so the history trigger
    -- writes one event per transition, exactly as it would in use.
    if reach >= 2 then
      update public.enquiries
         set status = 'contacted', first_contacted_on = d_contact
       where id = e_id;
    end if;

    if reach >= 3 then
      update public.enquiries
         set status = 'survey_booked',
             survey_date = d_survey,
             survey_slot = (array['am','pm'])[1 + floor(random() * 2)::int],
             surveyor    = surveyors[1 + floor(random() * 2)::int],
             survey_reschedule_count = case when random() < 0.15 then 1 else 0 end
       where id = e_id;
    end if;

    if reach >= 4 then
      update public.enquiries
         set status = 'surveyed', survey_completed_on = d_surveyed
       where id = e_id;
    end if;

    if reach >= 5 then
      update public.enquiries
         set status = 'quoted',
             quote_value      = val,
             quote_sent_on    = d_quoted,
             quote_expires_on = d_quoted + 30,
             probability      = (array[20,30,40,50,60,70,80])[1 + floor(random() * 7)::int],
             target_install_from = d_quoted + 40,
             target_install_to   = d_quoted + 75
       where id = e_id;
    end if;

    -- 6 = quoted and gone quiet, 7 = won, 8 = lost.
    if reach = 6 then
      update public.enquiries
         set status = 'follow_up',
             next_action = 'Chase the quote',
             next_action_on = d_quoted + 14
       where id = e_id;

    elsif reach = 7 then
      update public.enquiries
         set status = 'won', won_on = d_closed
       where id = e_id;

    elsif reach = 8 then
      update public.enquiries
         set status  = 'lost',
             lost_on = d_closed,
             lost_reason = lost_why[1 + floor(random() * array_length(lost_why,1))::int],
             lost_to     = lost_whom[1 + floor(random() * array_length(lost_whom,1))::int]
       where id = e_id;
    end if;

    -- Open enquiries need a next action, or the overdue strip has
    -- nothing to show and the follow-up index goes untested. A quarter
    -- of them are deliberately overdue, because that is the case the
    -- board exists to surface.
    if reach between 1 and 6 then
      update public.enquiries
         set next_action    = coalesce(next_action, 'Call back'),
             next_action_on = coalesce(next_action_on,
                                case when random() < 0.25
                                     then current_date - (1 + floor(random() * 21))::int
                                     else current_date + (1 + floor(random() * 21))::int end)
       where id = e_id;
    end if;
  end loop;

  -- Backdate the history. Without this every transition is timestamped
  -- now() and every cycle-time metric reads zero days.
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
       end
     )::timestamptz + interval '10 hours'
    from public.enquiries e
   where e.id = ev.enquiry_id
     and e.notes like '%[seed data]%';

  raise notice 'seeded % enquiries, % events',
    seeded,
    (select count(*) from public.enquiry_events ev
       join public.enquiries e on e.id = ev.enquiry_id
      where e.notes like '%[seed data]%');
end
$seed$;


-- ---------------------------------------------------------------------
--  Capacity, so the forward-capacity tile has something to divide by.
--  Five working days across three parallel jobs = 15 job-days a week.
--  August and Christmas are cut for holidays.
-- ---------------------------------------------------------------------
insert into public.capacity_weeks (week_start, available_days, note)
select d::date,
       case
         when extract(month from d) = 8  and extract(day from d) <= 14 then 5.0
         when extract(month from d) = 12 and extract(day from d) >= 20 then 0.0
         else 15.0
       end,
       case
         when extract(month from d) = 8  and extract(day from d) <= 14 then 'Summer shutdown, skeleton crew'
         when extract(month from d) = 12 and extract(day from d) >= 20 then 'Christmas close'
         else null
       end
  from generate_series(
         date_trunc('week', current_date - interval '18 months'),
         date_trunc('week', current_date + interval '9 months'),
         interval '1 week') as d
on conflict (week_start) do nothing;
