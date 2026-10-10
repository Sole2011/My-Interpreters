-- ===== 0001_init.sql =====
-- Core schema
create table profiles (
  id uuid primary key references auth.users,
  role text check (role in ('interpreter','organization')) not null,
  full_name text,
  org_name text,
  org_verified boolean default false,
  plan text default 'free' check (plan in ('free','pro','unlimited')),
  unlocks_used int default 0,
  period_start date default current_date
);

create table interpreters (
  id uuid primary key references profiles(id),
  bio text,
  city text, state text,
  remote boolean default true,
  in_person boolean default true,
  hourly_rate numeric,
  specialties text[],                  -- {'medical','legal','conference'}
  verified boolean default false,
  featured boolean default false,
  available boolean default true
);

create table interpreter_languages (
  interpreter_id uuid references interpreters(id) on delete cascade,
  language text,
  proficiency text,
  primary key (interpreter_id, language)
);

create table certifications (
  id serial primary key,
  interpreter_id uuid references interpreters(id) on delete cascade,
  name text,                           -- CCHI, NBCMI, court cert
  document_url text,
  status text default 'pending' check (status in ('pending','verified','rejected'))
);

-- Contact details live in a separate, locked-down table
create table interpreter_contacts (
  interpreter_id uuid primary key references interpreters(id),
  email text, phone text
);

create table unlocks (
  org_id uuid references profiles(id),
  interpreter_id uuid references interpreters(id),
  created_at timestamptz default now(),
  primary key (org_id, interpreter_id)
);

-- Privileges: clients get only what they need; flags like verified, featured and plan are server-controlled.
revoke all on profiles, interpreters, interpreter_languages, certifications, interpreter_contacts, unlocks from anon, authenticated;
revoke all on sequence certifications_id_seq from anon, authenticated;

grant select on profiles to authenticated;
grant insert (id, role, full_name, org_name) on profiles to authenticated;
grant update (full_name, org_name) on profiles to authenticated;

grant select on interpreters, interpreter_languages to anon, authenticated;
grant insert (id, bio, city, state, remote, in_person, hourly_rate, specialties, available) on interpreters to authenticated;
grant update (bio, city, state, remote, in_person, hourly_rate, specialties, available) on interpreters to authenticated;
grant insert, update, delete on interpreter_languages to authenticated;

grant select on certifications to anon, authenticated;
grant insert (interpreter_id, name, document_url) on certifications to authenticated;
grant usage on sequence certifications_id_seq to authenticated;

grant select, insert, update on interpreter_contacts to authenticated;
grant select on unlocks to authenticated;

-- Row-level security
alter table profiles enable row level security;
alter table interpreters enable row level security;
alter table interpreter_languages enable row level security;
alter table certifications enable row level security;
alter table interpreter_contacts enable row level security;
alter table unlocks enable row level security;

create policy "own profile read" on profiles for select using (id = auth.uid());
create policy "own profile insert" on profiles for insert with check (id = auth.uid());
create policy "own profile update" on profiles for update using (id = auth.uid());

create policy "public directory" on interpreters for select using (true);
create policy "own interpreter insert" on interpreters for insert
  with check (id = auth.uid() and exists (select 1 from profiles where id = auth.uid() and role = 'interpreter'));
create policy "own interpreter update" on interpreters for update using (id = auth.uid());

create policy "public languages" on interpreter_languages for select using (true);
create policy "own languages write" on interpreter_languages for all
  using (interpreter_id = auth.uid()) with check (interpreter_id = auth.uid());

-- Anyone sees verified certs; interpreters also see their own. Status is only changed by admins (service role).
create policy "certs read" on certifications for select using (status = 'verified' or interpreter_id = auth.uid());
create policy "own cert insert" on certifications for insert with check (interpreter_id = auth.uid());

-- Contacts: owner only. Organizations get them through unlock_contact().
create policy "own contact" on interpreter_contacts for all
  using (interpreter_id = auth.uid()) with check (interpreter_id = auth.uid());

create policy "own unlocks" on unlocks for select using (org_id = auth.uid());

