-- Voice answers a rider chose to report, kept 30 days to improve the conversation.
create table if not exists public.assistant_feedback (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  heard text not null,
  said text not null,
  state text not null,
  model text not null default '',
  note text not null default ''
);
alter table public.assistant_feedback enable row level security;
create index if not exists assistant_feedback_user_day on public.assistant_feedback (user_id, created_at);

-- How many phones a subscription has proved Pro on lately, to stop one proof unlocking many.
create index if not exists assistant_pro_transaction on public.assistant_pro (original_transaction_id, updated_at);

create or replace function public.prune_assistant_usage()
returns void
language sql
security definer
set search_path = public
as $$
  delete from assistant_usage where day < current_date - 7;
  delete from assistant_voice_usage where day < current_date - 7;
  delete from assistant_web_usage where day < current_date - 7;
  delete from assistant_feedback where created_at < now() - interval '30 days';
$$;
revoke all on function public.prune_assistant_usage() from public, anon, authenticated;
grant execute on function public.prune_assistant_usage() to service_role;
