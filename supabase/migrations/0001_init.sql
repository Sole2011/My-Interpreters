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
