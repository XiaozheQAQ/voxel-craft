# Voxel Craft — PUBLIC_BETA_DEPLOYMENT.md

```
Runtime 0.2.0-dev -- NOT declared stable. This is a Beta deployment guide.
```

**Live as of this writing** — two real Cloudflare Pages deployments,
verified end-to-end over real HTTPS:

```
Community: https://voxel-craft-community.pages.dev
Runtime:   https://voxel-craft-play.pages.dev
```

## 1. Architecture

```
voxel-craft-community.pages.dev     voxel-craft-play.pages.dev
  community.html (as index.html)      index.html
  Supabase Auth (session lives here)  Runtime, Mod execution
  Explore / Publish / Profiles        NO Auth session, ever
         |                                    ^
         |  "Open in Runtime" / "Remix"       |
         `--- ?communityRelease=<uuid> -------'
              (release id only -- never a token)
```

**Hard invariant, unchanged and now live-verified on real production
origins (not `file://`, not two localhost ports)**: the authenticated
Community origin and the Mod-executing Runtime origin are two genuinely
different Cloudflare Pages projects/origins. See § 7 for the exact
proof performed.

## 2. Deployment artifacts — isolation is a build step, not a convention

`build-deploy.sh` (Node-free shell script) produces two disjoint output
directories, each containing only the one page that origin is allowed
to serve:

```
dist-community/index.html   <- copy of community.html
dist-community/_headers

dist-play/index.html        <- copy of index.html
dist-play/_headers
```

Verified after every build: `dist-community/index.html` contains zero
Runtime-execution markers (`WorkshopController`/`captureDefinition`) and
`dist-play/index.html` contains zero Community-Auth markers
(`authSignIn`/`authSignUp`); each output is byte-identical to its
source file (`diff -q` clean). Re-verified on the **live deployed**
origins too (§ 8) — not just the local build output.

## 3. Configuration (as actually deployed)

`community.html` → `COMMUNITY_BACKEND_CONFIG`:
```js
{
  enabled: true,
  supabaseUrl: 'https://gdfenseaqjhmaspsfpnq.supabase.co',
  publishableKey: 'sb_publishable_...',
  runtimeBaseUrl: 'https://voxel-craft-play.pages.dev/'
}
```

`index.html` → `COMMUNITY_BACKEND_CONFIG`:
```js
{ enabled: true, supabaseUrl: 'https://gdfenseaqjhmaspsfpnq.supabase.co', publishableKey: 'sb_publishable_...' }
```

No `service_role`/`sb_secret_...`/DB password/token in either file —
re-confirmed by secret scan before this deploy (see § 10).

## 4. Cloudflare Pages configuration (as actually created)

Created via `wrangler pages project create` (Direct Upload, no Git
integration configured yet — see § 11):

| Project | Production branch | Deploy source | Live URL |
|---|---|---|---|
| `voxel-craft-community` | `main` | `dist-community/` | `https://voxel-craft-community.pages.dev` |
| `voxel-craft-play` | `main` | `dist-play/` | `https://voxel-craft-play.pages.dev` |

No framework preset used (Direct Upload of static files). Deployed via:
```
wrangler pages deploy dist-play --project-name voxel-craft-play --branch main
wrangler pages deploy dist-community --project-name voxel-craft-community --branch main
```
(Runtime deployed first so Community's `runtimeBaseUrl` could point at
its real, final URL before Community's own deploy — Cloudflare Pages
project names, and therefore their `*.pages.dev` URLs, are deterministic
at creation time, so this ordering was a one-pass operation, not
trial-and-error.)

## 5. Supabase Auth URL configuration — applied

```
Site URL:                 https://voxel-craft-community.pages.dev
Additional Redirect URLs: https://voxel-craft-community.pages.dev,
                           https://voxel-craft-community.pages.dev/*
```
Applied via `supabase/config.toml` + `supabase config push
--experimental`; diff confirmed only these two values changed (from
local-dev placeholders), and the Play origin was never added anywhere
in this config.

## 6. CORS / network

Unchanged from the prior milestone's finding: Supabase's REST API and
the `publish-release` Edge Function are origin-agnostic by design
(RLS-based security, not CORS-based). Re-confirmed live from the real
`voxel-craft-play.pages.dev` origin: the one Supabase request the
Runtime makes returns `Access-Control-Allow-Origin:
https://voxel-craft-play.pages.dev` and succeeds with `200`.

## 7. Production security proof (release blocker) — passed

Performed via DevTools against the two **real, live** origins after a
genuine "Open in Runtime" click (not simulated):

