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
  and past that Claude answers from what it knows. Nothing is stored. The two functions share `_shared/` (caller, Pro check, Claude client).
- Pro is checked from the signed App Store transaction the app sends, verified against Apple's root
  certificates bundled in `_shared/apple_roots.ts`, and remembered until that period ends. The check
  uses Web Crypto (`@peculiar/x509`): Supabase's runtime does not implement node:crypto's
  `X509Certificate.verify`, which `@apple/app-store-server-library` needs.
- Only the function (service role) can read `assistant_usage` and `assistant_pro`; row level
  security with no policies keeps every client out.

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
