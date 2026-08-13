# Voxel Craft — COMMUNITY_BACKEND_SPEC.md (Runtime 0.2 — Community Backend Foundation)

```
Runtime 0.2 — Community Backend Foundation
API 1 — frozen, unaffected
VMP 1 — frozen, unaffected
Voxel Game Package Format 1 — frozen, unaffected
Voxel Creation Workspace Format 1 — one additive, backward-compatible field
Voxel Community Release Format 1 — one additive, backward-compatible field
```

This milestone persists Community Releases remotely using a real, live
Supabase project, while preserving the Runtime's core security boundary
and offline-first local workflows. It builds directly on
`COMMUNITY_RELEASE_SPEC.md` (the local `.vrelease` format) — this document
does not redefine that format, only extends it minimally and adds a
backend behind it.

## 1. The one hard rule this milestone is organized around

**`index.html` (the Runtime) never holds an authenticated Community Auth
session.** Mods execute as trusted, same-realm JavaScript inside
`index.html` (see `RUNTIME_ARCHITECTURE.md`'s Trust model — there is no
sandbox). Any Auth token present in that page could be read or misused by
a Mod. Therefore:

- `index.html` = Mod execution Runtime = **anonymous** Community consumer
  only. It never signs in, never stores a session, never sends an
  `Authorization: Bearer <token>` header to the backend. Its only two new
  Community capabilities (`runtime.community.getRelease`/`getChildren`,
  plus an optional `getProfile`) are anonymous, public reads.
