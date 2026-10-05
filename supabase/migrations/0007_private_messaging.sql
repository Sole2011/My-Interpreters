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
