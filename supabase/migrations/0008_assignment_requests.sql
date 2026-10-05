create table assignments (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references profiles(id) on delete cascade,
  requested_interpreter_id uuid not null references interpreters(id),
  current_interpreter_id uuid references interpreters(id),
  language text not null,
  specialty text not null,
  city text,
  state text,
  service_mode text not null check (service_mode in ('remote','in-person')),
  scheduled_for timestamptz not null,
  max_hourly_rate numeric,
  status text not null default 'offered' check (status in ('offered','accepted','cancelled','unfilled')),
  current_response_deadline timestamptz,
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);

create table assignment_offers (
  id uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id) on delete cascade,
  interpreter_id uuid not null references interpreters(id) on delete cascade,
  status text not null default 'offered' check (status in ('offered','accepted','declined','expired')),
  offered_at timestamptz not null default now(),
  response_deadline timestamptz not null,
  responded_at timestamptz,
  unique (assignment_id, interpreter_id)
);

create index assignments_customer_created on assignments (customer_id, created_at desc);
create index assignments_interpreter_deadline on assignments (current_interpreter_id, current_response_deadline) where status = 'offered';
create index assignment_offers_assignment on assignment_offers (assignment_id, status);

alter table assignments enable row level security;
alter table assignment_offers enable row level security;
revoke all on assignments, assignment_offers from anon, authenticated;
grant select on assignments to authenticated;

create policy "assignment participants can read" on assignments for select
  using (customer_id = auth.uid() or current_interpreter_id = auth.uid());

create or replace function assignment_interpreter_matches(p_assignment_id uuid, p_interpreter_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1
    from assignments a
    join interpreters i on i.id = p_interpreter_id
    where a.id = p_assignment_id
      and i.available
      and exists (
        select 1 from interpreter_languages l
        where l.interpreter_id = i.id and lower(l.language) = lower(a.language)
      )
      and lower(a.specialty) = any(array(select lower(s) from unnest(i.specialties) s))
      and ((a.service_mode = 'remote' and i.remote) or (a.service_mode = 'in-person' and i.in_person))
      and (a.service_mode <> 'in-person' or (
        (nullif(a.city, '') is null or lower(i.city) = lower(a.city)) and
        (nullif(a.state, '') is null or lower(i.state) = lower(a.state))
      ))
      and (a.max_hourly_rate is null or i.hourly_rate <= a.max_hourly_rate)
  )
$$;

create or replace function find_next_assignment_interpreter(p_assignment_id uuid)
returns uuid
language sql stable security definer set search_path = public
as $$
  select i.id
  from interpreters i
  join assignments a on a.id = p_assignment_id
  where assignment_interpreter_matches(a.id, i.id)
    and not exists (
      select 1 from assignment_offers o
      where o.assignment_id = a.id and o.interpreter_id = i.id
    )
  order by i.verified desc, i.hourly_rate asc nulls last, i.id
  limit 1
$$;