- A brand-new, separate file, **`community.html`** (the "Community
  Portal"), owns identity/Auth: sign-up, sign-in, profile editing,
  publishing, and release management. It **never executes `.vmod` source
  or evaluates untrusted JS** — Mod source is only ever displayed as
  read-only text (`textContent`, never `innerHTML`, never `eval`/`new
  Function`, never a dynamically-created `<script>` tag).
- **Hard requirement, not a recommendation: `community.html` MUST be
  deployed on a different origin from `index.html` in any deployment
  that also serves untrusted/third-party Mods.** Example:
  `community.example.com` (authenticated Portal) vs. `play.example.com`
  (Runtime + untrusted Mods). This is the actual security boundary —
  everything else in this section (separate file, separate
  `localStorage` key, no token in URL/postMessage) is defense-in-depth
  *on top of* origin separation, never a substitute for it. **A
  different filename and a different `localStorage` key are NOT security
  isolation by themselves**: if the two pages ever end up served from the
  same origin, a Mod running inside `index.html` can read any
  `localStorage` key on that origin (including a Community session
  token, however it's named) and call any authenticated browser API
  available to that origin — same-realm JavaScript has no partition
  between "the Runtime's own storage" and "some other page's storage" the
  moment they share an origin. Same-origin proximity between the two
  pages must never be relied upon for security anywhere this design is
  deployed.
- Access/refresh tokens are never transferred between the two pages by
  URL, `postMessage`, query parameter, clipboard, or shared `localStorage`
  key. `community.html` persists its own session under a Portal-specific
  `localStorage` key (`voxelcraft.community.portal.session.v1`) purely so
  a page reload doesn't sign the user out — this key is never read,
  written, or referenced anywhere in `index.html`.

## 2. What actually shipped

| Component | File | Role |
|---|---|---|
| Schema + RLS + trigger + publish RPC | `supabase/migrations/*.sql` | Source of truth for stored data and every authorization rule |
| `publish-release` Edge Function | `supabase/functions/publish-release/index.ts` | Structural validation + calls `publish_release()` as the caller |
| Community Portal | `community.html` | Auth, profile, publish, manage releases, browse by id |
| Runtime remote client | `index.html` (`runtime.community.getRelease`/`getChildren`/`getProfile`) | Anonymous fetch → reuse the existing Open Release pipeline |

No marketplace/discovery/browsing UI, no likes/comments/ratings, no
moderation, no recommendations — explicitly out of scope (see § 10).

## 3. Data model

### `profiles`
`user_id` (PK, `references auth.users(id)`), `display_name` (1–60 chars,
required), `bio` (≤500 chars, optional), `avatar_url` (≤500 chars,
optional), `created_at`, `updated_at`. Publicly readable; only the owning
user (`auth.uid() = user_id`) may insert/update their own row. Note this
table deliberately does **not** store email — `auth.users` is the sole
identity source; `profiles` is display metadata only.

### `community_releases`
The authoritative server record of one published Release.

- `id` (PK, server-generated `uuid`) — the **Community publication
  identity**. Distinct from, and never conflated with, the local
  `.vrelease` `releaseId`.
- `client_release_id` (`text`) — the local `.vrelease` `releaseId` at
  publish time. Informational only, not unique, not authoritative.
- `creator_id` (`references auth.users(id)`) — ownership, always
  `auth.uid()` at insert time, never a client-supplied value.
- `title`, `description`, `author_display_name`, `language`,
  `release_note` — presentation fields, length-capped to match
  `COMMUNITY_RELEASE_SPEC.md`'s own limits.
- `generation` (`integer`, computed server-side, never trusted from the
  client) and `parent_release_id` (`references community_releases(id)`).
- `runtime_version`/`api_version`/`vmp_version`/
  `game_package_format_version`/`community_release_format_version` —
  informational version stamps from the source `.vrelease`.
- `client_content_hash` — the non-cryptographic fingerprint from
  `COMMUNITY_RELEASE_SPEC.md` § 9, stored as-is, never re-derived or
  trusted as an authenticity signal server-side either.
- `snapshot_text` — the **exact, verbatim** published `.vrelease` JSON
  payload. This is the source of truth for exact reconstruction; see
  § 4 "Snapshot + normalized-fields duality".
- `is_published` (`boolean`) — the only column a creator may ever change
  after creation.
- `created_at`, `published_at`, `updated_at`.

### `community_release_mods` / `community_release_tags`
A searchable index over `snapshot_text`'s `mods[]`/`metadata.tags[]` —
`(release_id, position) → {manifest_id, manifest_version, manifest_name}`
and `(release_id, tag)`. Populated atomically alongside the release row
by `publish_release()`. Never an alternate source of truth: if a future
reader needs the exact original content, it reads `snapshot_text`, not
these tables.

## 4. Snapshot + normalized-fields duality

`snapshot_text` preserves the exact original `.vrelease` JSON so a
Release can always be reconstructed byte-for-byte (this is what
`runtime.community.getRelease()` returns — literally
`JSON.parse(row.snapshot_text)`, nothing re-derived). The normalized
columns/mods/tags exist purely as a discovery/index layer. The two are
never allowed to drift into being treated as interchangeable sources of
truth — the code that builds a Release out of a fetched row (Runtime's
`communityGetRelease`) reads only `snapshot_text`.

## 5. Row Level Security — full policy matrix

RLS is enabled on all four tables; every rule below is enforced by
Postgres itself, not application code.

| Table | Command | Role | Rule |
|---|---|---|---|
| `profiles` | SELECT | any | `true` (public) |
| `profiles` | INSERT | authenticated | `auth.uid() = user_id` |
| `profiles` | UPDATE | authenticated | `auth.uid() = user_id` (both USING and WITH CHECK) |
| `community_releases` | SELECT | any | `is_published = true OR auth.uid() = creator_id` |
| `community_releases` | INSERT | authenticated | `auth.uid() = creator_id` |
| `community_releases` | UPDATE | authenticated | `auth.uid() = creator_id` (both USING and WITH CHECK) — see § 6 for what's actually changeable |
| `community_release_mods` | SELECT | any | parent release visible (published OR own) |
| `community_release_mods` | INSERT | authenticated | parent release owned by caller |
| `community_release_tags` | SELECT | any | parent release visible (published OR own) |
| `community_release_tags` | INSERT | authenticated | parent release owned by caller |

No DELETE policy exists on any table (RLS denies by default when no
policy exists for a command) — nothing in this milestone hard-deletes a
release or a profile.

`auth.uid()` calls in every policy are wrapped as `(select auth.uid())`
per Supabase's `auth_rls_initplan` performance advisory (evaluated once
per query via an InitPlan, not once per row) — see § 8.

Explicit `GRANT`s (`select`/`insert`/`update` to `anon`/`authenticated`
as appropriate) exist on every table: as of this project's creation,
Supabase Cloud's default `auto_expose_new_tables` behavior no longer
auto-exposes new tables to the Data API — RLS alone is not sufficient to
make a table reachable via PostgREST, so relying on RLS without the
matching GRANTs would silently produce 401s. This was verified live
against the actual linked project before writing the migration, not
assumed from prior/possibly-stale knowledge of Supabase defaults.

## 6. Immutability

A `BEFORE UPDATE` trigger (`enforce_release_immutability`) on
`community_releases` compares every column except `is_published` and
`updated_at` between `OLD` and `NEW`, and raises if any of them differ.
This is defense-in-depth layered under the RLS UPDATE policy (§ 5) — even
the owning creator, going through any client, cannot edit a published
Release's content; the only legitimate mutation post-creation is
withdrawing it (`is_published: true → false`).

## 7. Publishing transaction

`publish_release(...)` is a single `SECURITY INVOKER` Postgres function —
it runs with the **calling user's own privileges**, so every `INSERT`
inside it is still separately subject to the RLS policies in § 5;
`auth.uid() = creator_id` is enforced by Postgres itself on each
statement, not merely by the function's own checks. One function call is
one transaction: if any statement raises, the entire publish rolls back
— there is no way to observe a release row with a missing mod/tag index.

Inside the function:
1. Rejects if `auth.uid()` is null (`COMMUNITY_AUTH_REQUIRED`), if
   structural limits are exceeded (mod count, snapshot size, title
   presence), mirroring — but not replacing — the Edge Function's own
   pre-validation (§ 9).
2. **Server-computes lineage.** If a `p_parent_release_id` is supplied,
   the function looks up that row itself; if it doesn't exist or
   `is_published` isn't `true`, the whole publish is rejected
   (`RELEASE_PARENT_UNAVAILABLE`). `generation` is always
   `parent.generation + 1` (or `0` with no parent) — **never** the
   client-supplied value. Verified live: a publish with a forged
   `provenance.generation: 999` on the client resulted in the server
   recording `generation: 1` (the true `parent.generation + 1`),
   confirming the forged value was silently ignored, not merely
   rejected-with-error.
3. Inserts the release row, then the mod-index rows (from a `jsonb`
   array via `jsonb_array_elements(...) WITH ORDINALITY`), then the tag
   rows, all as part of the same function invocation/transaction.

`SECURITY INVOKER` was chosen deliberately over `SECURITY DEFINER`
(spec's stated preference, § 45 of the originating request) — there was
no need for elevated privilege anywhere in this transaction once RLS
policies exist to permit a user's own inserts; using DEFINER here would
have widened the trusted-code surface for no benefit.

## 8. Security & performance advisor results

Ran via `supabase db advisors --linked --type all --level info` (the
CLI-native equivalent of the Dashboard's Security/Performance Advisor —
same underlying `splinter` lint set) immediately after the initial
schema migration, and again after a follow-up fix migration:

**First pass** — 2 SECURITY WARNs (`function_search_path_mutable` on
`touch_updated_at` and `enforce_release_immutability` — neither function
pinned `search_path`) + 9 PERFORMANCE WARNs (`auth_rls_initplan` — every
RLS policy calling `auth.uid()` directly instead of `(select auth.uid())`)
+ 6 `unused_index` INFO notices.

**Fix migration** (`20260813093810_community_backend_advisor_fixes.sql`):
added `set search_path = public` to both trigger functions, and rewrote
every RLS policy to wrap `auth.uid()` as `(select auth.uid())`.

**Second pass** — all SECURITY and PERFORMANCE WARNs resolved. Only the
6 `unused_index` INFO notices remain, which is expected/harmless: those
indexes (`creator_id`, `parent_release_id`, `published_at`, `language`,
`manifest_id`, `tag`) have no query history to have been "used" against
yet, since this is a brand-new project with only hand-run test data —
they exist for query patterns the Portal/Runtime already issue (my
releases by creator, children by parent, etc.), not speculatively.

## 9. `publish-release` Edge Function

A thin, deliberately narrow-scope Deno function
(`supabase/functions/publish-release/index.ts`) sitting in front of
`publish_release()`:

1. Requires an `Authorization` header (else `COMMUNITY_AUTH_REQUIRED`,
   401). Verified live: an unauthenticated request to the deployed
   function returns exactly this.
2. Structurally validates the raw `.vrelease` JSON string before it ever
   reaches the database: total size ≤2 MiB, mod count ≤32, each mod's
   source ≤256 KiB, `title` present and ≤100 chars, `description`
   ≤2000, `releaseNote` ≤1000, tags ≤8 × ≤32 chars, valid JSON,
   `format === 'voxel-release'`, a supported `formatVersion`, every mod
   entry has both `source` and `manifest.id`. Any violation returns
   `COMMUNITY_RELEASE_INVALID` (422) with a specific message, never a raw
   Postgres error.
3. Constructs a Supabase client using **only the publishable
   (`SUPABASE_ANON_KEY`) key**, with the caller's own `Authorization`
   header forwarded into it (`global.headers.Authorization`). This
   function never constructs or uses a service-role/secret-key client —
   every subsequent call (`auth.getUser()`, the `publish_release` RPC)
   therefore runs under the **caller's own RLS context**, identical to
   what a direct authenticated REST/RPC call would get. This was a
   deliberate implementation choice over the platform's newer
   `withSupabase`/`ctx.supabaseAdmin` scaffold helper — that helper's
   admin client bypasses RLS by design, and using an unfamiliar wrapper
   in the one function that handles write authorization was judged not
   worth the reduced auditability; the plain `supabase-js` +
   header-forwarding pattern used here is the well-documented, easily
   verified approach.
4. Reads `provenance.communityParentReleaseId` (see § 11 — **not**
   `provenance.parentReleaseId`, which is a local id, meaningless to this
   backend) as the RPC's parent-lineage input.
5. Maps RPC failures to stable codes (`COMMUNITY_RELEASE_INVALID` for
   `RELEASE_INVALID`/`RELEASE_PARENT_UNAVAILABLE`, `COMMUNITY_AUTH_REQUIRED`
   for auth failures, `COMMUNITY_PUBLISH_FAILED` for anything else) and
   logs the raw Postgres error server-side only — the client never sees
   raw Postgres internals.
6. On success, returns `{remoteId}` — the new `community_releases.id`.

Deployed with `supabase functions deploy publish-release --no-verify-jwt`
(the function does its own `Authorization` check rather than relying on
the platform JWT gate, so it can return the structured
`COMMUNITY_AUTH_REQUIRED` error shape instead of a generic gateway 401).

## 10. Remote/local Release identity model

Two distinct identifiers exist for every published Release, and the code
never conflates them:

- **Local**: `.vrelease`'s own `releaseId` (`release_<uuid>`, minted by
  `generateLocalId('release')` at build time, purely client-side, no
  server involvement). Stored as `client_release_id` server-side —
  informational only.
- **Remote**: `community_releases.id` (server-generated `uuid`, minted
  only when the Portal actually publishes). This is the id a player
  types into the Runtime's "Open Community Release (remote)" field, the
  id shown/copied in the Portal's "My Releases" list, and the id used
  for all server-side lineage (`parent_release_id`).

`runtime.community.getRelease(remoteId)` fetches by the **remote** id and
attaches the fetched row's `id` back onto the reconstructed release
object as `__communityRemoteId` (informational, not part of Release
Format 1 itself) — this is what lets a subsequent Start Remix correctly
carry the remote parent id forward (§ 11).

## 11. Lineage model (Workspace Format 1 + Release Format 1 extensions)

Both formats gain one new, purely additive, optional field —
**`communityParentReleaseId`** — alongside the existing (local)
`parentReleaseId` field each format already had from the prior
milestone. Neither format's version counter changes
(`WORKSPACE_FORMAT_VERSION` and `COMMUNITY_RELEASE_FORMAT_VERSION` both
stay `1`); an older reader simply doesn't recognize the field and treats
it as absent, exactly like every other additive field this Runtime has
shipped.

**Backward-compatibility audit (release-blocker check, re-verified before
merge):** confirmed by code inspection that neither `validateWorkspaceShape()`
nor `validateReleaseShape()` reference `communityParentReleaseId` at all
— an older `.vwork`/`.vrelease` file lacking the field passes validation
identically to one that has it. Every read site
(`resolveReleaseParent()`, `startRemixWorkspace()`, `buildRelease()`)
reads it as `x.communityParentReleaseId || null`, so a genuinely absent
(`undefined`) value is treated exactly like an explicit `null` — no
read site assumes the key exists. The Edge Function's own structural
check likewise only validates the field's *type* when present
(`!== undefined && !== null && typeof !== 'string'` → reject), never its
presence. This confirms the field is safely optional end-to-end and that
no Workspace/Release Format 2 was triggered or is needed.

```
Workspace.provenance: {
  parentWorkspaceId, parentReleaseId, parentTitle, generation, derivedFrom,
  communityParentReleaseId  // NEW — the parent Release's REMOTE id, set only
                             // by Start Remix from a Release that was itself
                             // fetched from the Community backend
}

Release.provenance: {
  parentReleaseId, parentTitle, generation, remixNote,
  communityParentReleaseId  // NEW — propagated from the Workspace's own
                             // provenance at buildRelease() time
}
```

Flow: `communityGetRelease(remoteId)` → `startRemixFromRelease(rel)` sets
`Workspace.provenance.communityParentReleaseId = rel.__communityRemoteId`
→ `buildRelease()`'s `resolveReleaseParent()` reads it back off the
Workspace's provenance and writes it into the new Release's own
`provenance.communityParentReleaseId` → the Portal's publish call sends
the raw `.vrelease` JSON unmodified → the Edge Function reads
`provenance.communityParentReleaseId` as the RPC's parent input → the RPC
re-validates the parent is real/published and computes `generation`
itself.

**A real correctness bug was found and fixed during testing**: the first
implementation of the Edge Function read `provenance.parentReleaseId`
(the *local* id) as the parent-lineage input, which would have silently
failed to link any real remote lineage (a local id is never a valid
`community_releases.id`). Caught by inspecting `buildRelease()`'s actual
output before wiring the Edge Function, fixed by introducing the
distinct `communityParentReleaseId` field end-to-end and updating the
Edge Function to read that field instead. This is documented here as a
design decision, not silently corrected, because it's the kind of
mistake worth flagging for anyone extending this lineage model further.

**Known limitation**: this field is *not* auto-chained across repeated
in-session "Publish Snapshot" clicks the way the local `releaseId` chain
already is (`__lastPublishedRelease`) — a Release's remote id only ever
comes into existence once the Portal actually publishes it (a separate
page, a separate network call the Runtime itself never makes). So B→C
chaining within one Runtime session, without re-fetching/re-remixing
from the backend between publishes, only carries the *local* chain, not
the remote one. To thread the *remote* chain, the primary loop (fetch →
remix → publish) is used at each generation, which is the expected
pattern anyway and is exactly what the flagship test (§ 12) exercises.

## 12. Testing — results

All run live against the actual linked Supabase project
(`gdfenseaqjhmaspsfpnq` / `voxel-craft-community-dev`), a real deployed
Edge Function, and a real `file://` Runtime session — not simulated,
mocked, or "covered by construction" except where explicitly noted.

| Test | Result |
|---|---|
| Migration applies cleanly (`supabase db push`) | **Pass** |
| Security/performance advisor clean after fix migration | **Pass** — 0 WARN/ERROR remaining, only expected `unused_index` INFO noise (§ 8) |
| Sign-up → auto-session (confirmation disabled on dev project) | **Pass** |
| Profile create/read/update via RLS | **Pass** |
| Publish via Portal → Edge Function → RPC → DB | **Pass** — real remote id returned, row present with correct `creator_id`/`generation:0`/`parent_release_id:null` |
| Hostile-content round-trip (`<script>alert(1)</script>`, quotes) through Portal preview | **Pass** — rendered as literal text via `textContent`, no execution, confirmed via accessibility-tree inspection showing the raw tag text |
| Parent-forgery: client sends `generation: 999` | **Pass** — server recorded the true `parent.generation + 1` (`1`), forged value silently ignored |
| User A publishes; User B attempts direct REST `PATCH` to unpublish/retitle A's release | **Pass** — both return HTTP 200 with an empty result array (RLS `USING` clause excluded the row; zero rows affected), verified by re-reading the row afterward (`title`/`is_published` unchanged) |
| User B attempts direct REST `INSERT` forging `creator_id` to a different user | **Pass** — rejected outright, HTTP 403, Postgres `42501` RLS violation |
| Fully anonymous (no `Authorization` header at all) `INSERT`/`PATCH`/Edge-Function-publish attempts | **Pass** — all rejected (RLS violation / zero rows affected / `COMMUNITY_AUTH_REQUIRED` 401) |
| Real `file://` Runtime → `runtime.community.getRelease(remoteId)` → preview → Open | **Pass** — fetched, previewed (reusing the exact same `communityPendingImport`/trust-notice/Open pipeline as a local `.vrelease`), Mod activated |
| A→B remote lineage via the flagship loop (Runtime fetch A → Start Remix → local `.vrelease` B export → Portal publish B) | **Pass** — `B.provenance.communityParentReleaseId` correctly equaled A's real remote id in the exported file; after publishing, the live DB row showed `B.parent_release_id === A.id` and `B.generation === A.generation + 1` |
| Unpublish (real owner, via Portal UI) | **Pass** — row's `is_published` flips to `false`; a subsequent anonymous read of that id returns zero rows |
| i18n catalog parity (`?dev=1` audit) after all Runtime additions | **Pass** — "all locale catalogs are in sync with en-US" |
| Runtime boots and plays fully offline with Community backend never contacted | **Pass by construction** — every `runtime.community` remote method is only invoked from an explicit Workshop button click; nothing runs at load/boot time |
| zh-CN full workflow (sign-up → profile → publish → my-releases → view → unpublish, plus Runtime remote-fetch/open/remix) | **Pass** — the entire live test pass above was conducted with the browser in `zh-CN`, verified via the accessibility-tree snapshots showing correctly localized text throughout |
| 3+ Mod Release round-trip | Covered by construction, not re-run as a dedicated pass — `publish_release()`'s mod-index insert iterates `p_mods` generically (`jsonb_array_elements ... WITH ORDINALITY`) with no mod-count-specific code path, matching the same reasoning `COMMUNITY_RELEASE_SPEC.md`'s own Test H used |
| Secret scan of repo (`index.html`, `community.html`, `supabase/migrations`, `supabase/functions`) for `sb_secret_`/service-role JWT patterns | **Pass** — zero matches; only the publishable key and project URL appear anywhere in committed code |

## 13. Configuration strategy

`COMMUNITY_BACKEND_CONFIG = {enabled, supabaseUrl, publishableKey}` is
the **only** shape Community credentials are ever allowed to take in
either browser-loaded file. `publishableKey` (`sb_publishable_...`, or
the legacy `anon` JWT on older projects) identifies the project to
Supabase's API gateway and grants no privilege by itself — every table
and RPC requires RLS, and `index.html`'s client never sends an
`Authorization` header at all. There is no build step or environment
substitution: both files simply have this object inline, matching every
other configuration constant in this project's zero-build philosophy.
Rotating/relocating the backend means editing this one object in each
file — no secret ever needs to appear in either file for this to work.

See `COMMUNITY_BACKEND_SETUP.md` for the concrete deployment/config
walkthrough.

## 13.1 Superseded by / see also

The Community Discovery & Release Pages milestone (`COMMUNITY_DISCOVERY_SPEC.md`)
builds the public browsing/search/Release-detail/profile UI on top of
everything in this document, adds one new `security_invoker` read-model
view, and adds `index.html`'s only Discovery-related surface (a
`?communityRelease=` handoff hook). Nothing in this document was changed
or superseded by it — this remains the source of truth for the schema,
RLS, publish transaction, and Auth architecture.

