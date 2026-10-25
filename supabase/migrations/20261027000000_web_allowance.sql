-- Web lookups from the voice conversation (Pro): how many each anonymous phone made today. Only the
-- Edge Function (service role) reads or writes it; no query text is stored.

create table if not exists public.assistant_web_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  count integer not null default 0,
  primary key (user_id, day)
);
alter table public.assistant_web_usage enable row level security;

-- Takes one lookup from today's allowance; returns the new count, or null when it is used up.
create or replace function public.take_web_allowance(p_user uuid, p_day date, p_limit integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  used integer;
begin
  insert into assistant_web_usage (user_id, day, count)
  values (p_user, p_day, 1)
  on conflict (user_id, day) do update
    set count = assistant_web_usage.count + 1
    where assistant_web_usage.count < p_limit
  returning count into used;
  return used;
end;
$$;

revoke all on function public.take_web_allowance(uuid, date, integer) from public, anon, authenticated;
grant execute on function public.take_web_allowance(uuid, date, integer) to service_role;

-- Old rows of every allowance are not needed after a few days.
create or replace function public.prune_assistant_usage()
returns void
language sql
security definer
set search_path = public
as $$
  delete from assistant_usage where day < current_date - 7;
  delete from assistant_voice_usage where day < current_date - 7;
  delete from assistant_web_usage where day < current_date - 7;
$$;
revoke all on function public.prune_assistant_usage() from public, anon, authenticated;
grant execute on function public.prune_assistant_usage() to service_role;