-- Atomic unlock: checks eligibility, enforces plan and daily limits, never double-counts.
create or replace function unlock_contact(p_interpreter_id uuid)
returns table (email text, phone text)
language plpgsql security definer set search_path = public
as $$
declare
  p profiles%rowtype;
  plan_limit int;
  daily_cap constant int := 20;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found or p.role <> 'organization' then raise exception 'Organizations only'; end if;
  if not p.org_verified then raise exception 'Organization not verified'; end if;

  if not exists (select 1 from unlocks where org_id = p.id and interpreter_id = p_interpreter_id) then
    if p.period_start < date_trunc('month', current_date)::date then
      update profiles set unlocks_used = 0, period_start = date_trunc('month', current_date)::date where id = p.id;
      p.unlocks_used := 0;
    end if;
    plan_limit := case p.plan when 'free' then 0 when 'pro' then 10 else null end;
    if plan_limit is not null and p.unlocks_used >= plan_limit then raise exception 'No unlocks left on your plan'; end if;
    if (select count(*) from unlocks where org_id = p.id and created_at > now() - interval '1 day') >= daily_cap then
      raise exception 'Daily unlock limit reached';
    end if;
    insert into unlocks (org_id, interpreter_id) values (p.id, p_interpreter_id);
    update profiles set unlocks_used = unlocks_used + 1 where id = p.id;
  end if;

  return query select c.email, c.phone from interpreter_contacts c where c.interpreter_id = p_interpreter_id;
end;
$$;
revoke all on function unlock_contact(uuid) from public, anon;
grant execute on function unlock_contact(uuid) to authenticated;


-- ===== 0002_client_support.sql =====
-- Public display name, signup trigger, and interpreter stats for the client app.
alter table interpreters add column display_name text;
grant insert (display_name), update (display_name) on interpreters to authenticated;

-- Profile rows are created server-side from signup metadata so signup works before email confirmation.
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r text := m->>'role';
begin
  if r is null or r not in ('interpreter','organization') then raise exception 'invalid role'; end if;
  insert into profiles (id, role, full_name, org_name)
    values (new.id, r, left(m->>'full_name', 100), left(m->>'org_name', 150));

  if r = 'interpreter' then
    insert into interpreters (id, display_name, city, state, remote, in_person, hourly_rate, specialties)
    values (new.id, left(m->>'full_name', 100), left(m->>'city', 100), left(m->>'state', 50),
      coalesce((m->>'remote')::boolean, true), coalesce((m->>'in_person')::boolean, true),
      (m->>'hourly_rate')::numeric,
      array(select left(x, 50) from jsonb_array_elements_text(coalesce(m->'specialties', '[]'::jsonb)) x limit 20));
    insert into interpreter_languages (interpreter_id, language)
      select new.id, left(x, 50) from jsonb_array_elements_text(coalesce(m->'languages', '[]'::jsonb)) x limit 20
      on conflict do nothing;
    insert into interpreter_contacts (interpreter_id, email, phone) values (new.id, new.email, left(m->>'phone', 40));
    insert into certifications (interpreter_id, name)
      select new.id, left(x, 100) from jsonb_array_elements_text(coalesce(m->'certs', '[]'::jsonb)) x limit 20;
  end if;
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create or replace function my_unlock_count()
returns int language sql stable security definer set search_path = public
as $$ select count(*)::int from unlocks where interpreter_id = auth.uid() $$;
revoke all on function my_unlock_count() from public, anon;
grant execute on function my_unlock_count() to authenticated;


-- ===== 0003_billing.sql =====
alter table profiles add column stripe_customer_id text unique, add column stripe_subscription_id text;


-- ===== 0004_lock_contacts.sql =====
alter table interpreter_contacts enable row level security;

drop policy if exists "own contact" on interpreter_contacts;
drop policy if exists "own contact update" on interpreter_contacts;

revoke all on interpreter_contacts from anon, authenticated;
grant select (interpreter_id) on interpreter_contacts to authenticated;
grant update (phone) on interpreter_contacts to authenticated;

