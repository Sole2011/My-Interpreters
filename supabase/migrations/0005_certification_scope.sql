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
