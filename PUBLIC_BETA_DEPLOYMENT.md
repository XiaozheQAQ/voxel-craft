# Voxel Craft — PUBLIC_BETA_DEPLOYMENT.md

```
Runtime 0.2.0-dev -- NOT declared stable. This is a Beta deployment guide.
```

Makes the existing Community Beta (backend + Discovery + Trust Gate,
all already complete) actually deployable on the public Internet with a
real, separate-origin authenticated Community Portal and Mod Runtime.
This document does not change product scope — no new features, no real
sandbox. See `TRUST_MODEL.md` for why remote Mod execution stays
blocked regardless of deployment topology.

## 1. Architecture

```
https://community.<domain>          https://play.<domain>
  community.html                      index.html
  Supabase Auth (session lives here)  Runtime, Mod execution
  Explore / Publish / Profiles        NO Auth session, ever
         |                                    ^
         |  "Open in Runtime" / "Remix"       |
         `--- ?communityRelease=<uuid> -------'
              (release id only -- never a token)
```

**Hard invariant, unchanged from prior milestones**: the authenticated
Community origin and the Mod-executing Runtime origin must be two
different origins. A different filename or `localStorage` key is not
isolation — see `COMMUNITY_BACKEND_SPEC.md` § 1 and
`COMMUNITY_DISCOVERY_SPEC.md` § 2 for the concrete, previously-observed
proof of why (opening both files via `file://` from the same directory
shares one origin and leaks the session — `community.html` now
code-enforces Auth-disabled under `file:`, but a real deployment should
never rely on that fallback).

## 2. Configuration

Two plain constants per file, both already present, no build step, no
env-var substitution:

**`community.html`** (`COMMUNITY_BACKEND_CONFIG`, near the top of the
`<script>` block):
```js
const COMMUNITY_BACKEND_CONFIG = {
  enabled: true,
  supabaseUrl: 'https://<project-ref>.supabase.co',
  publishableKey: 'sb_publishable_...',
  runtimeBaseUrl: 'https://play.<domain>/'   // <-- MUST be the Runtime's real absolute origin before deploy
};
```

**`index.html`** (`COMMUNITY_BACKEND_CONFIG`, near
`runtime.community`):
```js
const COMMUNITY_BACKEND_CONFIG = {
  enabled: true,
  supabaseUrl: 'https://<project-ref>.supabase.co',
  publishableKey: 'sb_publishable_...'
};
```

**Rules (unchanged, re-verified this milestone):**
- Only the project URL and the **publishable** key (`sb_publishable_...`,
  client-safe) ever appear in either file.
- `service_role`/`sb_secret_...`/DB password/any Auth token: **never**
  in either file, never in this repo, never in `git log`.
- `runtimeBaseUrl` in `community.html` is the one value that is
  currently a **local-dev-only default** (`'index.html'`, a relative
  path assuming both files share a directory) and **must be edited to
  the Runtime's real absolute URL before a real deployment** — left
  unedited, it silently resolves to the Portal's own origin, which
  looks like it works but defeats the separation. This is flagged
  in-file with a `DEPLOYMENT:` comment.

Verify before every deploy:
```
grep -c "sb_secret_\|service_role" community.html index.html   # must be 0
```

## 3. Hosting

Both files are static, dependency-free, no build step — deployable to
**any** static host. This project intentionally has no build pipeline
and this milestone does not add one. Two independent static
deployments are required (one per origin); which host is used for each
is not prescribed here — pick any static host that supports custom
domains and (ideally) a `_headers`-style config file, or translate the
included `_headers` file to your host's native header syntax.

**Minimum per deployment:**
- `community.<domain>` deployment serves `community.html` (as its
  index/entry document) and, if the host requires an `_headers`-style
  file to apply security headers, this repo's `_headers` file.
- `play.<domain>` deployment serves `index.html` similarly.
- **Do not deploy `community.html` to the `play.<domain>` origin.** Its
  mere presence there is not itself unsafe (it never holds a session
  until someone signs in through it), but publishing it there invites
  a player to sign in on the wrong origin and re-creates exactly the
  risk the whole architecture exists to prevent. Keep the two
  deployments' file sets disjoint if your host allows it; at minimum,
  never link to `play.<domain>/community.html` from anywhere.

## 4. Supabase Auth URL configuration

**Community origin only** — never add the Runtime origin as an Auth
redirect URL; it never performs Auth in the first place.

Required values (replace `<domain>` with your real domain before
applying):

```
Site URL:              https://community.<domain>
Additional Redirect URLs:  https://community.<domain>/**
```

