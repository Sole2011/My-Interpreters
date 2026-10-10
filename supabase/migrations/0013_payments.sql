-- 0013: Secure booking payments (Stripe Connect, separate charges and transfers).
-- No card data is ever stored here. Stripe holds the card; this schema only tracks state.
--
-- Flow: customer requests (awaiting_payment) -> Stripe Checkout authorizes a hold ->
-- webhook activates the offer -> interpreter accepts via Edge Function, which captures
-- the hold and transfers the interpreter's share -> database marks the job accepted.

-- Interpreters' Stripe Connect accounts. Private: clients may only see their own payout status.
create table interpreter_payout_accounts (
  interpreter_id uuid primary key references interpreters(id) on delete cascade,
  stripe_account_id text not null unique,
  payouts_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table interpreter_payout_accounts enable row level security;
revoke all on interpreter_payout_accounts from anon, authenticated;
grant select (interpreter_id, payouts_enabled) on interpreter_payout_accounts to authenticated;
create policy "interpreters can read own payout status" on interpreter_payout_accounts for select
  using (interpreter_id = auth.uid());

alter table assignments
  add column duration_hours numeric check (duration_hours is null or (duration_hours >= 0.5 and duration_hours <= 12)),
  add column currency text not null default 'usd',
  add column authorized_amount_cents integer check (authorized_amount_cents is null or authorized_amount_cents >= 50),
  add column captured_amount_cents integer,
  add column platform_fee_cents integer,
  add column payment_status text not null default 'unpaid'
    check (payment_status in ('unpaid','authorized','capturing','captured','released','failed')),
  add column payment_updated_at timestamptz not null default now(),
  add column payment_authorized_at timestamptz,
  add column stripe_checkout_session_id text,
  add column stripe_payment_intent_id text unique,
  add column stripe_transfer_id text;

alter table assignments drop constraint assignments_status_check;
alter table assignments add constraint assignments_status_check
  check (status in ('awaiting_payment','offered','accepted','cancelled','unfilled'));

-- Stripe identifiers stay server-side; everything else remains visible to participants.
revoke select on assignments from authenticated;
grant select (
  id, customer_id, requested_interpreter_id, current_interpreter_id, language, specialty,
  city, state, service_mode, scheduled_for, max_hourly_rate, status, current_response_deadline,
  accepted_at, created_at, address, room_number, parking_instructions, transit_stop,
  duration_hours, currency, authorized_amount_cents, captured_amount_cents, platform_fee_cents,
  payment_status, payment_authorized_at
) on assignments to authenticated;

-- Only interpreters who finished Stripe onboarding can be matched, so a paid booking can always be paid out.

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
      and exists (select 1 from interpreter_payout_accounts p where p.interpreter_id = i.id and p.payouts_enabled)
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

-- Card holds expire after about 7 days, so offers must be answered with margin before that.
create or replace function hold_capturable_until(p_authorized_at timestamptz)
returns timestamptz
language sql immutable
as $$ select coalesce(p_authorized_at, now()) + interval '6 days 12 hours' $$;

-- An offer in the middle of being accepted must not be passed to the next interpreter.
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
  if not found or a.status <> 'offered' or a.payment_status = 'capturing' then return null; end if;
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

  next_deadline := least(case a.service_mode
    when 'in-person' then least(now() + interval '24 hours', a.scheduled_for - interval '1 hour')
    else least(now() + interval '24 hours', a.scheduled_for - interval '4 hours')
  end, hold_capturable_until(a.payment_authorized_at));
  if next_deadline <= now() then
    update assignments set status = 'unfilled', current_interpreter_id = null, current_response_deadline = null
      where id = a.id;
    return null;
  end if;
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

drop function request_interpreter_assignment(uuid, text, text, text, text, text, timestamptz, numeric, text, text, text, text);

-- Creates the request in awaiting_payment. Nothing is offered to the interpreter until the card hold succeeds.
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
  p_transit_stop text default null,
  p_duration_hours numeric default null
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  customer profiles%rowtype;
  assignment_id uuid;
  rate_ceiling numeric;
  authorized_cents integer;
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
  if p_duration_hours is null or p_duration_hours < 0.5 or p_duration_hours > 12 then
    raise exception 'Duration must be between 0.5 and 12 hours';
  end if;
  if not exists (
    select 1 from interpreter_payout_accounts where interpreter_id = p_interpreter_id and payouts_enabled
  ) then
    raise exception 'This interpreter has not finished setting up payouts yet';
  end if;

  -- The hold covers the highest rate any matched interpreter could charge, so a later
  -- offer to a different interpreter can never exceed what the customer authorized.
  rate_ceiling := coalesce(p_max_hourly_rate, (select hourly_rate from interpreters where id = p_interpreter_id));
  if rate_ceiling is null or rate_ceiling <= 0 then
    raise exception 'This interpreter has not listed an hourly rate; enter a maximum hourly rate';
  end if;
  authorized_cents := ceil(rate_ceiling * p_duration_hours * 100)::integer;
  if authorized_cents < 50 then raise exception 'Booking total is below the minimum charge'; end if;
  if authorized_cents > 1000000 then raise exception 'Booking total is above the maximum allowed'; end if;

  insert into assignments (
    customer_id, requested_interpreter_id, language, specialty,
    city, state, service_mode, scheduled_for, max_hourly_rate, status,
    address, room_number, parking_instructions, transit_stop,
    duration_hours, authorized_amount_cents
  ) values (
    customer.id, p_interpreter_id, lower(btrim(p_language)), lower(btrim(p_specialty)),
    nullif(btrim(p_city), ''), nullif(btrim(p_state), ''), p_service_mode,
    p_scheduled_for, rate_ceiling, 'awaiting_payment',
    nullif(btrim(p_address), ''), nullif(btrim(p_room_number), ''),
    nullif(btrim(p_parking_instructions), ''), nullif(btrim(p_transit_stop), ''),
    p_duration_hours, authorized_cents
  ) returning id into assignment_id;

  if not assignment_interpreter_matches(assignment_id, p_interpreter_id) then
    raise exception 'Selected interpreter does not match this assignment';
  end if;
  return assignment_id;
end;
$$;

revoke all on function request_interpreter_assignment(uuid, text, text, text, text, text, timestamptz, numeric, text, text, text, text, numeric) from public, anon;
grant execute on function request_interpreter_assignment(uuid, text, text, text, text, text, timestamptz, numeric, text, text, text, text, numeric) to authenticated;

-- Called only by the Stripe webhook (service role) once the card hold exists.
create or replace function activate_assignment(p_assignment_id uuid, p_payment_intent_id text)
returns text
language plpgsql security definer set search_path = public
as $$
declare
  a assignments%rowtype;
  customer profiles%rowtype;
  response_deadline timestamptz;
  conversation_id uuid;
begin
  select * into a from assignments where id = p_assignment_id for update;
  if not found then raise exception 'Assignment not found'; end if;
  if a.status <> 'awaiting_payment' then return a.status; end if;

  response_deadline := least(case a.service_mode
    when 'in-person' then least(now() + interval '24 hours', a.scheduled_for - interval '1 hour')
    else least(now() + interval '24 hours', a.scheduled_for - interval '4 hours')
  end, hold_capturable_until(now()));
  if response_deadline <= now() then
    update assignments set status = 'cancelled', payment_status = 'authorized',
      stripe_payment_intent_id = p_payment_intent_id, payment_updated_at = now(), payment_authorized_at = now()
      where id = a.id;
    return 'cancelled';
  end if;

  update assignments set
    status = 'offered', current_interpreter_id = a.requested_interpreter_id,
    current_response_deadline = response_deadline, payment_status = 'authorized',
    stripe_payment_intent_id = p_payment_intent_id, payment_updated_at = now(), payment_authorized_at = now()
  where id = a.id;
  insert into assignment_offers (assignment_id, interpreter_id, response_deadline)
    values (a.id, a.requested_interpreter_id, response_deadline);

  select * into customer from profiles where id = a.customer_id;
  insert into conversations (customer_id, interpreter_id, customer_label)
    values (a.customer_id, a.requested_interpreter_id, coalesce(nullif(customer.org_name, ''), nullif(customer.full_name, ''), 'Customer'))
    on conflict (customer_id, interpreter_id) do nothing;
  select id into conversation_id from conversations
    where customer_id = a.customer_id and interpreter_id = a.requested_interpreter_id;
  insert into messages (conversation_id, sender_id, body)
    values (conversation_id, a.customer_id, format(
      'Assignment request: %s interpreter for %s, %s. Please accept or decline in Assignments by %s.',
      a.language, a.specialty, a.service_mode, to_char(response_deadline, 'YYYY-MM-DD HH24:MI TZ')));
  update conversations set updated_at = now() where id = conversation_id;
  return 'offered';
end;
$$;

-- Accepting is only possible through the accept-assignment Edge Function, which captures payment first.
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
  if p_accept then
    raise exception 'Accepting an assignment requires payment confirmation. Use Accept in Assignments.';
  end if;
  select * into a from assignments where id = p_assignment_id for update;
  if not found or a.status <> 'offered' or a.current_interpreter_id <> auth.uid() then
    raise exception 'Assignment offer is no longer active';
  end if;
  if a.payment_status = 'capturing' then
    raise exception 'This assignment is being confirmed';
  end if;
  if a.current_response_deadline <= now() then
    perform advance_assignment_offer(a.id, false);
    return;
  end if;
  update assignment_offers set status = 'declined', responded_at = now()
    where assignment_id = a.id and interpreter_id = auth.uid() and status = 'offered';
  perform advance_assignment_offer(a.id, true);
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
  -- An interrupted acceptance goes back to a normal offer so it can be retried or expire,
  -- unless the card was already charged: then it stays with that interpreter until they finish.
  update assignments set payment_status = 'authorized', payment_updated_at = now()
    where status = 'offered' and payment_status = 'capturing' and captured_amount_cents is null
      and payment_updated_at < now() - interval '10 minutes';
  update assignments set status = 'cancelled'
    where status = 'awaiting_payment' and created_at < now() - interval '2 hours';

  for a in select id from assignments
    where status = 'offered' and payment_status <> 'capturing' and current_response_deadline <= now()
  loop
    perform advance_assignment_offer(a.id, false);
    total := total + 1;
  end loop;
  return total;
end;
$$;

-- Step 1 of acceptance (service role): lock the offer and return what Stripe needs.
create or replace function begin_assignment_acceptance(p_assignment_id uuid, p_interpreter_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  a assignments%rowtype;
  rate numeric;
  amount integer;
  account text;
begin
  select * into a from assignments where id = p_assignment_id for update;
  if not found or a.status <> 'offered' or a.current_interpreter_id is distinct from p_interpreter_id then
    raise exception 'Assignment offer is no longer active';
  end if;
  if a.payment_status not in ('authorized', 'capturing') or a.stripe_payment_intent_id is null then
    raise exception 'The customer''s payment is not confirmed';
  end if;
  if a.payment_status = 'authorized' and a.current_response_deadline <= now() then
    raise exception 'This offer has expired';
  end if;
  select hourly_rate into rate from interpreters where id = p_interpreter_id;
  select stripe_account_id into account from interpreter_payout_accounts
    where interpreter_id = p_interpreter_id and payouts_enabled;
  if account is null then raise exception 'Set up payouts before accepting assignments'; end if;
  if a.captured_amount_cents is null and (rate is null or rate <= 0 or rate > a.max_hourly_rate) then
    raise exception 'Your hourly rate does not fit this booking';
  end if;
  -- A retry after the card was charged must finish with exactly the amount already captured.
  amount := coalesce(a.captured_amount_cents, round(rate * a.duration_hours * 100)::integer);
  if amount < 50 or amount > a.authorized_amount_cents then
    raise exception 'Booking total does not fit the authorized amount';
  end if;

  update assignments set payment_status = 'capturing', payment_updated_at = now() where id = a.id;
  return jsonb_build_object(
    'payment_intent_id', a.stripe_payment_intent_id,
    'amount_cents', amount,
    'currency', a.currency,
    'stripe_account_id', account
  );
end;
$$;

-- Step 2 failed before any money moved: allow another attempt.
create or replace function abort_assignment_acceptance(p_assignment_id uuid)
returns void
language sql security definer set search_path = public
as $$
  update assignments set payment_status = 'authorized', payment_updated_at = now()
  where id = p_assignment_id and status = 'offered' and payment_status = 'capturing' and captured_amount_cents is null;
$$;

-- Step 2b (service role): the card was charged. Recorded before paying the interpreter so the
-- offer can never be handed to someone else while the money is waiting to be transferred.
create or replace function record_assignment_capture(p_assignment_id uuid, p_captured_cents integer)
returns void
language sql security definer set search_path = public
as $$
  update assignments set captured_amount_cents = p_captured_cents, payment_updated_at = now()
  where id = p_assignment_id and status = 'offered' and payment_status = 'capturing';
$$;

-- Step 3 (service role): money has moved, so record the acceptance. Safe to repeat.
create or replace function finalize_assignment_acceptance(
  p_assignment_id uuid, p_interpreter_id uuid, p_captured_cents integer, p_fee_cents integer, p_transfer_id text
)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  a assignments%rowtype;
begin
  select * into a from assignments where id = p_assignment_id for update;
  if not found then raise exception 'Assignment not found'; end if;
  if a.status = 'accepted' and a.current_interpreter_id = p_interpreter_id then return; end if;
  if a.status <> 'offered' or a.current_interpreter_id is distinct from p_interpreter_id or a.payment_status <> 'capturing' then
    raise exception 'Assignment is not awaiting confirmation';
  end if;
  update assignment_offers set status = 'accepted', responded_at = now()
    where assignment_id = a.id and interpreter_id = p_interpreter_id and status = 'offered';
  update assignments set
    status = 'accepted', accepted_at = now(), payment_status = 'captured', payment_updated_at = now(),
    captured_amount_cents = p_captured_cents, platform_fee_cents = p_fee_cents, stripe_transfer_id = p_transfer_id
  where id = a.id;
end;
$$;

-- Customer cancels before acceptance (service role). Returns the hold to release, if any.
create or replace function cancel_assignment_by_customer(p_assignment_id uuid, p_customer_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  a assignments%rowtype;
begin
  select * into a from assignments where id = p_assignment_id for update;
  if not found or a.customer_id <> p_customer_id then raise exception 'Assignment not found'; end if;
  if a.status not in ('awaiting_payment', 'offered', 'unfilled') or a.payment_status = 'capturing' then
    raise exception 'This assignment can no longer be cancelled here';
  end if;
  update assignment_offers set status = 'expired', responded_at = now()
    where assignment_id = a.id and status = 'offered';
  update assignments set status = 'cancelled', current_response_deadline = null where id = a.id;
  return jsonb_build_object(
    'payment_intent_id', case when a.payment_status = 'authorized' then a.stripe_payment_intent_id end
  );
end;
$$;

create or replace function mark_payment_released(p_assignment_id uuid)
returns void
language sql security definer set search_path = public
as $$
  update assignments set payment_status = 'released', payment_updated_at = now()
  where id = p_assignment_id and status = 'cancelled' and payment_status = 'authorized';
$$;

-- Server-only functions: never callable from the browser.
revoke all on function activate_assignment(uuid, text) from public, anon, authenticated;
revoke all on function begin_assignment_acceptance(uuid, uuid) from public, anon, authenticated;
revoke all on function abort_assignment_acceptance(uuid) from public, anon, authenticated;
revoke all on function record_assignment_capture(uuid, integer) from public, anon, authenticated;
revoke all on function finalize_assignment_acceptance(uuid, uuid, integer, integer, text) from public, anon, authenticated;
revoke all on function cancel_assignment_by_customer(uuid, uuid) from public, anon, authenticated;
revoke all on function mark_payment_released(uuid) from public, anon, authenticated;
grant execute on function activate_assignment(uuid, text) to service_role;
grant execute on function begin_assignment_acceptance(uuid, uuid) to service_role;
grant execute on function abort_assignment_acceptance(uuid) to service_role;
grant execute on function record_assignment_capture(uuid, integer) to service_role;
grant execute on function finalize_assignment_acceptance(uuid, uuid, integer, integer, text) to service_role;
grant execute on function cancel_assignment_by_customer(uuid, uuid) to service_role;
grant execute on function mark_payment_released(uuid) to service_role;
