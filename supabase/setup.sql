-- Shape Sentinel database setup.
-- Run this entire file once in Supabase Dashboard > SQL Editor > New query.
-- Public participants can submit one validated session through the RPC function.
-- They cannot directly read, update, or delete records in any table.

create table if not exists public.participant_summaries (
  participant_id text primary key check (char_length(participant_id) between 1 and 12),
  submission_id uuid not null unique,
  age smallint not null check (age between 18 and 100),
  course text not null check (char_length(course) between 1 and 200),
  gender text not null check (char_length(gender) between 1 and 80),
  condition_order jsonb not null check (pg_catalog.jsonb_typeof(condition_order) = 'array'),
  low_distraction_accuracy_percent numeric(5,2) not null,
  high_distraction_accuracy_percent numeric(5,2) not null,
  low_distraction_average_reaction_time_seconds numeric(8,3),
  high_distraction_average_reaction_time_seconds numeric(8,3),
  prospective_memory_hits smallint not null,
  prospective_memory_misses smallint not null,
  false_alarms smallint not null,
  completed_at timestamptz not null
);

-- Migrate projects created with the earlier text[] version of condition_order.
alter table public.participant_summaries
  alter column condition_order type jsonb
  using pg_catalog.to_jsonb(condition_order);

create unique index if not exists participant_summaries_participant_id_lower_key on public.participant_summaries (lower(participant_id));

create table if not exists public.participant_contacts (
  participant_id text primary key references public.participant_summaries(participant_id) on delete cascade,
  email text not null check (char_length(email) between 3 and 254)
);

create table if not exists public.trial_data (
  participant_id text not null references public.participant_summaries(participant_id) on delete cascade,
  trial_number smallint not null check (trial_number between 1 and 30),
  experimental_condition text not null check (experimental_condition in ('low','high')),
  presented_shape text not null check (presented_shape in ('circle','square','triangle')),
  shape_colour text not null check (shape_colour in ('blue','red','green','gold','purple','teal')),
  shape_colour_hex text not null,
  shape_identification_response text check (shape_identification_response in ('F','J','K')),
  shape_response_accuracy text not null check (shape_response_accuracy in ('correct','incorrect','no response')),
  shape_reaction_time_seconds numeric(8,3) check (shape_reaction_time_seconds between 0 and 1.5),
  is_prospective_memory_target boolean not null,
  key_1_pressed boolean not null,
  prospective_memory_reaction_time_seconds numeric(8,3) check (prospective_memory_reaction_time_seconds between 0 and 1.5),
  prospective_memory_outcome text not null check (prospective_memory_outcome in ('hit','miss','false alarm','not target')),
  primary key (participant_id, experimental_condition, trial_number)
);

alter table public.participant_summaries enable row level security;
alter table public.participant_contacts enable row level security;
alter table public.trial_data enable row level security;

-- Keep all direct table access private, including reads from the public website.
revoke all on table public.participant_summaries, public.participant_contacts, public.trial_data from public, anon, authenticated;
grant usage on schema public to anon;

