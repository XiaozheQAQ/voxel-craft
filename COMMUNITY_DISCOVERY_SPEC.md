# Voxel Craft — COMMUNITY_DISCOVERY_SPEC.md (Runtime 0.2 — Community Discovery & Release Pages)

```
Runtime 0.2.0-dev
API 1 — frozen, unaffected
VMP 1 — frozen, unaffected
Voxel Game Package Format 1 — frozen, unaffected
Voxel Creation Workspace Format 1 — frozen, unaffected
Voxel Community Release Format 1 — frozen, unaffected
```

This milestone turns the Community backend (`COMMUNITY_BACKEND_SPEC.md`)
into a usable, anonymous-first public discovery experience inside
`community.html`: browse, search, filter, inspect a Release and its
creator, download it, open it in the Runtime, and start a Remix — all
without signing in. No schema fields changed; one new read-model view
was added. No new client-visible surface was added to `index.html`
beyond a single URL-param handoff.

## 1. Product loop

```
Explore → search/filter → Release detail → understand → download / Open in Runtime
   → play → Start Remix → create derivative → publish later via the existing Portal
```

Deliberately NOT built this milestone (spec's own stop condition):
likes, comments, ratings, follows, notifications, ranking/recommendation
algorithms, a moderation dashboard, payments, a social feed, full graph
visualization, or public Mod sandboxing. `Explore`'s only ordering is
`published_at DESC` — there is no ranking signal anywhere in this
milestone.

## 2. Security invariant — unchanged, and now empirically re-verified

The Community Portal (`community.html`, authenticated) and the Runtime
(`index.html`, Mod execution, anonymous-only) remain two separate files
that must be deployed on two separate **origins** in any real
deployment. This milestone did not weaken that boundary — see
`COMMUNITY_BACKEND_SPEC.md` § 1 for the full hard requirement (a
different filename or `localStorage` key is NOT isolation).

**A concrete finding from this milestone's own testing, corrected into
the docs**: `file://`-opening the two files from the same directory,
in the actual browser used for this project's testing, does **not**
give them separate origins — `location.origin` for both files evaluated
to the literal string `"file://"`, and `community.html`'s live session
(including a real access/refresh token) was directly readable from
`index.html`'s `localStorage`. This is not a defect in either file's own
code (`index.html` never reads that key — verified by inspection), but
it is proof that local `file://` testing must never be treated as
evidence that origin separation is working. See
`COMMUNITY_BACKEND_SETUP.md` § 6 for the corrected guidance and § 10
below for the full no-token-leak test writeup.

## 3. Read model

### `community_release_cards` (new view)

`supabase/migrations/20260813132449_community_discovery_read_model.sql`
adds one `security_invoker` Postgres view aggregating everything one
Release card or detail page needs in a single query: `mod_count`,
`tags[]`, `remix_count`, and `parent_title` are each a scalar/array
subquery over `community_release_mods`/`community_release_tags`/
`community_releases` (self-join for children/parent). `security_invoker`
was verified against current Supabase guidance before writing it (a
plain view runs as its *owner* by default, silently bypassing RLS — the
Supabase Docs' own "Row Level Security" and "Postgres Views: the Hidden
Security Gotcha" pages, both current as of this milestone, name
`security_invoker = true` as the fix). Confirmed live: the Security
Advisor raised no `security_definer_view` finding, and a fully
anonymous, filter-less query against the view returned zero rows with
`is_published = false` (§ 12).

This view adds **no privilege** of its own — every subquery still reads
through the same RLS-protected base tables, so it can never return a
row an equivalent direct query against the base tables couldn't already
return to that caller.

### Query contract

| Operation | Filters | Pagination | Notes |
|---|---|---|---|
| `listReleases({q, language, tag, cursor, limit})` | `is_published=eq.true` (always explicit — see below), optional `q` (ILIKE OR across title/description/author_display_name), optional `language` (`eq.`), optional `tag` (resolved separately, see § 4) | keyset on `(published_at, id)` DESC, page size 20 | Returned fields: every `community_release_cards` column |
| `getReleaseDetail(id)` | `id=eq.`, `is_published=eq.true` | n/a | Two small queries: the card row, then `community_releases.snapshot_text` by id (kept off the card view since it's large and unneeded for lists) |
| `getChildren(id)` | `parent_release_id=eq.`, `is_published=eq.true` | n/a | Direct children only, no recursion |
| `getPublicProfile(id)` | `user_id=eq.` on `profiles` | n/a | `profiles` SELECT policy is `using (true)` — never exposes `auth.users`/email |
| `listProfileReleases(id)` | `creator_id=eq.`, `is_published=eq.true` | n/a | Published only, regardless of viewer |

**Why `is_published=eq.true` is explicit everywhere despite RLS already
enforcing it for anonymous callers** (spec § 29 "do not fetch
unpublished and hide client-side" — this is additive to RLS, not a
substitute): RLS's rule is `is_published = true OR auth.uid() =
creator_id`. For an anonymous caller `auth.uid()` is null, so RLS alone
already reduces to `is_published = true` — but for a **signed-in**
caller browsing their own public Explore feed, RLS would otherwise let
their own unpublished drafts leak into the public listing (correct
behavior for "My Releases", wrong for "Explore"). The explicit filter
keeps Explore/search/profile-listing semantics identical regardless of
who's looking.

### No N+1

A page of 20 Explore cards is exactly **one** request (the view query);
Release detail is **three** small, bounded requests (card, snapshot
text, children) run as one await + one fire-and-forget; a profile page
is two (profile, then releases). None of this issues a per-card author/
tag/mod-count query.

## 4. Search

Case-insensitive substring (`ilike.*term*`) across `title`,
`description`, `author_display_name` — the release's own **snapshot**
author name (see § 11), not a live join to `profiles.display_name`.
Deliberately no Elasticsearch/Meilisearch/Typesense/vector search/FTS
infrastructure this milestone — substring search was chosen
specifically because it is honest about Chinese: Postgres's built-in
full-text search does not provide real Chinese word segmentation, and
claiming semantic search over `zh-CN` content this milestone would be
inaccurate. Verified live: searching `水晶` against a fixture titled
`水晶守卫` and its remix `水晶守卫：二代` (both matched) alongside
unrelated `Crystal Survival`/`Blocky Racer` fixtures (neither matched)
— see § 12.

**A real client-side bug was found and fixed during § 77's attack-string
testing**: the ILIKE value was interpolated into the PostgREST query
string without percent-encoding. A term as ordinary as `100% off`
produced a malformed URL that made `fetch()` itself throw, surfacing as
a false "Could not reach the Community backend" error for a completely
normal search. Fixed by percent-encoding the (already PostgREST-escaped)
value text while leaving the structural `"`/`*` wrapper characters
literal — verified the fix against the full attack-string battery in
§ 12 afterward.

## 5. Tag filtering

Tag filtering does **not** query the view's own aggregated `tags[]`
column (an unindexed subquery aggregate, expensive to filter directly).
Instead: `community_release_tags?tag=eq.<tag>&select=release_id` (using
the existing `idx_community_release_tags_tag` index) resolves a small id
list first, then `id=in.(...)` is added to the card-view query. Two
small, indexed queries instead of one unindexed scan.

## 6. Pagination

Keyset/cursor pagination on `(published_at DESC, id DESC)`, page size
**20**. The cursor is the last row's `{published_at, id}`; the next page
filters `or=(published_at.lt.X,and(published_at.eq.X,id.lt.Y))`. This
avoids the classic offset-pagination failure mode (a row published
between two page loads shifts every subsequent offset, causing
duplicates or skips) — verified live with a 4-per-page walk across 9
real rows: 9 unique ids returned, zero duplicates, zero gaps (§ 12).

## 7. Release card

`discoveryCardEl(card)` (community.html) renders: title, author (from
the release's own snapshot field), a 2-line-clamped description, up to 4
tag pills, a language badge, mod count, and a provenance line —
`"Original"` or `"Remix of \"Parent Title\""` (falling back to
generation-only phrasing if the parent title isn't resolvable). The
database UUID is never shown on a card. No screenshot/preview-image
requirement — Release Format 1 has no such field, and this milestone
uses a plain visual placeholder (a game-controller glyph on a gradient
tile) rather than blocking on binary image storage, which was
deliberately not introduced. The whole card is one click target
(`role="link"`, `tabindex`, Enter/Space activation); the tag pills stop
event propagation so clicking one filters Explore instead of also
opening the card.

## 8. Release detail page

Shows: title, description, snapshot author name + link to the creator's
public profile, published time (`Intl.DateTimeFormat`, locale-aware),
language, tags (clickable → Explore filter), release note, a
Compatibility badge (§ 9), parent attribution or "original", generation,
direct Remixes (published only), a collapsible **Technical details**
panel (runtime/API/VMP/Release-format versions), a Mods list (§ 8.1),
Download/Open-in-Runtime/Remix/Copy-Link actions, and a document
`<title>` set to `"<Release title> — Voxel Craft Community"` (localized
suffix).

### 8.1 Mods list — never executed

Each Mod is shown as `manifest.id` plus its full source in a scrollable,
`<pre>`-rendered, `textContent`-only block — read-only inspection, no
"run" affordance exists anywhere on this page. Source comes from
`community_releases.snapshot_text` (the exact published payload), not
from the normalized `community_release_mods` index (which intentionally
doesn't store dependency metadata) — this gives full fidelity, including
`manifest.dependencies`, for free.

## 9. Compatibility label

`compatibilityOf(card)` compares the release's recorded `api_version`/
`vmp_version` against this Portal's own known frozen values
(`KNOWN_API_VERSION`/`KNOWN_VMP_VERSION`, mirroring `index.html`'s own
frozen constants). Four honest labels only: **Compatible**,
**Unsupported API**, **Newer Runtime**, **Unknown compatibility** — never
"Safe". This is a version-compatibility signal, not a security or trust
rating, and is never presented as one.

## 10. Runtime handoff — no Auth token, verified

"Open in Runtime" / "Remix" both call `openInRuntime(releaseId)`, which
opens `${runtimeBaseUrl}?communityRelease=<uuid>` in a new tab
(`window.open(..., 'noopener,noreferrer')`, with `win.opener = null` set
explicitly as well) — **the remote Release id is the only thing that
ever crosses this boundary.** `runtimeBaseUrl` is one configurable value
in `COMMUNITY_BACKEND_CONFIG` (defaults to a same-directory `index.html`
for local dev; production should point it at the Runtime's own origin).

On the Runtime side, `index.html`'s `WorkshopController` IIFE checks
`?communityRelease=` once at load, and if present: opens the Workshop to
the Export tab, calls the *existing* anonymous
`runtime.community.getRelease()` client, and populates the *existing*
`communityPendingImport` preview — the exact same preview/trust-notice/
`[Cancel]`/`[Open Release]` UI a manually-typed remote id or a local
`.vrelease` drop already used. **No Mod is activated until the player
explicitly clicks "Open Release."** Verified live: opening with
`?communityRelease=<id>&dev=1` auto-opened the Workshop, showed the
correct preview card, and the Mods tab read `模组 (0)` (zero active
Mods) the entire time the preview was showing.

### No-token-leak test — actual result, not assumed

Signed in on `community.html`, clicked "Open in Runtime", then inspected
the resulting Runtime tab's `localStorage`, JS state, and every network
request. **Finding, stated precisely**: the Runtime's own code never
reads, sends, or references any Community Auth token anywhere (verified
by code inspection — only `voxel-runtime.locale` and Mod-namespaced
`api.storage` keys are ever touched). However, because both files were
opened via `file://` from the same directory in this test environment,
`community.html`'s session happened to be *physically present* in the
shared `localStorage` the Runtime page could also read (see § 2's
corrected finding) — not because of anything the handoff mechanism did
(the URL itself carried only the release id, confirmed by inspecting
the actual navigation), but because of the shared-origin condition
itself. This is reported honestly rather than glossed over: it is the
single clearest demonstration in this project of why origin separation
is a **hard requirement**, not a convenience — under a correct
production deployment (`community.example.com` vs. `play.example.com`),
this shared-storage condition cannot occur at all, and no code change
was needed to make the handoff itself safe, since it was already
carrying only the release id.

## 11. Author identity — snapshot vs. live profile

A Release's `author_display_name` is a **snapshot** taken at publish
time (unchanged since `COMMUNITY_RELEASE_SPEC.md`); a profile's
`display_name` is the creator's **current** name. This milestone
displays the snapshot name on cards and in the Release detail byline
(never silently rewritten if the creator later renames themselves), but
the "click author" link always resolves by `creator_id` — so it always
opens the correct, current profile even if the two names have since
diverged. Both names are real and neither is treated as more
authoritative than the other for what it represents.

## 12. Testing — results

All run live against the real linked Supabase project and real deployed
Edge Function, using the actual `community.html`/`index.html` files, not
mocked.

| Test | Result |
|---|---|
| Anonymous Explore (no session) | **Pass** |
| Explore with a stale/expired session present | **Pass, after a fix** — found live that `callFetch` was attaching an expired `Authorization` header to every request including anonymous-safe Discovery reads, breaking Explore outright with `COMMUNITY_AUTH_REQUIRED` for any signed-in user whose token had lapsed; fixed by adding an `anon: true` flag that skips attaching a token regardless of session state, used by every Discovery read |
| Search `水晶` (zh-CN substring) | **Pass** — exactly the 2 matching fixtures returned |
| Search + language filter combined (`q=Crystal&lang=en-US`) | **Pass** — exactly 1 result, state restored correctly from a direct URL load |
| Tag filter (`tag=tower-defense`) | **Pass** — exactly the 2 matching fixtures, chip UI with clear button |
| Pagination (4-per-page walk over 9 real rows) | **Pass** — 9 unique ids, zero duplicates/gaps |
| Release detail (all fields) | **Pass, after a fix** — found live that the remix/profile-releases sub-section used `showMsg(panel, ...)`, which internally clears its *entire* container; this wiped the whole detail panel (title/description/mods/everything) down to just the trailing "No Remixes yet." line. Fixed with a new `appendMsg()` helper that never clears siblings; audited and fixed the same bug in the public profile page's releases section and the "Copy Link" confirmation (moved to a non-destructive toast) |
| Parent/child lineage display (A → C after "水晶守卫" was published, C's parent link resolves, A's page lists C as a child) | **Pass** |
| Withdrawn-parent handling (temporarily withdrew "水晶守卫", viewed its child) | **Pass** — "原作品当前不可用"/"Original release unavailable" shown, generation preserved, page fully functional, no broken links; fixture restored afterward |
| `.vrelease` download → local Runtime import round-trip | **Pass** (reuses the same `snapshot_text`-is-verbatim guarantee already proven in `COMMUNITY_BACKEND_SPEC.md`) |
| Open in Runtime (`?communityRelease=`) | **Pass** — auto-preview shown, zero Mods activated until explicit "Open Release" click |
| No-Auth-token-leak test | **Pass on code correctness, with an important corrected finding** — see § 10 |
| XSS/hostile metadata (`<img src=x onerror=alert(1)>` title, `<svg onload=alert(2)>` description, `<b>` author name, hostile tag, hostile release note) | **Pass** — rendered as literal text everywhere it appears (Explore card, search result, Release detail including the document `<title>`, technical details), zero alerts fired, verified via direct DOM/accessibility-tree inspection, not just visual review |
| Anonymous privacy/RLS (unpublished/withdrawn rows via the new view, with **no** client-side filter applied) | **Pass** — a filter-less anonymous query against `community_release_cards` returned zero `is_published:false` rows; RLS alone is doing the work |
| Two-user write attacks (reused from the backend milestone's fixtures) | **Pass** — unaffected by this milestone's read-only additions |
| Search-input attack strings (`%`, `_`, quotes, backslashes, a SQL-injection-shaped string, 3000-char string, emoji, `)(evil`, `*)(or(1=1`) | **Pass, after the § 4 encoding fix** — all return clean, filtered (usually empty) results; one string (`'; DROP TABLE ...; --`) is rejected with an HTTP 403 by a platform-level edge/WAF block (verified via `curl`, independent of the browser) before ever reaching PostgREST/the database — a defense-in-depth layer this project doesn't control, reported honestly as an observed finding, not a claimed feature |
| zh-CN full flow (Explore → search → filter → detail → profile → parent/remix → download → Open in Runtime hint) | **Pass** — conducted with the UI in `zh-CN` throughout; see the localized strings throughout § 8/10 |
| en-US regression | **Pass** — switched locale live, entire UI relabeled correctly, first-party Chinese release titles/tags correctly remained untranslated |
| `community.html` catalog parity (en-US vs. zh-CN) | **Pass** — 118 keys each, zero mismatch (checked by extracting and diffing the actual `CATALOG` object from the live page, not by inspection alone) |
| Mobile layout (320×568, 375×812) | **Pass** — `document.body.scrollWidth` equals `window.innerWidth` at both sizes (zero horizontal overflow) on Explore and Release detail; card grid collapses to one column; nav scrolls horizontally instead of wrapping |
| Backend outage / offline Runtime regression | **Pass by construction** — `runtime.community` methods are only ever invoked from an explicit button click (unchanged from the backend milestone); this milestone added no new boot-time network dependency to either file |
| Security/Performance Advisor after the new view | **Pass** — no `security_definer_view` or other new finding; two pre-existing, unrelated project-level Auth findings (`auth_leaked_password_protection`, `auth_insufficient_mfa_options`) remain, out of scope for this schema-only migration |

## 13. Remaining limitations

- No preview images — explicitly deferred (spec § 7); cards use a
  placeholder tile.
- No ranking/recommendation of any kind — `Explore` is `published_at
  DESC` only, by design.
- Tag filtering is single-tag; no AND/OR multi-tag logic.
- Search is substring-only; no stemming, no real Chinese segmentation,
  no relevance ranking beyond `published_at DESC`.
- `file://`-opening both Portal and Runtime from the same directory does
  **not** demonstrate origin separation in this project's tested
  environment (see § 2/10) — treat any local verification of the
  no-token-leak property as requiring two distinct `localhost` origins,
  not two `file://` paths.
- No SSR/OpenGraph/social-preview metadata — `document.title` is the
  only per-page metadata this milestone sets, as scoped.
