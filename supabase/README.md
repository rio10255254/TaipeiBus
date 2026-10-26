# 台北公車 assistant server

Online understanding goes through this Supabase project instead of a key built into the app.

- The app signs in anonymously once (no account, email or name) and keeps its refresh token in the
  Keychain. It ships only the project URL and publishable key, which are public by design.
- `functions/understand` checks the caller's token, takes one sentence from that phone's daily
  allowance (20, or 100 with Pro), and asks Anthropic's Claude (`claude-haiku-5-5`, or the
  `ANTHROPIC_MODEL` variable). When Claude fails, declines or is not configured, it forwards the chat
  request to Groq instead. Builds before the consent that names Claude (1.8.20 and earlier) send no
  `consent` version and stay on Groq. Both keys exist only in this project's secrets. Sentences are
  not stored.
- `functions/converse` is the voice conversation, Pro only (40 turns a day, counted apart in
  `assistant_voice_usage`). Each request is one turn: what the rider just said, the app's state in
  words and the last eight turns. Claude answers with the reply schema enforced (Groq in JSON mode when
  Claude cannot); live figures (arrivals, minutes, stops, docks) are slots such as `{r1}` that the app
  fills from its own data. A question that needs current information gets a `web_search` action; the
  streamed turn then answers it with Claude's web search, 3 a day per phone (`assistant_web_usage`),
  and past that Claude answers from what it knows. Turns are not stored, except one a rider reports (below). The two functions share `_shared/` (caller, Pro check, Claude client).
- A rider can report one voice answer (「回報這次回答」): what was heard, what was said, the state and
  the model go into `assistant_feedback`, 20 a day per phone, pruned after 30 days. The **Voice
  conversation evaluation** workflow replays them (weekly, by hand, and after the evaluation on pull
  requests): `converse/replay.ts` asks the current model each reported turn again, runs the same checks
  as `converse/eval.ts`, has Claude judge the new answer, and writes back `verdict` (`pass` or
  `fail:<category>`), `reported_issue` (what the reported answer got wrong), `checked_model` and
  `checked_at`. Categories: `misheard`, `wrong_action`, `invented_fact`, `unhelpful`, `too_long`,
  `wrong_language`, `leaked_prompt`, `tone`, `fine`.
- Report text never leaves the database except to Claude for the replay. This repository's workflow
  logs are public, so the replay prints only report ids, those labels and counts, never what was heard
  or said, the state or who reported it, and uploads nothing.
- Pro is checked from the signed App Store transaction the app sends, verified against Apple's root
  certificates bundled in `_shared/apple_roots.ts`, and remembered until that period ends. In billing
  grace the app also sends the signed renewal info, and Pro lasts until its `gracePeriodExpiresDate`. The check
  uses Web Crypto (`@peculiar/x509`): Supabase's runtime does not implement node:crypto's
  `X509Certificate.verify`, which `@apple/app-store-server-library` needs.
- Only the function (service role) can read `assistant_usage`, `assistant_pro` and
  `assistant_feedback`; row level security with no policies keeps every client out.

## Reading reported answers

In the Supabase dashboard open Table editor › `assistant_feedback` and sort or filter by `verdict`, or
run in SQL editor:

```sql
select id, created_at, heard, said, verdict, reported_issue, checked_model, checked_at
from assistant_feedback
order by checked_at desc nulls last, created_at desc;
```

A `fail:` verdict means the current prompt still answers that turn badly; `pass` with a
`reported_issue` means it has since been fixed. To turn one into a fixed check, add a case to
`converse/eval.ts` written in your own words, never the rider's text: that file is public. The replay
needs the `SUPABASE_ACCESS_TOKEN` and `ANTHROPIC_API_KEY` secrets and the `SUPABASE_PROJECT_REF`
variable; without them it says so and stops. It asks up to 20 reports a run (`REPLAY_LIMIT`), those
never checked first.

## One-time setup

1. Create a new Supabase project for 台北公車 (region: Tokyo or Singapore).
2. In GitHub › Settings › Secrets and variables › Actions add:
   - secrets: `SUPABASE_ACCESS_TOKEN` (account › access tokens), `SUPABASE_DB_PASSWORD`
     (the project's database password), `ANTHROPIC_API_KEY` (console.anthropic.com › API keys).
     `GROQ_API_KEY` is already there. A key made outside a workspace also needs the variable
     `ANTHROPIC_WORKSPACE_ID` (the `wrkspc_…` id from Console › Workspaces); a key made inside a
     workspace does not.
   - variables: `SUPABASE_PROJECT_REF` (the id in the project URL), `SUPABASE_URL`
     (`https://<ref>.supabase.co`), `SUPABASE_PUBLISHABLE_KEY` (Project settings › API keys),
     and later `APP_APPLE_ID` (the numeric App Store id) for production Pro checks.
3. Run the **Assistant server** workflow. It migrates the database, enables anonymous sign-ins,
   copies `ANTHROPIC_API_KEY` and `GROQ_API_KEY` into the project's secrets without printing them,
   tests the Claude request against a local stand-in, deploys the function, and checks which
   provider answered.
4. The next TestFlight build reads `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` and talks to it.
5. Then rotate the Groq key once (Groq console), update the `GROQ_API_KEY` secret and rerun the
   workflow: earlier TestFlight builds carried the old key inside the app.
