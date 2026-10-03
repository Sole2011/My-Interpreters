alter table interpreter_contacts enable row level security;

drop policy if exists "own contact" on interpreter_contacts;
drop policy if exists "own contact update" on interpreter_contacts;

revoke all on interpreter_contacts from anon, authenticated;
grant select (interpreter_id) on interpreter_contacts to authenticated;
grant update (phone) on interpreter_contacts to authenticated;

create policy "own contact update" on interpreter_contacts for update
  using (interpreter_id = auth.uid())
  with check (interpreter_id = auth.uid());