create policy "own contact update" on interpreter_contacts for update
  using (interpreter_id = auth.uid())
  with check (interpreter_id = auth.uid());


-- ===== 0005_certification_scope.sql =====
alter table certifications
  add column scope text check (scope in ('national','international','state','local'));

create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r text := m->>'role';
  cert_scope text := nullif(lower(m->>'certification_scope'), '');
begin
  if r is null or r not in ('interpreter','organization') then raise exception 'invalid role'; end if;
  insert into profiles (id, role, full_name, org_name)
    values (new.id, r, left(m->>'full_name', 100), left(m->>'org_name', 150));

  if r = 'interpreter' then
    insert into interpreters (id, display_name, city, state, remote, in_person, hourly_rate, specialties)
    values (new.id, left(m->>'full_name', 100), left(m->>'city', 100), left(m->>'state', 50),
      coalesce((m->>'remote')::boolean, true), coalesce((m->>'in_person')::boolean, true),
      (m->>'hourly_rate')::numeric,
      array(select left(x, 50) from jsonb_array_elements_text(coalesce(m->'specialties', '[]'::jsonb)) x limit 20));
    insert into interpreter_languages (interpreter_id, language)
      select new.id, left(x, 50) from jsonb_array_elements_text(coalesce(m->'languages', '[]'::jsonb)) x limit 20
      on conflict do nothing;
    insert into interpreter_contacts (interpreter_id, email, phone) values (new.id, new.email, left(m->>'phone', 40));
    insert into certifications (interpreter_id, name, scope)
      select new.id, left(x, 100), cert_scope
      from jsonb_array_elements_text(coalesce(m->'certs', '[]'::jsonb)) x limit 20;
  end if;
  return new;
end;
$$;


-- ===== 0006_personal_accounts.sql =====
alter table profiles rename column org_verified to account_verified;
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('interpreter','organization','personal'));

alter table unlocks rename column org_id to customer_id;

create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r text := m->>'role';
  cert_scope text := nullif(lower(m->>'certification_scope'), '');
begin
  if r is null or r not in ('interpreter','organization','personal') then raise exception 'invalid role'; end if;
  insert into profiles (id, role, full_name, org_name)
    values (new.id, r, left(m->>'full_name', 100), left(m->>'org_name', 150));

  if r = 'interpreter' then
    insert into interpreters (id, display_name, city, state, remote, in_person, hourly_rate, specialties)
    values (new.id, left(m->>'full_name', 100), left(m->>'city', 100), left(m->>'state', 50),
      coalesce((m->>'remote')::boolean, true), coalesce((m->>'in_person')::boolean, true),
      (m->>'hourly_rate')::numeric,
      array(select left(x, 50) from jsonb_array_elements_text(coalesce(m->'specialties', '[]'::jsonb)) x limit 20));
    insert into interpreter_languages (interpreter_id, language)
      select new.id, left(x, 50) from jsonb_array_elements_text(coalesce(m->'languages', '[]'::jsonb)) x limit 20
      on conflict do nothing;
    insert into interpreter_contacts (interpreter_id, email, phone) values (new.id, new.email, left(m->>'phone', 40));
    insert into certifications (interpreter_id, name, scope)
      select new.id, left(x, 100), cert_scope
      from jsonb_array_elements_text(coalesce(m->'certs', '[]'::jsonb)) x limit 20;
  end if;
  return new;
end;
$$;

create or replace function unlock_contact(p_interpreter_id uuid)
returns table (email text, phone text)
language plpgsql security definer set search_path = public
as $$
declare
  p profiles%rowtype;
  plan_limit int;
  daily_cap constant int := 20;
