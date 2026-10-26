-- What the weekly replay (supabase/functions/converse/replay.ts) found when it asked the current model a
-- reported turn again: 'pass' or 'fail:<category>', what the reported answer got wrong, when and with
-- which model. Fixed labels only; the report's own text stays in this table. Row level security is
-- unchanged: only the service role (and the owner's SQL access) can read it.
alter table public.assistant_feedback
  add column if not exists checked_at timestamptz,
  add column if not exists verdict text,
  add column if not exists reported_issue text,
  add column if not exists checked_model text;
