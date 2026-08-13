# Voxel Craft — COMMUNITY_BACKEND_SETUP.md

Deployment/local-dev instructions for the Community backend introduced in
Runtime 0.2 — Community Backend Foundation. Read `COMMUNITY_BACKEND_SPEC.md`
first for the design and security architecture; this document is the
practical "how do I stand this up" companion.

## 1. What you need

- A Supabase project (a free-tier project is enough for this milestone).
- The Supabase CLI, authenticated (`supabase login`) and linked to your
  project (`supabase link --project-ref <ref>`).
- Nothing else — no server to run, no build step, no Node project. The
  Runtime and Portal are still plain static HTML files.

**Never paste your project's secret/service-role key into any file in
this repository, into chat with an AI assistant, or into any client-side
code.** Only two values are ever meant to live in `index.html`/
`community.html`: the project URL and the **publishable** key
(`sb_publishable_...`, or the legacy `anon` JWT on older-style projects).
Retrieve them with:

```
supabase projects api-keys --project-ref <your-project-ref>
```

Copy only the `default` / `sb_publishable_...` row (or `anon` on legacy
projects). The `service_role` / `sb_secret_...` row is server-only and is
never used anywhere in this milestone's code.

## 2. Apply the schema

```
supabase link --project-ref <your-project-ref>
supabase db push
```

This applies, in order:
- `supabase/migrations/20260813093111_community_backend_schema.sql` —
  tables, RLS, the immutability trigger, the `publish_release()` function,
  and every `GRANT`.
- `supabase/migrations/20260813093810_community_backend_advisor_fixes.sql`
  — the follow-up fixes for the Security/Performance Advisor findings
  (see `COMMUNITY_BACKEND_SPEC.md` § 8). Both migrations are required;
  apply them in filename order (which `supabase db push` already does).

Verify cleanly:

```
supabase db advisors --linked --type all --level info
```

Expect zero `SECURITY`/`PERFORMANCE` findings above `INFO`. The
`unused_index` `INFO` notices on a fresh project are expected and
harmless (see spec § 8) — they resolve themselves once real query
traffic exists.

## 3. Local Auth configuration for testing

New Supabase projects default to `enable_confirmations = true` (email
confirmation required before a session is issued on sign-up), which is
correct for production but inconvenient for local iteration. This
project's `supabase/config.toml` sets local-dev-friendly Auth defaults;
push them to your linked project with:

```
supabase config push --experimental
```

**Only do this against a project you're using for development/testing.**
For a real production deployment, leave (or explicitly re-enable) email
confirmation, and make sure `community.html`'s sign-up flow surfaces the
`COMMUNITY_EMAIL_CONFIRMATION_REQUIRED` message correctly (it already
does — this is the code path exercised whenever a sign-up response has no
`access_token`).

## 4. Deploy the Edge Function

```
supabase functions deploy publish-release --no-verify-jwt
```

`--no-verify-jwt` is used because the function performs its own
`Authorization` header check and returns a structured
`COMMUNITY_AUTH_REQUIRED` JSON body on failure, rather than relying on
the platform gateway's generic JWT-verification 401. The function itself
never uses the service-role key — see `COMMUNITY_BACKEND_SPEC.md` § 9.

Sanity-check the deployment (should return 401 with a structured body,
not a network error):

```
curl -s -X POST 'https://<project-ref>.supabase.co/functions/v1/publish-release' \
  -H 'apikey: <publishable-key>' \
  -H 'Content-Type: application/json' \
  -d '{"releaseText":"{}"}'
```

## 5. Configure the two client files

Both `index.html` and `community.html` have an inline
`COMMUNITY_BACKEND_CONFIG` object near the top of their `<script>` block:

```js
const COMMUNITY_BACKEND_CONFIG = {
  enabled: true,
  supabaseUrl: 'https://<project-ref>.supabase.co',
  publishableKey: 'sb_publishable_...'
};
```

Edit both files with your project's URL and publishable key. There is no
build step or environment-variable substitution — this project is
zero-build by design, so this is a plain find-and-edit. Setting
`enabled: false` (or leaving `supabaseUrl`/`publishableKey` empty) makes
every Community feature fail gracefully with `COMMUNITY_NOT_CONFIGURED`
without affecting any purely local Runtime feature — the Runtime never
depends on the backend being present to boot or play.

## 6. Production topology

Deploy `community.html` and `index.html` to **separate origins** — this
is a hard recommendation, not a suggestion, since the entire security
model of this milestone rests on the Runtime never being able to observe
a Community Auth token, and same-origin `localStorage`/DOM access would
undermine that if the two files shared an origin. A typical setup:

```
community.example.com  → community.html  (Community Portal, owns Auth)
play.example.com       → index.html      (Runtime, anonymous Community consumer)
```

For local testing, opening each file directly via `file://` already
gives you origin-level isolation in most browsers (each `file://` URL is
treated as a unique origin) — this is why the live testing for this
milestone was conducted with both files open as separate `file://` tabs
without any special server setup.

## 7. Row Level Security is not optional

Every table this milestone introduces has RLS enabled with an explicit
policy for every command it needs to support (see
`COMMUNITY_BACKEND_SPEC.md` § 5 for the full matrix). If you extend this
schema, keep doing this: add `ENABLE ROW LEVEL SECURITY` and explicit
policies for every new table before ever `GRANT`ing it to `anon`/
`authenticated`, and re-run `supabase db advisors --linked` after every
schema change to catch drift immediately rather than discovering it in
production.

## 8. Rolling back / undoing local-dev Auth changes

If you ran step 3 above against a project you now want to restore to
production-safe Auth defaults (email confirmation required, restrictive
redirect URLs), edit `supabase/config.toml`'s `[auth]`/`[auth.email]`
sections back to your intended values and run `supabase config push
--experimental` again — this pushes the file's current contents to the
linked project outright; there is no separate "undo" command.
