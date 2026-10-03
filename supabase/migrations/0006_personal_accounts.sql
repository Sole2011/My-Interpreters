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