begin
  select * into p from profiles where id = auth.uid() for update;
  if not found or p.role not in ('organization','personal') then raise exception 'Customer account required'; end if;
  if not p.account_verified then raise exception 'Account not verified'; end if;

  if not exists (select 1 from unlocks where customer_id = p.id and interpreter_id = p_interpreter_id) then
    if p.period_start < date_trunc('month', current_date)::date then
      update profiles set unlocks_used = 0, period_start = date_trunc('month', current_date)::date where id = p.id;
      p.unlocks_used := 0;
    end if;
    plan_limit := case p.plan when 'free' then 0 when 'pro' then 10 else null end;
    if plan_limit is not null and p.unlocks_used >= plan_limit then raise exception 'No unlocks left on your plan'; end if;
    if (select count(*) from unlocks where customer_id = p.id and created_at > now() - interval '1 day') >= daily_cap then
      raise exception 'Daily unlock limit reached';
    end if;
    insert into unlocks (customer_id, interpreter_id) values (p.id, p_interpreter_id);
    update profiles set unlocks_used = unlocks_used + 1 where id = p.id;
  end if;

  return query select c.email, c.phone from interpreter_contacts c where c.interpreter_id = p_interpreter_id;
end;
$$;
revoke all on function unlock_contact(uuid) from public, anon;
grant execute on function unlock_contact(uuid) to authenticated;


-- ===== 0007_private_messaging.sql =====
drop function if exists unlock_contact(uuid);

create table conversations (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references profiles(id) on delete cascade,
  interpreter_id uuid not null references interpreters(id) on delete cascade,
  customer_label text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (customer_id, interpreter_id)
);