Applied via `supabase/config.toml`'s `[auth]` section
(`site_url`/`additional_redirect_urls`) + `supabase config push
--experimental`, the same mechanism used earlier in this project for
local-dev defaults (see `COMMUNITY_BACKEND_SETUP.md` § 3). **Not applied
by this milestone** — no real domain exists yet to push (see § 12
below); this section documents the exact values to set once one does.

## 5. CORS / network — verified live this milestone

Supabase's Data API (PostgREST) and this project's own `publish-release`
Edge Function are **origin-agnostic by design** (security is RLS-based,
not CORS-based) — confirmed, not assumed:

- REST API: `curl` with `Origin: http://localhost:4173` →
  `Access-Control-Allow-Origin: http://localhost:4173` (reflects the
  requesting origin).
- Edge Function: `CORS_HEADERS` in `supabase/functions/publish-release/index.ts`
  already sets `Access-Control-Allow-Origin: *` explicitly.

**Live cross-origin test performed** (two real, distinct local HTTP
origins — `http://localhost:4173` as a stand-in Community origin,
`http://localhost:4174` as a stand-in Runtime origin — the closest
faithful reproduction of the production topology available without a
real domain):
- Anonymous Explore from `:4173`: works.
- Sign-in + publish from `:4173` against the live Supabase project:
  works (`remoteId` returned, `200`).
- Remote Release fetch from `:4174` (Runtime): works, **and inspecting
  the actual request headers showed no `Authorization` header at all**
  — only the client-safe `apikey` header, `origin: http://localhost:4174`,
  `sec-fetch-site: cross-site` (browser-confirmed cross-origin).

No CORS weakening was needed or performed globally — the existing
configuration already supports this topology correctly.

## 6. Community → Runtime handoff

Unchanged from the Discovery/Trust-Gate milestones, re-verified here
under genuine cross-origin conditions: `openInRuntime(releaseId)` opens
`${runtimeBaseUrl}?communityRelease=<uuid>` — the release id is the
**only** thing that crosses the boundary. Verified live (§ 11): the
Runtime tab's `localStorage` was completely empty, its URL contained no
token, and its one Supabase request carried no bearer token. The
Runtime's Trust Gate (`TRUST_MODEL.md`) still applies identically
regardless of origin topology — a fetched Release always gets the
metadata-only preview, never execution.

## 7. Security headers

`_headers` (repo root, Netlify/Cloudflare Pages syntax — zero build
step, auto-detected by both hosts) sets, on every path:
```
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=()
```
Deploy this same file to **both** origins.

**No CSP shipped, deliberately, not an oversight**: this Runtime is one
inline `<script>` per file with no external script sources (by design —
see `RUNTIME_ARCHITECTURE.md`). A CSP strict enough to be worth shipping
(blocking `'unsafe-inline'`) would break the Runtime's own code and its
Mod-execution model outright. Doing this properly requires restructuring
both files into external script files first — explicitly deferred, not
silently skipped; tracked as a known limitation (§ 15).

If your host doesn't support a `_headers` file, translate the three
headers into its native config (e.g. a Vercel `headers` array in
`vercel.json`, an Nginx `add_header` block, a CloudFront response-headers
policy) — the three headers above have no host-specific behavior.

## 8. Cache policy

`_headers` sets `Cache-Control: no-cache` on both `index.html` and
`community.html` specifically — this project has no separate
long-lived built-asset tier (no bundler, no hashed filenames), so the
one thing that matters is never letting a stale cached HTML file keep
serving an old Runtime version (e.g. a pre-Trust-Gate build) after a
redeploy. `no-cache` still allows the browser to revalidate cheaply
(304s), it just prevents silently serving a stale copy without asking.

## 9. Production error UX — already handled, re-verified

All required cases already produce a structured, localized message with
a **Retry** button rather than a blank page or raw error, unchanged from
prior milestones:
- Backend unavailable: `COMMUNITY_NETWORK_ERROR` → retry button
  (Explore/Release/Profile all have one).
- Invalid/withdrawn Release id: `COMMUNITY_RELEASE_NOT_FOUND` (RLS makes
  the two indistinguishable to an anonymous caller, documented as such).
- Auth failure: `COMMUNITY_AUTH_FAILED`, shown inline on the sign-in
  form.
- Publish failure: `COMMUNITY_PUBLISH_FAILED`/`COMMUNITY_RELEASE_INVALID`,
  shown inline on the Publish tab.
No new logging platform was built or is needed for this milestone —
errors are user-facing only, as scoped.

## 10. Smoke test checklist

Run after every deploy. All items below were executed live this
milestone (against `http://localhost:4173`/`:4174` as origin
stand-ins, since no real domain exists yet — re-run against the real
domains once chosen):

