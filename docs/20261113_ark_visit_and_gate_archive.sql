-- UNAPPLIED DRAFT. Do not run until Brian approves.
-- Project: aklxxrmytplbrjqunkpg (main SWAGG Supabase project)
-- Date drafted: 2026-11-13, America/Denver (MT)
--
-- What this does:
--   1) Extends the existing zero-proof age_gate_events archive so a pass or
--      decline can be stored as category + timestamp only (no ip, device, or name).
--   2) After a new age_assertions row with event 'yes' or 'no' is written by the
--      live Oasis gate, a trigger copies only that decision and time into
--      age_gate_events as 'pass' or 'decline'. The Oasis gate file does not
--      need to change. Permanent totals are kept. Raw rows still purge at 28 days.
--   3) Adds page_visits / page_visit_totals for Signal Ark, Ark dashboard, and
--      Living Archive visits, with an insert-only RPC, a short-lived rate-limit
--      hash that is never stored on the archive row, a public 28-day live count,
--      and signed-in-only access to the lasting totals.
--
-- This script does NOT:
--   - touch age_verifications or any age_verifications_* table
--   - change age_assertions columns or existing rows
--   - change what the Ark pages display
--
-- Apply only after explicit approval, then merge the BaileyOS-Public page PR
-- so visit logging starts. Pass/decline archiving starts as soon as this
-- migration is applied, because the Oasis gate already writes yes/no.

-- ---------------------------------------------------------------------------
-- 1. Age-gate pass / decline on the existing zero-proof events table
-- ---------------------------------------------------------------------------
alter table public.age_gate_events
  drop constraint if exists age_gate_events_event_check;

alter table public.age_gate_events
  add constraint age_gate_events_event_check
  check (event = any (array['gate_shown','backed_out','click','dwell','pass','decline']));

alter table public.age_gate_event_totals
  drop constraint if exists age_gate_event_totals_event_check;

alter table public.age_gate_event_totals
  add constraint age_gate_event_totals_event_check
  check (event = any (array['gate_shown','backed_out','click','dwell','pass','decline']));

insert into public.age_gate_event_totals (event, total)
values ('pass', 0), ('decline', 0)
on conflict (event) do nothing;

comment on table public.age_gate_events is
  'Zero-proof age-gate archive: event (gate_shown, backed_out, click, dwell, pass, decline), time, and optional dwell_ms only. No ip, device, or name. Raw rows purged after 28 days. Lasting totals stay in age_gate_event_totals.';

create or replace function public.archive_age_gate_decision_from_assertion()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.event = 'yes' then
    insert into public.age_gate_events (event, created_at)
    values ('pass', coalesce(new.created_at, now()));
  elsif new.event = 'no' then
    insert into public.age_gate_events (event, created_at)
    values ('decline', coalesce(new.created_at, now()));
  end if;
  return new;
end;
$function$;

drop trigger if exists age_assertions_archive_pass_decline_ai on public.age_assertions;
create trigger age_assertions_archive_pass_decline_ai
after insert on public.age_assertions
for each row
when (new.event = any (array['yes'::text, 'no'::text]))
execute function public.archive_age_gate_decision_from_assertion();

revoke all on function public.archive_age_gate_decision_from_assertion() from public, anon, authenticated;

comment on function public.archive_age_gate_decision_from_assertion() is
  'Copies only pass/decline (yes/no) and the timestamp from age_assertions into the zero-proof age_gate_events archive. Does not copy identity fields and does not touch age_verifications.';

-- Signed-in users may read lasting age-gate totals (the archive).
-- Raw event rows stay insert-only for anon; no public select on raw rows.
-- FORCE RLS is already on this totals table, so a policy is required too.
grant select on public.age_gate_event_totals to authenticated;
drop policy if exists authenticated_select_age_gate_event_totals on public.age_gate_event_totals;
create policy authenticated_select_age_gate_event_totals
  on public.age_gate_event_totals
  for select
  to authenticated
  using (true);

-- Public live count for the current 28-day window (raw rows only).
create or replace function public.get_age_gate_live_count(p_event text)
returns bigint
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  n bigint;
begin
  if p_event is null or p_event not in ('gate_shown','backed_out','click','dwell','pass','decline') then
    raise exception 'invalid event';
  end if;
  select count(*) into n
    from public.age_gate_events
   where event = p_event
     and created_at >= now() - interval '28 days';
  return coalesce(n, 0);
end;
$function$;

