-- 0014: Server-side Edge Functions (payments, payouts, webhooks) connect as service_role.
-- This project does not grant new tables to service_role automatically, so grant it explicitly,
-- including for anything created later. The browser roles (anon, authenticated) are unchanged.
grant usage on schema public to service_role;
grant all on all tables in schema public to service_role;
grant all on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
alter default privileges in schema public grant all on tables to service_role;
alter default privileges in schema public grant all on sequences to service_role;
alter default privileges in schema public grant execute on functions to service_role;
