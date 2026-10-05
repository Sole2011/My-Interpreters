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