create or replace function request_interpreter_assignment(
  p_interpreter_id uuid,
  p_language text,
  p_specialty text,
  p_city text,
  p_state text,
  p_service_mode text,
  p_scheduled_for timestamptz,
  p_max_hourly_rate numeric default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  customer profiles%rowtype;
  assignment_id uuid;
  conversation_id uuid;
  response_deadline timestamptz;
  assignment_note text;
begin
  select * into customer from profiles where id = auth.uid();
  if not found or customer.role not in ('organization','personal') then
    raise exception 'Personal or organization account required';
  end if;
  if nullif(btrim(p_language), '') is null or nullif(btrim(p_specialty), '') is null then
    raise exception 'Language and specialty are required';
  end if;
  if p_service_mode not in ('remote','in-person') then raise exception 'Invalid service mode'; end if;
  if p_service_mode = 'in-person' and nullif(btrim(p_city), '') is null then
    raise exception 'City is required for in-person assignments';
  end if;
  if p_scheduled_for <= now() + interval '1 hour' then raise exception 'Choose a time at least one hour from now'; end if;
  if p_max_hourly_rate is not null and p_max_hourly_rate < 0 then raise exception 'Invalid maximum rate'; end if;

  response_deadline := least(now() + interval '24 hours', p_scheduled_for - interval '1 hour');
  insert into assignments (
    customer_id, requested_interpreter_id, current_interpreter_id, language, specialty,
    city, state, service_mode, scheduled_for, max_hourly_rate, status, current_response_deadline
  ) values (
    customer.id, p_interpreter_id, p_interpreter_id, lower(btrim(p_language)), lower(btrim(p_specialty)),
    nullif(btrim(p_city), ''), nullif(btrim(p_state), ''), p_service_mode,
    p_scheduled_for, p_max_hourly_rate, 'offered', response_deadline
  ) returning id into assignment_id;

  if not assignment_interpreter_matches(assignment_id, p_interpreter_id) then
    raise exception 'Selected interpreter does not match this assignment';
  end if;

  insert into assignment_offers (assignment_id, interpreter_id, response_deadline)
    values (assignment_id, p_interpreter_id, response_deadline);

  insert into conversations (customer_id, interpreter_id, customer_label)
    values (customer.id, p_interpreter_id, coalesce(nullif(customer.org_name, ''), nullif(customer.full_name, ''), 'Customer'))
    on conflict (customer_id, interpreter_id) do nothing;
  select id into conversation_id from conversations
    where customer_id = customer.id and interpreter_id = p_interpreter_id;
  assignment_note := format(
    'Assignment request: %s interpreter for %s, %s. Please accept or decline in Assignments by %s.',
    p_language, p_specialty, p_service_mode, to_char(response_deadline, 'YYYY-MM-DD HH24:MI TZ')
  );
  insert into messages (conversation_id, sender_id, body)
    values (conversation_id, customer.id, assignment_note);
  update conversations set updated_at = now() where id = conversation_id;
  return assignment_id;
end;
$$;

create or replace function advance_assignment_offer(p_assignment_id uuid, p_force boolean default false)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  a assignments%rowtype;
  next_interpreter uuid;
  next_deadline timestamptz;
  conversation_id uuid;
  customer profiles%rowtype;
  interpreter_name text;
begin
  select * into a from assignments where id = p_assignment_id for update;
  if not found or a.status <> 'offered' then return null; end if;
  if not p_force and a.current_response_deadline > now() then return null; end if;

  update assignment_offers set status = 'expired', responded_at = now()
    where assignment_id = a.id and interpreter_id = a.current_interpreter_id and status = 'offered';
  next_interpreter := find_next_assignment_interpreter(a.id);

  if next_interpreter is null then
    update assignments set status = 'unfilled', current_interpreter_id = null, current_response_deadline = null
      where id = a.id;
    select * into customer from profiles where id = a.customer_id;
    insert into conversations (customer_id, interpreter_id, customer_label)
      values (a.customer_id, a.requested_interpreter_id, coalesce(nullif(customer.org_name, ''), nullif(customer.full_name, ''), 'Customer'))
      on conflict (customer_id, interpreter_id) do nothing;
    select id into conversation_id from conversations where customer_id = a.customer_id and interpreter_id = a.requested_interpreter_id;
    insert into messages (conversation_id, sender_id, body)
      values (conversation_id, a.customer_id, 'No other available interpreter matched this assignment. Please update the request or choose another interpreter.');
    update conversations set updated_at = now() where id = conversation_id;
    return null;
  end if;

  next_deadline := least(now() + interval '24 hours', a.scheduled_for - interval '1 hour');
  insert into assignment_offers (assignment_id, interpreter_id, response_deadline)
    values (a.id, next_interpreter, next_deadline);
  update assignments set current_interpreter_id = next_interpreter, current_response_deadline = next_deadline
    where id = a.id;
  select * into customer from profiles where id = a.customer_id;
  select display_name into interpreter_name from interpreters where id = next_interpreter;
  insert into conversations (customer_id, interpreter_id, customer_label)
    values (a.customer_id, next_interpreter, coalesce(nullif(customer.org_name, ''), nullif(customer.full_name, ''), 'Customer'))
    on conflict (customer_id, interpreter_id) do nothing;
  select id into conversation_id from conversations where customer_id = a.customer_id and interpreter_id = next_interpreter;
  insert into messages (conversation_id, sender_id, body)
    values (conversation_id, a.customer_id, format('New assignment request: %s interpreter for %s, %s. Please accept or decline in Assignments by %s.', a.language, a.specialty, a.service_mode, to_char(next_deadline, 'YYYY-MM-DD HH24:MI TZ')));
  update conversations set updated_at = now() where id = conversation_id;
  return next_interpreter;
end;
$$;

create or replace function respond_to_assignment(p_assignment_id uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  a assignments%rowtype;
begin
  if not exists (select 1 from profiles where id = auth.uid() and role = 'interpreter') then
    raise exception 'Interpreter account required';
  end if;
  select * into a from assignments where id = p_assignment_id for update;
  if not found or a.status <> 'offered' or a.current_interpreter_id <> auth.uid() then
    raise exception 'Assignment offer is no longer active';
  end if;
  if a.current_response_deadline <= now() then
    perform advance_assignment_offer(a.id, false);
    return;
  end if;

  if p_accept then
    update assignment_offers set status = 'accepted', responded_at = now()
      where assignment_id = a.id and interpreter_id = auth.uid() and status = 'offered';
    update assignments set status = 'accepted', accepted_at = now() where id = a.id;
  else
    update assignment_offers set status = 'declined', responded_at = now()
      where assignment_id = a.id and interpreter_id = auth.uid() and status = 'offered';
    perform advance_assignment_offer(a.id, true);
  end if;
end;
$$;

create or replace function expire_unanswered_assignments()
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  a record;
  total integer := 0;
begin
  for a in select id from assignments where status = 'offered' and current_response_deadline <= now()
  loop
    perform advance_assignment_offer(a.id, false);
    total := total + 1;
  end loop;
  return total;
end;
$$;

revoke all on function assignment_interpreter_matches(uuid, uuid) from public, anon, authenticated;
revoke all on function find_next_assignment_interpreter(uuid) from public, anon, authenticated;
revoke all on function request_interpreter_assignment(uuid, text, text, text, text, text, timestamptz, numeric) from public, anon;
revoke all on function advance_assignment_offer(uuid, boolean) from public, anon, authenticated;
revoke all on function respond_to_assignment(uuid, boolean) from public, anon;
revoke all on function expire_unanswered_assignments() from public, anon, authenticated;
grant execute on function request_interpreter_assignment(uuid, text, text, text, text, text, timestamptz, numeric) to authenticated;
grant execute on function respond_to_assignment(uuid, boolean) to authenticated;

grant select on assignments to authenticated;

create extension if not exists pg_cron;
select cron.schedule(
  'expire-unanswered-assignment-offers',
  '*/5 * * * *',
  $$select public.expire_unanswered_assignments();$$
);