create table messages (
  id bigint generated always as identity primary key,
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id uuid not null references profiles(id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now()
);

create index conversations_customer_updated on conversations (customer_id, updated_at desc);
create index conversations_interpreter_updated on conversations (interpreter_id, updated_at desc);
create index messages_conversation_created on messages (conversation_id, created_at);

alter table conversations enable row level security;
alter table messages enable row level security;
revoke all on conversations, messages from anon, authenticated;
grant select on conversations, messages to authenticated;

create policy "conversation participants can read" on conversations for select
  using (customer_id = auth.uid() or interpreter_id = auth.uid());

create policy "conversation messages can be read by participants" on messages for select
  using (exists (
    select 1 from conversations c
    where c.id = conversation_id
      and (c.customer_id = auth.uid() or c.interpreter_id = auth.uid())
  ));

create or replace function start_conversation(p_interpreter_id uuid, p_body text)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare
  p profiles%rowtype;
  v_conversation_id uuid;
begin
  select * into p from profiles where id = auth.uid();
  if not found or p.role not in ('organization','personal') then
    raise exception 'Personal or organization account required';
  end if;
  if char_length(btrim(coalesce(p_body, ''))) not between 1 and 4000 then
    raise exception 'Message must be between 1 and 4000 characters';
  end if;
  if not exists (select 1 from interpreters where id = p_interpreter_id) then
    raise exception 'Interpreter not found';
  end if;

  insert into conversations (customer_id, interpreter_id, customer_label)
    values (p.id, p_interpreter_id, coalesce(nullif(p.org_name, ''), nullif(p.full_name, ''), 'Customer'))
    on conflict (customer_id, interpreter_id) do nothing;
  select id into v_conversation_id from conversations
    where customer_id = p.id and interpreter_id = p_interpreter_id;
  insert into messages (conversation_id, sender_id, body)
    values (v_conversation_id, p.id, btrim(p_body));
  update conversations set updated_at = now() where id = v_conversation_id;
  return v_conversation_id;
end;
$$;

create or replace function send_message(p_conversation_id uuid, p_body text)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  sender uuid := auth.uid();
begin
  if sender is null then raise exception 'Sign in required'; end if;
  if char_length(btrim(coalesce(p_body, ''))) not between 1 and 4000 then
    raise exception 'Message must be between 1 and 4000 characters';
  end if;
  perform 1 from conversations
    where id = p_conversation_id and (customer_id = sender or interpreter_id = sender)
    for update;
  if not found then raise exception 'Conversation not found'; end if;

  insert into messages (conversation_id, sender_id, body)
    values (p_conversation_id, sender, btrim(p_body));
  update conversations set updated_at = now() where id = p_conversation_id;
end;
$$;

revoke all on function start_conversation(uuid, text) from public, anon;
revoke all on function send_message(uuid, text) from public, anon;
grant execute on function start_conversation(uuid, text) to authenticated;
grant execute on function send_message(uuid, text) to authenticated;


-- ===== 0008_assignment_requests.sql =====
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

  next_deadline := case a.service_mode
    when 'in-person' then least(now() + interval '24 hours', a.scheduled_for - interval '1 hour')
    else least(now() + interval '24 hours', a.scheduled_for - interval '4 hours')
  end;
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


-- ===== 0009_assignment_location_details.sql =====
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


-- ===== 0010_multiple_certification_scopes.sql =====
create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r text := m->>'role';
  cert_names text[];
  cert_scopes text[];
begin
  if r is null or r not in ('interpreter','organization','personal') then raise exception 'invalid role'; end if;
  insert into profiles (id, role, full_name, org_name)
    values (new.id, r, left(m->>'full_name', 100), left(m->>'org_name', 150));

  if r = 'interpreter' then
    insert into interpreters (id, display_name, city, state, remote, in_person, hourly_rate, specialties)
    values (new.id, left(m->>'full_name', 100), left(m->>'city', 100), left(m->>'state', 50),
      coalesce((m->>'remote')::boolean, true), coalesce((m->>'in_person')::boolean, true),
      (m->>'hourly_rate')::numeric,
      array(select left(x, 50) from jsonb_array_elements_text(coalesce(m->'specialties', '[]'::jsonb)) x limit 20));
    insert into interpreter_languages (interpreter_id, language)
      select new.id, left(x, 50) from jsonb_array_elements_text(coalesce(m->'languages', '[]'::jsonb)) x limit 20
      on conflict do nothing;
    insert into interpreter_contacts (interpreter_id, email, phone) values (new.id, new.email, left(m->>'phone', 40));

    select coalesce(array_agg(distinct left(btrim(x), 100)), array[]::text[])
      into cert_names
      from jsonb_array_elements_text(coalesce(m->'certs', '[]'::jsonb)) x
      where nullif(btrim(x), '') is not null;
    select coalesce(array_agg(distinct lower(btrim(x))), array[]::text[])
      into cert_scopes
      from jsonb_array_elements_text(coalesce(m->'certification_scopes', '[]'::jsonb)) x
      where lower(btrim(x)) in ('national','international','state','local');

    if cardinality(cert_scopes) = 0 then
      insert into certifications (interpreter_id, name)
        select new.id, cert_name from unnest(cert_names) cert_name;
    else
      insert into certifications (interpreter_id, name, scope)
        select new.id, cert_name, cert_scope
        from unnest(cert_names) cert_name
        cross join unnest(cert_scopes) cert_scope;
    end if;
  end if;
  return new;
end;
$$;


-- ===== 0011_consent_notifications.sql =====
alter table profiles
  add column accepted_terms_version text,
  add column accepted_privacy_version text,
  add column accepted_rules_version text,
  add column required_policy_notifications boolean not null default true,
  add column feature_updates_opt_in boolean not null default false,
  add column consented_at timestamptz;

create table site_notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  category text not null check (category in ('policy','feature')),
  title text not null,
  body text not null,
  version text,
  requires_ack boolean not null default false,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  acknowledged_at timestamptz
);

create index site_notifications_user_created on site_notifications (user_id, created_at desc);

alter table site_notifications enable row level security;
revoke all on site_notifications from anon, authenticated;
grant select on site_notifications to authenticated;
grant update (read_at) on site_notifications to authenticated;

create policy "users can read own notifications" on site_notifications for select
  using (user_id = auth.uid());
create policy "users can mark own notifications read" on site_notifications for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r text := m->>'role';
  cert_names text[];
  cert_scopes text[];
