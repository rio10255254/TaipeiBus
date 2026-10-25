-- Online understanding: how many sentences each anonymous phone sent today, and verified Pro access.
-- Only the Edge Function (service role) reads or writes these tables; row level security with no
-- policies keeps every client out. No sentence text is stored.

create table if not exists public.assistant_usage (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  count integer not null default 0,
  primary key (user_id, day)
);
alter table public.assistant_usage enable row level security;

create table if not exists public.assistant_pro (
  user_id uuid primary key references auth.users (id) on delete cascade,
  original_transaction_id text not null,
  expires_at timestamptz not null,
  updated_at timestamptz not null default now()
);
alter table public.assistant_pro enable row level security;

-- Takes one sentence from today's allowance; returns the new count, or null when it is used up.
create or replace function public.take_assistant_allowance(p_user uuid, p_day date, p_limit integer)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  used integer;
begin
  insert into assistant_usage (user_id, day, count)
  values (p_user, p_day, 1)
  on conflict (user_id, day) do update
    set count = assistant_usage.count + 1
    where assistant_usage.count < p_limit
  returning count into used;
  return used;
end;
$$;

revoke all on function public.take_assistant_allowance(uuid, date, integer) from public, anon, authenticated;
grant execute on function public.take_assistant_allowance(uuid, date, integer) to service_role;

-- Old rows are not needed after a few days.
create or replace function public.prune_assistant_usage()
returns void
language sql
security definer
set search_path = public
as $$
  delete from assistant_usage where day < current_date - 7;
$$;
revoke all on function public.prune_assistant_usage() from public, anon, authenticated;
grant execute on function public.prune_assistant_usage() to service_role;
