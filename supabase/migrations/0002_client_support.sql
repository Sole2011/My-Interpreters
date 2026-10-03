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