revoke all on function public.get_age_gate_live_count(text) from public;
grant execute on function public.get_age_gate_live_count(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Ark page visits
-- ---------------------------------------------------------------------------
create table if not exists public.page_visits (
  id uuid primary key default gen_random_uuid(),
  category text not null
    check (category = any (array['signal_ark','ark_dashboard','living_archive'])),
  viewer_kind text not null
    check (viewer_kind = any (array['logged_out_visitor','logged_in'])),
  created_at timestamptz not null default now()
);

create index if not exists page_visits_created_at_idx
  on public.page_visits (created_at);

create index if not exists page_visits_category_created_at_idx
  on public.page_visits (category, created_at);

comment on table public.page_visits is
  'Zero-proof Ark page visit archive: category (signal_ark, ark_dashboard, living_archive), viewer_kind (logged_out_visitor or logged_in), and a millisecond-precision timestamp only. No ip, user agent, name, or device. Raw rows purged after 28 days.';

comment on column public.page_visits.created_at is
  'Visit time with millisecond precision (timestamptz). No other visitor data.';

create table if not exists public.page_visit_totals (
  category text not null
    check (category = any (array['signal_ark','ark_dashboard','living_archive'])),
  viewer_kind text not null
    check (viewer_kind = any (array['logged_out_visitor','logged_in'])),
  total bigint not null default 0 check (total >= 0),
  primary key (category, viewer_kind)
);

insert into public.page_visit_totals (category, viewer_kind, total)
values
  ('signal_ark', 'logged_out_visitor', 0),
  ('signal_ark', 'logged_in', 0),
  ('ark_dashboard', 'logged_out_visitor', 0),
  ('ark_dashboard', 'logged_in', 0),
  ('living_archive', 'logged_out_visitor', 0),
  ('living_archive', 'logged_in', 0)
on conflict (category, viewer_kind) do nothing;

comment on table public.page_visit_totals is
  'Permanent Ark page visit totals by category and viewer_kind. Not rolled back when raw page_visits rows are purged after 28 days. Signed-in select only.';

create or replace function public.bump_page_visit_total()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.page_visit_totals
     set total = total + 1
   where category = new.category
     and viewer_kind = new.viewer_kind;
  return new;
end;
$function$;

drop trigger if exists page_visits_total_ai on public.page_visits;
create trigger page_visits_total_ai
after insert on public.page_visits
for each row execute function public.bump_page_visit_total();

revoke all on function public.bump_page_visit_total() from public, anon, authenticated;

-- Short-lived rate-limit helper. Stores only a hash and a time, never on page_visits.
-- Purged quickly. Not exposed through the Data API.
create table if not exists public.page_visit_rate_limits (
  client_hash text not null,
  created_at timestamptz not null default now()
);

create index if not exists page_visit_rate_limits_hash_created_at_idx
  on public.page_visit_rate_limits (client_hash, created_at);

create or replace function public.record_page_visit(p_category text)
returns bigint
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_kind text;
  v_hash text;
  v_recent int;
  v_live bigint;
begin
  if p_category is null or p_category not in ('signal_ark','ark_dashboard','living_archive') then
    raise exception 'invalid category';
  end if;

  v_kind := case when auth.uid() is null then 'logged_out_visitor' else 'logged_in' end;
  v_hash := encode(extensions.digest(coalesce(inet_client_addr()::text, 'unknown'), 'sha256'), 'hex');

  delete from public.page_visit_rate_limits
   where created_at < now() - interval '1 hour';

  select count(*) into v_recent
    from public.page_visit_rate_limits
   where client_hash = v_hash
     and created_at >= now() - interval '1 hour';

  if v_recent >= 30 then
    raise exception 'rate limit';
  end if;

  insert into public.page_visit_rate_limits (client_hash, created_at)
  values (v_hash, now());

  insert into public.page_visits (category, viewer_kind)
  values (p_category, v_kind);

  select count(*) into v_live
    from public.page_visits
   where category = p_category
     and created_at >= now() - interval '28 days';

  return coalesce(v_live, 0);
end;
$function$;

create or replace function public.get_page_visit_live_count(p_category text)
returns bigint
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  n bigint;
begin
  if p_category is null or p_category not in ('signal_ark','ark_dashboard','living_archive') then
    raise exception 'invalid category';
  end if;
  select count(*) into n
    from public.page_visits
   where category = p_category
     and created_at >= now() - interval '28 days';
  return coalesce(n, 0);
end;
$function$;

create or replace function public.delete_old_page_visits()
returns void
language plpgsql
set search_path to 'public', 'pg_temp'
as $function$
begin
  delete from public.page_visits
   where created_at < now() - interval '28 days';
  delete from public.page_visit_rate_limits
   where created_at < now() - interval '1 hour';
end;
$function$;

alter table public.page_visits enable row level security;
alter table public.page_visits force row level security;
alter table public.page_visit_totals enable row level security;
alter table public.page_visit_totals force row level security;
alter table public.page_visit_rate_limits enable row level security;
alter table public.page_visit_rate_limits force row level security;

revoke all on public.page_visits from public, anon, authenticated;
revoke all on public.page_visit_totals from public, anon, authenticated;
revoke all on public.page_visit_rate_limits from public, anon, authenticated;

-- Lasting archive: signed-in only. No public select on raw rows or the rate-limit table.
grant select on public.page_visit_totals to authenticated;
grant all on public.page_visits, public.page_visit_totals, public.page_visit_rate_limits to service_role;

drop policy if exists authenticated_select_page_visit_totals on public.page_visit_totals;
create policy authenticated_select_page_visit_totals
  on public.page_visit_totals
  for select
  to authenticated
  using (true);

revoke all on function public.record_page_visit(text) from public;
revoke all on function public.get_page_visit_live_count(text) from public;
revoke all on function public.delete_old_page_visits() from public, anon, authenticated;
grant execute on function public.record_page_visit(text) to anon, authenticated;
grant execute on function public.get_page_visit_live_count(text) to anon, authenticated;

-- Nightly purge, after the existing 15 2 * * * age_gate_events job (times are UTC,
-- same window as the other 28-day jobs). Skip if the job is already scheduled.
do $cron$
begin
  if not exists (select 1 from cron.job where jobname = 'delete-old-page-visits') then
    perform cron.schedule(
      'delete-old-page-visits',
      '20 2 * * *',
      'select public.delete_old_page_visits()'
    );
  end if;
end;
$cron$;


-- ---------------------------------------------------------------------------
-- 3. Views and policies so the Ark screens can read the archive
--    without querying age_verifications.
-- ---------------------------------------------------------------------------

-- Public may read only zero-proof pass/decline rows from the last 28 days.
-- This also lets Realtime deliver those inserts to the pages.
drop policy if exists anon_select_age_gate_pass_decline_live on public.age_gate_events;
create policy anon_select_age_gate_pass_decline_live
  on public.age_gate_events
  for select
  to anon, authenticated
  using (
    event = any (array['pass'::text, 'decline'::text])
    and created_at >= now() - interval '28 days'
  );

-- Live 28-day decision list, shaped like the columns the pages already read
-- (id, verified, verified_at, source, event). security_invoker so it respects
-- the policy above: no older rows, and no other event types.
create or replace view public.archive_decisions_live
with (security_invoker = true) as
select
  id,
  (event = 'pass') as verified,
  created_at as verified_at,
  'age-gate'::text as source,
  event
from public.age_gate_events
where event = any (array['pass'::text, 'decline'::text])
  and created_at >= now() - interval '28 days';

comment on view public.archive_decisions_live is
  'Public 28-day zero-proof pass/decline archive for the Ark screens. No ip, device, or name. Lasting totals stay in age_gate_event_totals (signed-in only).';

grant select on public.archive_decisions_live to anon, authenticated;

-- Lasting pass/decline totals, signed-in only. The live pages have no sign-in
-- today, so they use archive_decisions_live (28 days) for everyone.
create or replace view public.archive_decision_totals
with (security_invoker = true) as
select event, total
  from public.age_gate_event_totals
 where event = any (array['pass'::text, 'decline'::text]);

comment on view public.archive_decision_totals is
  'Permanent pass/decline totals. Signed-in select only. Not rolled back when raw rows purge at 28 days.';

grant select on public.archive_decision_totals to authenticated;
revoke all on public.archive_decision_totals from anon, public;

-- Realtime for pass/decline inserts. age_gate_events is not in the publication yet.
do $pub$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'age_gate_events'
  ) then
    execute 'alter publication supabase_realtime add table public.age_gate_events';
  end if;
end;
$pub$;

-- Backfill ENABLED (Brian, Nov 13, 2026, 9:56 AM MT: "Start at 6, include the Nov 1 passes").
-- Copies last-28-day yes/no assertions into the zero-proof archive
-- (category + timestamp only; no identity fields). Guarded so re-running adds nothing twice.
insert into public.age_gate_events (event, created_at)
select case when a.event = 'yes' then 'pass' else 'decline' end, a.created_at
  from public.age_assertions a
 where a.event in ('yes', 'no')
   and a.created_at >= now() - interval '28 days'
   and not exists (
     select 1 from public.age_gate_events g
      where g.created_at = a.created_at
        and g.event = case when a.event = 'yes' then 'pass' else 'decline' end
   );