create or replace function public.submit_experiment_session(payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id text;
  v_submission_id uuid;
  v_existing_id text;
  v_trials jsonb;
  v_low_accuracy numeric(5,2);
  v_high_accuracy numeric(5,2);
  v_low_rt numeric(8,3);
  v_high_rt numeric(8,3);
  v_low_hits smallint;
  v_low_misses smallint;
  v_low_false_alarms smallint;
  v_high_hits smallint;
  v_high_misses smallint;
  v_high_false_alarms smallint;
begin
  if payload is null or pg_catalog.jsonb_typeof(payload) <> 'object'
     or pg_catalog.pg_column_size(payload) > 500000 then
    raise exception using errcode = '22023', message = 'Invalid experiment submission.';
  end if;

  v_id := payload->>'participant_id';
  v_submission_id := (payload->>'submission_id')::uuid;
  v_trials := payload->'trials';
  if v_id is null or v_submission_id is null or char_length(v_id) not between 1 and 12
     or coalesce((payload->>'age')::integer, 0) not between 18 and 100
     or coalesce(payload->>'course','') = '' or char_length(payload->>'course') > 200
     or coalesce(payload->>'gender','') = '' or char_length(payload->>'gender') > 80
     or coalesce(payload->>'email','') !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
     or pg_catalog.jsonb_typeof(v_trials) <> 'array'
     or pg_catalog.jsonb_array_length(v_trials) <> 60 then
    raise exception using errcode = '22023', message = 'Invalid participant details or trial count.';
  end if;

  select participant_id into v_existing_id from public.participant_summaries where submission_id=v_submission_id;
  if found then
    if v_existing_id=v_id then return pg_catalog.jsonb_build_object('saved',true,'participant_id',v_id,'already_saved',true); end if;
    raise exception using errcode='22023',message='Invalid submission ID.';
  end if;
  if exists(select 1 from public.participant_summaries where pg_catalog.lower(participant_id)=pg_catalog.lower(v_id)) then
    raise exception using errcode='23505',message='This participant ID has already been used. Please choose a different ID.';
  end if;

  if (select count(*) from pg_catalog.jsonb_to_recordset(v_trials) as t(experimental_condition text) where t.experimental_condition='low') <> 30
     or (select count(*) from pg_catalog.jsonb_to_recordset(v_trials) as t(experimental_condition text) where t.experimental_condition='high') <> 30
     or (select count(*) from pg_catalog.jsonb_to_recordset(v_trials) as t(experimental_condition text, is_prospective_memory_target boolean) where t.experimental_condition='low' and t.is_prospective_memory_target) <> 6
     or (select count(*) from pg_catalog.jsonb_to_recordset(v_trials) as t(experimental_condition text, is_prospective_memory_target boolean) where t.experimental_condition='high' and t.is_prospective_memory_target) <> 6 then
    raise exception using errcode = '22023', message = 'Each condition must contain 30 trials and 6 prospective memory targets.';
  end if;

  if exists (
    select 1
    from pg_catalog.jsonb_to_recordset(v_trials) as t(
      trial_number integer, experimental_condition text, presented_shape text,
      shape_colour text, shape_colour_hex text, shape_identification_response text,
      shape_response_accuracy text, shape_reaction_time_seconds numeric,
      is_prospective_memory_target boolean, key_1_pressed boolean,
      prospective_memory_reaction_time_seconds numeric, prospective_memory_outcome text
    )
    where t.trial_number not between 1 and 30
      or t.experimental_condition not in ('low','high')
      or t.presented_shape not in ('circle','square','triangle')
      or t.shape_colour not in ('blue','red','green','gold','purple','teal')
      or (t.shape_colour,t.shape_colour_hex) not in (('blue','#4776a8'),('red','#c96957'),('green','#6a8f70'),('gold','#c39b43'),('purple','#8067a8'),('teal','#4e9291'))
      or t.is_prospective_memory_target is distinct from (t.presented_shape='triangle' and t.shape_colour='blue')
      or (t.shape_identification_response is null and (t.shape_response_accuracy <> 'no response' or t.shape_reaction_time_seconds is not null))
      or (t.shape_identification_response is not null and (t.shape_identification_response not in ('F','J','K') or t.shape_reaction_time_seconds is null or t.shape_response_accuracy <> case when t.shape_identification_response=case t.presented_shape when 'circle' then 'F' when 'square' then 'J' else 'K' end then 'correct' else 'incorrect' end))
      or t.key_1_pressed is distinct from (t.prospective_memory_reaction_time_seconds is not null)
      or t.prospective_memory_outcome <> case when t.is_prospective_memory_target then case when t.key_1_pressed then 'hit' else 'miss' end else case when t.key_1_pressed then 'false alarm' else 'not target' end end
      or (t.shape_reaction_time_seconds is not null and t.shape_reaction_time_seconds not between 0 and 1.5)
      or (t.prospective_memory_reaction_time_seconds is not null and t.prospective_memory_reaction_time_seconds not between 0 and 1.5)
  ) then
    raise exception using errcode = '22023', message = 'Trial data failed validation.';
  end if;

  select
    round(100.0 * count(*) filter (where experimental_condition='low' and shape_response_accuracy='correct') / 30, 2),
    round(avg(shape_reaction_time_seconds) filter (where experimental_condition='low'), 3),
    count(*) filter (where experimental_condition='low' and is_prospective_memory_target and prospective_memory_outcome='hit'),
    count(*) filter (where experimental_condition='low' and is_prospective_memory_target and prospective_memory_outcome='miss'),
    count(*) filter (where experimental_condition='low' and prospective_memory_outcome='false alarm'),
    round(100.0 * count(*) filter (where experimental_condition='high' and shape_response_accuracy='correct') / 30, 2),
    round(avg(shape_reaction_time_seconds) filter (where experimental_condition='high'), 3),
    count(*) filter (where experimental_condition='high' and is_prospective_memory_target and prospective_memory_outcome='hit'),
    count(*) filter (where experimental_condition='high' and is_prospective_memory_target and prospective_memory_outcome='miss'),
    count(*) filter (where experimental_condition='high' and prospective_memory_outcome='false alarm')
  into v_low_accuracy,v_low_rt,v_low_hits,v_low_misses,v_low_false_alarms,v_high_accuracy,v_high_rt,v_high_hits,v_high_misses,v_high_false_alarms
  from pg_catalog.jsonb_to_recordset(v_trials) as t(
    experimental_condition text, shape_response_accuracy text, shape_reaction_time_seconds numeric,
    is_prospective_memory_target boolean, prospective_memory_outcome text
  );

  insert into public.participant_summaries (
    participant_id,submission_id,age,course,gender,condition_order,
    low_distraction_accuracy_percent,high_distraction_accuracy_percent,
    low_distraction_average_reaction_time_seconds,high_distraction_average_reaction_time_seconds,
    prospective_memory_hits,prospective_memory_misses,false_alarms,completed_at
  ) values (
    v_id,v_submission_id,(payload->>'age')::smallint,payload->>'course',payload->>'gender',
    payload->'condition_order',
    v_low_accuracy,v_high_accuracy,v_low_rt,v_high_rt,
    v_low_hits+v_high_hits,v_low_misses+v_high_misses,v_low_false_alarms+v_high_false_alarms,
    coalesce((payload->>'completed_at')::timestamptz,pg_catalog.now())
  );

  insert into public.participant_contacts (participant_id,email)
  values (v_id,payload->>'email');

  insert into public.trial_data (
    participant_id,trial_number,experimental_condition,presented_shape,shape_colour,shape_colour_hex,
    shape_identification_response,shape_response_accuracy,shape_reaction_time_seconds,
    is_prospective_memory_target,key_1_pressed,prospective_memory_reaction_time_seconds,prospective_memory_outcome
  )
  select v_id,t.trial_number,t.experimental_condition,t.presented_shape,t.shape_colour,t.shape_colour_hex,
    t.shape_identification_response,t.shape_response_accuracy,t.shape_reaction_time_seconds,
    t.is_prospective_memory_target,t.key_1_pressed,t.prospective_memory_reaction_time_seconds,t.prospective_memory_outcome
  from pg_catalog.jsonb_to_recordset(v_trials) as t(
    trial_number smallint,experimental_condition text,presented_shape text,shape_colour text,shape_colour_hex text,
    shape_identification_response text,shape_response_accuracy text,shape_reaction_time_seconds numeric,
    is_prospective_memory_target boolean,key_1_pressed boolean,prospective_memory_reaction_time_seconds numeric,prospective_memory_outcome text
  );

  return pg_catalog.jsonb_build_object('saved',true,'participant_id',v_id);
end;
$$;

revoke all on function public.submit_experiment_session(jsonb) from public, anon, authenticated;
grant execute on function public.submit_experiment_session(jsonb) to anon;

-- Researcher exports: run these in SQL Editor after collection, then use Download CSV.
-- Participant Summary (includes email only in this requested summary export):
-- select s.participant_id,s.age,s.course,s.gender,c.email,
--   s.low_distraction_accuracy_percent,s.high_distraction_accuracy_percent,
--   s.low_distraction_average_reaction_time_seconds,s.high_distraction_average_reaction_time_seconds,
--   s.prospective_memory_hits,s.prospective_memory_misses,s.false_alarms
-- from public.participant_summaries s
-- join public.participant_contacts c using (participant_id)
-- order by s.completed_at;
--
-- Trial-Level Raw Data (no email/contact details):
-- select participant_id,trial_number,experimental_condition,presented_shape,shape_colour,
--   shape_colour_hex,shape_identification_response,shape_response_accuracy,shape_reaction_time_seconds,
--   is_prospective_memory_target,key_1_pressed,prospective_memory_reaction_time_seconds,prospective_memory_outcome
-- from public.trial_data order by participant_id,experimental_condition,trial_number;
--
-- Private Contact List (keep separate from trial-level research data):
-- select participant_id,email from public.participant_contacts order by participant_id;