begin
  if r is null or r not in ('interpreter','organization','personal') then raise exception 'invalid role'; end if;
  if m->>'accepted_terms_version' is distinct from '1.0'
    or m->>'accepted_privacy_version' is distinct from '1.0'
    or m->>'accepted_rules_version' is distinct from '1.0'
    or coalesce((m->>'required_policy_notifications')::boolean, false) is not true then
    raise exception 'Accept the current terms, privacy notice, community rules, and required policy notifications';
  end if;

  insert into profiles (
    id, role, full_name, org_name, accepted_terms_version, accepted_privacy_version,
    accepted_rules_version, required_policy_notifications, feature_updates_opt_in, consented_at
  ) values (
    new.id, r, left(m->>'full_name', 100), left(m->>'org_name', 150),
    m->>'accepted_terms_version', m->>'accepted_privacy_version', m->>'accepted_rules_version',
    true, coalesce((m->>'feature_updates_opt_in')::boolean, false), now()
  );

  if r = 'interpreter' then
    insert into interpreters (id, display_name, city, state, remote, in_person, hourly_rate, specialties)
    values (new.id, left(m->>'full_name', 100), left(m->>'city', 100), left(m->>'state', 50),
      coalesce((m->>'remote')::boolean, true), coalesce((m->>'in_person')::boolean, true),
      (m->>'hourly_rate')::numeric,
      array(select left(x, 50) from jsonb_array_elements_text(coalesce(m->'specialties', '[]'::jsonb)) x limit 20));
    insert into interpreter_languages (interpreter_id, language)
      select new.id, left(x, 50) from jsonb_array_elements_text(coalesce(m->'languages', '[]'::jsonb)) x limit 20
      on conflict do nothing;
    insert into interpreter_contacts (interpreter_id, email, phone)
      values (new.id, new.email, left(m->>'phone', 40));

    select coalesce(array_agg(distinct left(btrim(x), 100)), array[]::text[])
      into cert_names
      from jsonb_array_elements_text(coalesce(m->'certs', '[]'::jsonb)) x
      where nullif(btrim(x), '') is not null;
    select coalesce(array_agg(distinct lower(btrim(x))), array[]::text[])
      into cert_scopes
      from jsonb_array_elements_text(coalesce(m->'certification_scopes', '[]'::jsonb)) x
      where lower(btrim(x)) in ('national','international','state','local');

    if cardinality(cert_scopes) = 0 then
      insert into certifications (interpreter_id, name)
        select new.id, cert_name from unnest(cert_names) cert_name;
    else
      insert into certifications (interpreter_id, name, scope)
        select new.id, cert_name, cert_scope
        from unnest(cert_names) cert_name
        cross join unnest(cert_scopes) cert_scope;
    end if;
  end if;
  return new;
end;
$$;

create or replace function publish_site_notification(
  p_category text,
  p_title text,
  p_body text,
  p_version text default null,
  p_requires_ack boolean default false
)
returns integer
language plpgsql security definer set search_path = public
as $$
declare
  inserted_count integer;
begin
  if auth.role() <> 'service_role' then raise exception 'Service role required'; end if;
  if p_category not in ('policy','feature') then raise exception 'Invalid notification category'; end if;
  if p_category = 'feature' and p_requires_ack then raise exception 'Feature notices cannot require policy acceptance'; end if;

  insert into site_notifications (user_id, category, title, body, version, requires_ack)
    select p.id, p_category, p_title, p_body, p_version, p_requires_ack
    from profiles p
    where p_category = 'policy' or p.feature_updates_opt_in;
  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