| # | Check | Result this milestone |
|---|---|---|
| A | Community page loads over HTTPS | Deferred to real domain — local HTTP stand-in loaded correctly |
| B | Anonymous Explore works | ✅ |
| C | Search works | ✅ (reused from Discovery milestone, unaffected) |
| D | Login works | ✅ (cross-origin, live sign-in against real Supabase project) |
| E | Publish works | ✅ (live publish from `:4173`, `remoteId` returned) |
| F | Release detail works | ✅ |
| G | Open in Runtime crosses to separate origin | ✅ (`:4173` → `:4174`, confirmed via `location.origin`) |
| H | Runtime receives only release id | ✅ (URL inspected: only `?communityRelease=<uuid>`) |
| I | Remote source remains blocked | ✅ (metadata-only preview, "模组 (0)", no Open/Remix affordance) |
| J | Download .vrelease works | ✅ (reused from Trust Gate milestone, unaffected) |
| K | Local Runtime still boots | ✅ (`file://index.html?dev=1`, i18n/VMP audits clean) |
| L | zh-CN/en-US both usable | ✅ (this session's testing was conducted in zh-CN throughout; en-US regression already established in prior milestones and unaffected by this one) |

## 11. Production security check — release blocker, verified

Explicit DevTools verification, this milestone, using two genuinely
distinct origins (not `file://`, not two paths on one origin):

- **Community origin (`:4173`) storage**: contains the Supabase Auth
  session (`voxelcraft.community.portal.session.v1` present). Expected
  and correct.
- **Runtime origin (`:4174`) storage**: `localStorage` **completely
  empty** — zero keys of any kind, confirmed by enumeration, not just a
  spot-check for the session key.
- **Runtime URL**: `http://localhost:4174/index.html?communityRelease=<uuid>`
  — no `access_token`, no `refresh_token`, nothing beyond the release id.
- **Runtime network**: the one Supabase request it made carried no
  `Authorization` header — inspected the actual raw request headers
  (`apikey` present, `Authorization` absent), not inferred from
  behavior.

**This is the release-blocker check called for in this milestone's
brief, and it passed.**

## 12. Environment separation — explicit decision required before real launch

The linked Supabase project is named `voxel-craft-community-dev` — **it
is a development project**, not a production one. This document does
not relabel it as production, per this milestone's explicit instruction.

**Option A — Beta temporarily uses the current dev project.** Fastest
path to a public Beta; acceptable for a genuinely early/soft Beta where
data loss or a project reset is tolerable and clearly communicated.
Nothing further to do beyond this document's steps.

**Option B — provision a real production Supabase project before public
launch.** Recommended before any announced/linked-from-marketing launch.
Not performed automatically this milestone (would exceed the timebox
and is a decision only the project owner should make — creating a new
paid/production-tier project, migrating data, and cutting over Auth
users are all consequential, hard-to-cheaply-reverse actions). Exact
steps when ready:
1. `supabase projects create <name> --org-id <org> --db-password <...>`
   (interactively, never scripted with a password in a repo/chat).
2. `supabase link --project-ref <new-ref>`.
3. `supabase db push` (applies every migration in `supabase/migrations/`
   in order — schema, advisor fixes, and the Discovery read-model view,
   all already written and tested).
4. Run `supabase db advisors --linked --type all --level info` on the
   new project and confirm clean, exactly as done for the dev project.
5. Update `COMMUNITY_BACKEND_CONFIG.supabaseUrl`/`publishableKey` in
   **both** `community.html` and `index.html` to the new project's
   values (`supabase projects api-keys --project-ref <new-ref>` — copy
   only the `sb_publishable_...` row, never `sb_secret_...`).
6. Set Auth Site URL/Redirect URLs per § 4 on the **new** project.
7. Re-run the full smoke test (§ 10) against the new project before
   announcing.

## 13. Rollback

Fastest safe rollback: redeploy the previous known-good commit/tag to
both origins.

```
Known-good tag: runtime-0.2-community-trust-gate
```

No destructive database migration is required for this milestone —
nothing in `supabase/migrations/` was added or changed here, so
rolling back the deployed static files alone is sufficient; the backend
schema is unaffected either way.

## 14. Known limitations / deferred

- No CSP — deferred, requires restructuring both files into external
  scripts first (§ 7).
- No real Supabase production project provisioned — Option A/B decision
  in § 12 is left to the project owner.
- Smoke test (§ 10) was run against local-HTTP-origin stand-ins, not a
  real deployed domain — re-run against real domains once chosen, item
  A in particular (HTTPS) cannot be verified without one.
- No CI/CD pipeline changes — deployment remains a manual "push these
  two static file sets to their respective hosts" process, matching
  this milestone's "no CI redesign" constraint.
- No analytics/monitoring platform — errors are user-facing only (§ 9).
