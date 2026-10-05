alter table assignments
  add column address text,
  add column room_number text,
  add column parking_instructions text,
  add column transit_stop text;

drop function request_interpreter_assignment(uuid, text, text, text, text, text, timestamptz, numeric);

create or replace function request_interpreter_assignment(
  p_interpreter_id uuid,
  p_language text,
  p_specialty text,
  p_city text,
  p_state text,
  p_service_mode text,
  p_scheduled_for timestamptz,
  p_max_hourly_rate numeric default null,
  p_address text default null,
  p_room_number text default null,
  p_parking_instructions text default null,
  p_transit_stop text default null
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
  if p_service_mode = 'in-person' and nullif(btrim(p_address), '') is null then
    raise exception 'Address is required for in-person assignments';
  end if;
  if p_service_mode = 'in-person' and p_scheduled_for <= now() + interval '1 hour' then
    raise exception 'In-person assignments must start more than one hour from now';
  end if;
  if p_service_mode = 'remote' and p_scheduled_for <= now() + interval '4 hours' then
    raise exception 'Virtual assignments must start more than four hours from now';
  end if;
  if p_max_hourly_rate is not null and p_max_hourly_rate < 0 then raise exception 'Invalid maximum rate'; end if;

  response_deadline := case p_service_mode
    when 'in-person' then least(now() + interval '24 hours', p_scheduled_for - interval '1 hour')
    else least(now() + interval '24 hours', p_scheduled_for - interval '4 hours')
  end;
  insert into assignments (
    customer_id, requested_interpreter_id, current_interpreter_id, language, specialty,
    city, state, service_mode, scheduled_for, max_hourly_rate, status, current_response_deadline,
    address, room_number, parking_instructions, transit_stop
  ) values (
    customer.id, p_interpreter_id, p_interpreter_id, lower(btrim(p_language)), lower(btrim(p_specialty)),
    nullif(btrim(p_city), ''), nullif(btrim(p_state), ''), p_service_mode,
    p_scheduled_for, p_max_hourly_rate, 'offered', response_deadline,
    nullif(btrim(p_address), ''), nullif(btrim(p_room_number), ''),
    nullif(btrim(p_parking_instructions), ''), nullif(btrim(p_transit_stop), '')
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

revoke all on function request_interpreter_assignment(uuid, text, text, text, text, text, timestamptz, numeric, text, text, text, text) from public, anon;
grant execute on function request_interpreter_assignment(uuid, text, text, text, text, text, timestamptz, numeric, text, text, text, text) to authenticated;