create or replace function acknowledge_site_notification(p_notification_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  n site_notifications%rowtype;
begin
  select * into n from site_notifications
    where id = p_notification_id and user_id = auth.uid() for update;
  if not found or not n.requires_ack or n.category <> 'policy' then
    raise exception 'Required policy notice not found';
  end if;

  update site_notifications set acknowledged_at = now(), read_at = coalesce(read_at, now()) where id = n.id;
  update profiles set
    accepted_terms_version = coalesce(n.version, accepted_terms_version),
    accepted_privacy_version = coalesce(n.version, accepted_privacy_version),
    accepted_rules_version = coalesce(n.version, accepted_rules_version),
    consented_at = now()
  where id = auth.uid();
end;
$$;

create or replace function update_feature_updates_preference(p_enabled boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign in required'; end if;
  update profiles set feature_updates_opt_in = coalesce(p_enabled, false) where id = auth.uid();
end;
$$;

revoke all on function publish_site_notification(text, text, text, text, boolean) from public, anon, authenticated;
revoke all on function acknowledge_site_notification(uuid) from public, anon;
revoke all on function update_feature_updates_preference(boolean) from public, anon;
grant execute on function publish_site_notification(text, text, text, text, boolean) to service_role;
grant execute on function acknowledge_site_notification(uuid) to authenticated;
grant execute on function update_feature_updates_preference(boolean) to authenticated;

insert into site_notifications (user_id, category, title, body, version, requires_ack)
select id, 'policy', 'Review Exponent policies',
  'Please review and accept the current Terms, Privacy Notice, and Community Rules to continue using your account.',
  '1.0', true
from profiles
where accepted_terms_version is null
   or accepted_privacy_version is null
   or accepted_rules_version is null;


-- ===== 0012_interpreter_postal_code.sql =====
alter table interpreters
  add column postal_code text,
  add constraint interpreters_postal_code_format
    check (postal_code is null or postal_code ~ '^[0-9]{5}(-[0-9]{4})?$');

grant update (postal_code) on interpreters to authenticated;

create or replace function handle_new_user()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  r text := m->>'role';
  cert_names text[];
  cert_scopes text[];
begin
  if r is null or r not in ('interpreter','organization','personal') then raise exception 'invalid role'; end if;
  if m->>'accepted_terms_version' is distinct from '1.0'
    or m->>'accepted_privacy_version' is distinct from '1.0'
    or m->>'accepted_rules_version' is distinct from '1.0'
    or coalesce((m->>'required_policy_notifications')::boolean, false) is not true then
    raise exception 'Accept the current terms, privacy notice, community rules, and required policy notifications';
  end if;

  insert into profiles (
    id, role, full_name, org_name, accepted_terms_version, accepted_privacy_version,
    accepted_rules_version, required_policy_notifications, feature_updates_opt_in, consented_at
  ) values (
    new.id, r, left(m->>'full_name', 100), left(m->>'org_name', 150),
    m->>'accepted_terms_version', m->>'accepted_privacy_version', m->>'accepted_rules_version',
    true, coalesce((m->>'feature_updates_opt_in')::boolean, false), now()
  );

  if r = 'interpreter' then
    insert into interpreters (id, display_name, city, state, postal_code, remote, in_person, hourly_rate, specialties)
    values (new.id, left(m->>'full_name', 100), left(m->>'city', 100), left(m->>'state', 50),
      nullif(btrim(m->>'postal_code'), ''),
      coalesce((m->>'remote')::boolean, true), coalesce((m->>'in_person')::boolean, true),
      (m->>'hourly_rate')::numeric,
      array(select left(x, 50) from jsonb_array_elements_text(coalesce(m->'specialties', '[]'::jsonb)) x limit 20));
    insert into interpreter_languages (interpreter_id, language)
      select new.id, left(x, 50) from jsonb_array_elements_text(coalesce(m->'languages', '[]'::jsonb)) x limit 20
      on conflict do nothing;
    insert into interpreter_contacts (interpreter_id, email, phone)
      values (new.id, new.email, left(m->>'phone', 40));

    select coalesce(array_agg(distinct left(btrim(x), 100)), array[]::text[])
      into cert_names
      from jsonb_array_elements_text(coalesce(m->'certs', '[]'::jsonb)) x
      where nullif(btrim(x), '') is not null;
    select coalesce(array_agg(distinct lower(btrim(x))), array[]::text[])
      into cert_scopes
      from jsonb_array_elements_text(coalesce(m->'certification_scopes', '[]'::jsonb)) x
      where lower(btrim(x)) in ('national','international','state','local');

    if cardinality(cert_scopes) = 0 then
      insert into certifications (interpreter_id, name)
        select new.id, cert_name from unnest(cert_names) cert_name;
    else
      insert into certifications (interpreter_id, name, scope)
        select new.id, cert_name, cert_scope
        from unnest(cert_names) cert_name
        cross join unnest(cert_scopes) cert_scope;
    end if;
  end if;
  return new;
end;
$$;




-- ===== 0013_payments.sql =====
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