## 14. Remaining limitations

- No marketplace/discovery/browsing UI, no likes/ratings/comments, no
  moderation tooling, no recommendations — all explicitly out of scope
  (unchanged from `COMMUNITY_RELEASE_SPEC.md`'s own stop condition, now
  extended to this backend layer too).
- No preview images (unchanged limitation from the prior milestone).
- `contentHash` remains a non-cryptographic fingerprint, stored but never
  treated as an authenticity/security signal server-side either.
- Remote lineage chaining requires the fetch→remix→publish loop each
  generation (§ 11) — repeated in-session local-only publishing does not
  auto-thread the remote parent id.
- Email confirmation is disabled on the dev project (`voxel-craft-community-dev`)
  for local testing convenience (see `COMMUNITY_BACKEND_SETUP.md`); the
  Portal's sign-up flow still handles the confirmation-required case
  gracefully (`COMMUNITY_EMAIL_CONFIRMATION_REQUIRED`) for any project
  where it's enabled, including a real production deployment.
- No rate limiting beyond whatever Supabase's platform defaults provide;
  no abuse/spam mitigation was in scope this milestone.
- `community.html` uses raw `fetch()` against Supabase's REST/Auth/Edge
  Function endpoints rather than the `supabase-js` SDK — see § 9's Edge
  Function note and `COMMUNITY_BACKEND_SETUP.md` for the tradeoff
  rationale (zero supply-chain surface / full auditability on the one
  page that holds live Auth tokens, at the cost of some manual
  boilerplate).
