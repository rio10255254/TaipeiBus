# 台北公車 assistant server

Online understanding goes through this Supabase project instead of a key built into the app.

- The app signs in anonymously once (no account, email or name) and keeps its refresh token in the
  Keychain. It ships only the project URL and publishable key, which are public by design.
- `functions/understand` checks the caller's token, takes one sentence from that phone's daily
  allowance (20, or 100 with Pro), and forwards the chat request to Groq. The Groq key exists only
  in this project's secrets. Sentences are not stored.
- Pro is checked from the signed App Store transaction the app sends, verified with Apple's root
  certificates (`@apple/app-store-server-library`), and remembered until that period ends.
- Only the function (service role) can read `assistant_usage` and `assistant_pro`; row level
  security with no policies keeps every client out.

## One-time setup

1. Create a new Supabase project for 台北公車 (region: Tokyo or Singapore).
2. In GitHub › Settings › Secrets and variables › Actions add:
   - secrets: `SUPABASE_ACCESS_TOKEN` (account › access tokens), `SUPABASE_DB_PASSWORD`
     (the project's database password). `GROQ_API_KEY` is already there.
   - variables: `SUPABASE_PROJECT_REF` (the id in the project URL), `SUPABASE_URL`
     (`https://<ref>.supabase.co`), `SUPABASE_PUBLISHABLE_KEY` (Project settings › API keys),
     and later `APP_APPLE_ID` (the numeric App Store id) for production Pro checks.
3. Run the **Assistant server** workflow. It migrates the database, enables anonymous sign-ins,
   copies `GROQ_API_KEY` into the project's secrets without printing it, and deploys the function.
4. The next TestFlight build reads `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` and talks to it.
5. Then rotate the Groq key once (Groq console), update the `GROQ_API_KEY` secret and rerun the
   workflow: earlier TestFlight builds carried the old key inside the app.