- **Community origin (`voxel-craft-community.pages.dev`) storage**:
  contains the Supabase Auth session after sign-in. Expected.
- **Runtime origin (`voxel-craft-play.pages.dev`) storage**: `0`
  `localStorage` keys of any kind (enumerated, not spot-checked) after
  the full handoff.
- **Runtime URL**: `https://voxel-craft-play.pages.dev/?communityRelease=<uuid>`
  — no token, nothing else.
- **Runtime network**: its one Supabase request (`community_releases`
  fetch) carries **no `Authorization` header** — confirmed by reading
  the actual raw request headers (`apikey` present, `Authorization`
  absent, `sec-fetch-site: cross-site`).
- **Remote execution**: the fetched Release showed the metadata-only
  preview ("Community code execution is not available yet…"), `Mods
  (0)` active, no Open/Remix affordance — Trust Gate held identically
  on real production origins.

## 8. Deployment isolation test — passed

```
voxel-craft-community.pages.dev/            -> Community Portal (title "...Community Portal")
voxel-craft-community.pages.dev/runtime.html -> STILL Community Portal (Cloudflare Pages'
                                                 default single-page fallback serves the one
                                                 index.html for any unmatched path -- confirmed
                                                 by inspecting the actual response content,
                                                 not just the 200 status)
voxel-craft-play.pages.dev/                  -> Runtime (title "Voxel Craft")
voxel-craft-play.pages.dev/community.html    -> STILL Runtime, same fallback reasoning
```
No path on either origin ever serves the other origin's page content.
`grep`-level checks on both live responses confirm zero cross-markers
(0 Runtime strings on the Community origin, 0 Auth-form strings on the
Runtime origin).

## 9. Live smoke test — real HTTPS, all items run

| # | Check | Result |
|---|---|---|
| A | Both URLs HTTPS | ✅ `200` over `https://` for both |
| B | Community loads | ✅ |
| C | Explore works | ✅ |
| D | Search works | ✅ (live `水晶` search, correct results) |
| E | Sign-in works | ✅ (live, against real Supabase project, post-Auth-URL-update) |
| F | Publish works | ✅ (live publish, real `remoteId` returned) |
| G | Release detail works | ✅ |
| H | Open in Runtime goes to the OTHER origin | ✅ (`voxel-craft-community` → new tab on `voxel-craft-play`) |
| I | Only `communityRelease` UUID crosses | ✅ (URL inspected directly) |
| J | Runtime storage has no Community Auth session | ✅ (0 keys, enumerated) |
| K | Runtime remote code remains blocked | ✅ (`Mods (0)`, metadata-only) |
| L | `.vrelease` download works | ✅ (correct format, no internal markers) |
| M | zh-CN works | ✅ (entire flow above run in zh-CN) |
| N | en-US works | ✅ (language switch verified live on the Release detail page) |

Test fixtures created for this pass (`Cloudflare Pages Live Test`, an
earlier `Beta Deploy CORS Test`) were withdrawn (`is_published:false`)
after verification — not deleted, matching this project's
immutable-once-published design.

## 10. Beta backend decision

The linked Supabase project (`voxel-craft-community-dev`,
`gdfenseaqjhmaspsfpnq`) continues to back this Beta. **This is
explicitly the Public Beta backend, not a final production backend** —
per this milestone's instruction, no second project was created in this
timebox. Verified before this deployment: no `service_role`/
`sb_secret_...`/DB password anywhere in `index.html`, `community.html`,
`supabase/`, `_headers`, or this document (secret scan clean); Auth
settings updated to the real Community origin (§ 5); stale local-dev
test fixtures from prior milestones remain in the database
(immutable-once-published) but most are already withdrawn or clearly
labeled as test data by title.

## 11. Known limitations / next steps

- **No Git integration configured on either Pages project** — deploys
  are currently manual (`wrangler pages deploy`), matching this
  project's "no CI redesign" constraint. Connecting each project to
  this repo (production branch `main`, per-project output directory)
  is a future, non-blocking improvement — document, don't build,
  this pass.
- No custom domain — `*.pages.dev` URLs are the real, live, HTTPS
  production URLs for this Beta.
- No CSP — deferred, unchanged reasoning (would require restructuring
  the inline-script Runtime).
- Dev Supabase project remains the backend (§ 10) — provisioning a real
  production project is an explicit future owner decision; steps
  documented in `COMMUNITY_BACKEND_SETUP.md`.
- Rollback: redeploy the previous known-good commit's build output via
  `wrangler pages deploy` to either project; known-good tag
  `runtime-0.2-community-trust-gate`. No destructive DB migration
  involved.
