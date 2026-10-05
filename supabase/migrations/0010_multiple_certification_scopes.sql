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
