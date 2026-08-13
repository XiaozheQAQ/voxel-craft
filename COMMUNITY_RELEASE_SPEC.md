# Voxel Craft — COMMUNITY_RELEASE_SPEC.md (Runtime 0.2.0-dev)

```
Runtime 0.2.0-dev
API 1 — frozen, unaffected
VMP 1 — frozen, unaffected
Voxel Game Package Format 1 — frozen, unaffected
Voxel Creation Workspace Format 1 — frozen this milestone (one additive,
                                     backward-compatible field only)
Voxel Community Release Format 1 — NEW
```

Source of truth for the **Community Foundation & Publish Model**: the local
data model and file format a future backend community service will persist,
not invent. No server, account, or network code is introduced this
milestone — see § Stop condition.

## 1. Product objective

```
Creation Workspace → Publish → Release Snapshot → Share/Download →
Open in Runtime → Start Remix → Publish derivative Release
```

The Community's primary content object is a **playable Game Release**, not
a bare `.vmod`. This document defines what that object is before any
backend exists to store it.

## 2. Release vs. Workspace — the canonical boundary

| | **Creation Workspace** (`.vwork`) | **Community Release** (`.vrelease`) |
|---|---|---|
| Purpose | Private, editable authoring state | Published, shareable snapshot |
| Contains | Full revision DAG, branches, requests, redo state | Current Mod source + presentation metadata only |
| Mutability | Edited continuously | Immutable-ish once published — never mutated in place |
| Identity | `workspaceId` | `releaseId`, always new on every publish |
| Produces | Many Releases over time | One playable game (via the existing Bake path) |

A single Workspace can produce many Releases:

```
Workspace A
  ├── Release 1
  ├── Release 2
  └── Release 3
```

Publication history is **never** stored as Mod revision history — those
are different levels entirely (a Mod's `RevisionHistoryStore` DAG lives
inside one Workspace; a Release chain spans across Workspaces/sessions and
is tracked only by each Release's own single `parentReleaseId` pointer).

## 3. Release Format 1 — exact structure

```jsonc
{
  "format": "voxel-release",
  "formatVersion": 1,

  "releaseId": "release_<uuid-or-local-id>",
  "contentHash": "fp_<non-cryptographic fingerprint>",   // see § 9

  "game": {
    "title": "Crystal Defense",
    "description": "...",
    "authorDisplayName": "...",     // NOT a verified identity -- see § 7
    "createdAt": "2026-08-13T05:07:07.044Z",   // Workspace's own createdAt if known, else this publish's timestamp
    "publishedAt": "2026-08-13T05:15:14.640Z"
  },

  "runtime": {
    "runtimeVersion": "0.2.0-dev",
    "apiVersion": 1,
    "vmpVersion": 1,
    "packageFormatVersion": 1
  },

  "mods": [
    { "manifest": { "id": "demo.enemy", "...": "..." }, "source": "defineVoxelMod({...})" }
  ],

  "provenance": {
    "parentReleaseId": null,        // or the immediate parent Release's id
    "parentTitle": null,            // cached for display without needing the parent file present
    "generation": 0,                // parent.generation + 1, or 0 for an original
    "remixNote": null               // reserved, unused this milestone
  },

  "metadata": {
    "tags": ["tower-defense", "survival"],   // max 8, each trimmed to 32 chars -- presentation only
    "language": "zh-CN",                     // primary player-facing content language, metadata only
    "releaseNote": "Added boss enemies and lowered wave speed."  // max 500 chars
  }
}
```

Plain readable JSON, no ZIP/binary, matching every other format in this
Runtime. `COMMUNITY_RELEASE_FORMAT_VERSION` (`1`) is its own counter —
independent of `API_VERSION`, `VMP_VERSION`, `GAME_PACKAGE_FORMAT_VERSION`,
and `WORKSPACE_FORMAT_VERSION`. None of these are conflated or bumped
together just because they happen to change in the same Runtime release.

### `mods[]` reuses Game Package composition (spec § 8)

`buildRelease()` does not duplicate Mod eligibility/dependency/topological-
sort logic — it calls the existing, unmodified `buildGamePackage()`
directly and re-shapes its output (`pkg.mods`, `pkg.meta`) into the
Release envelope. `releaseToGamePackage(release)` performs the reverse
mapping (reconstructing a `{format:'voxel-game', ...}`-shaped object from
a Release's fields) so that **the exact same, unmodified**
`bakeStandaloneHTML()` and `topoSortGamePackageMods()` + `ImportManager.
importSource()` pipeline can be reused verbatim for both baking a Release
and opening one. There is no second gameplay packaging engine anywhere in
this milestone.

## 4. Privacy boundary — what a Release never contains

A Release is built **only** from `buildGamePackage()`'s output — it never
reads `RevisionHistoryStore` at all. This means, by construction, a
Release can never contain: prior Mod revisions, abandoned/hidden branches,
the redo stack, revision requests, the original creation prompt, or
Workshop error logs. Verified live (the mandatory "Private History Leak
Test," spec § 22): a Workspace with 4 recorded revisions across a branch
(V1→V2→{V3,V4 current}, each carrying a distinct secret revision-request
string) was published, and the resulting `.vrelease` file was inspected
directly — it contained exactly V4's source and title/description/author,
and **zero** trace of V1/V2/V3 source text, any revision-request string,
or any `revisions`/`redoStack`/`currentRevisionId` key anywhere in the
file.

## 5. Release identity

`releaseId` = `generateLocalId('release')` (the same local-id generator
`WorkspaceManager` already uses — `crypto.randomUUID()` where available,
else a timestamp+random fallback). **Purely local**, no server issuance,
no verification claimed. Publishing an updated version always mints a
**new** `releaseId` and a **new** file — a Release is never mutated in
place, and re-publishing never overwrites a prior Release's identity.

## 6. Provenance / remix model

```
provenance: { parentReleaseId, parentTitle, generation, remixNote }
```

- **Original**: `parentReleaseId: null`, `generation: 0`. Displayed as
  "Original Creation" / 「原创作品」.
- **Remix chain**: each Release carries only its **immediate** parent
  pointer — no embedded ancestry array. A future Community backend can
  reconstruct the full graph by following `parentReleaseId` pointers
  release-by-release; Runtime 0.2 never needs to.

### Parent resolution within one session (§ 24-25)

The very first publish in a session resolves its parent from the **active
Workspace's own provenance** (`ws.provenance.parentReleaseId`/
`parentTitle`/`generation`) if that Workspace was itself started via
"Start Remix" from a Release — this is what correctly threads a Release's
`generation` through even across a Workspace save/reopen (`.vwork`) cycle,
since that provenance is what `WORKSPACE_SPEC.md` documents as persisted
verbatim. Every *subsequent* publish in the same session chains from the
most recently published Release that session (tracked in a lightweight
session variable) — so **repeatedly clicking Publish Snapshot without
reopening produces its own chain** (verified live: A→B→C was produced this
way in one continuous session, in addition to the standard "close, reopen,
remix" flow being verified separately). Both paths are the same underlying
mechanism; neither is a special case.

## 7. Creator model — local only

`authorDisplayName` is free text sourced from the Workshop's existing
title/description/author fields. **Never** called "verified author" or
"owner" anywhere in code, UI copy, or this document. No account, no
identity verification. A future account system would *augment*, not
replace, this field's meaning.

## 8. Tags / language / release note

- `tags`: optional array, capped at 8 entries, each trimmed to 32
  characters. Presentation/discovery metadata only — no taxonomy, no
  controlled vocabulary, no validation beyond the length/count cap.
- `language`: a plain metadata string (defaults to the active
  `runtime.i18n` locale at publish time if not explicitly set). Recording
  it does **not** alter Runtime locale negotiation and does **not** imply
  Mod text can be auto-translated — it is purely informational, exactly
  like `.vwork`'s own `workspace.locale` field.
- `releaseNote`: optional, capped at 500 characters, publication-level
  context ("what changed in this release"). Deliberately distinct from a
  Mod's own revision `reason` (Workshop revision-request text) — the two
  are never conflated; a `releaseNote` is written once, at publish time,
  about the whole game, not per-Mod.

## 9. Content hash (optional, non-authoritative)

`contentHash` is a **non-cryptographic**, synchronous fingerprint (an
FNV-1a-shaped 32-bit rolling hash over each Mod's exact `manifest.id` +
source text, order-sensitive) computed at publish time. Deliberately NOT
Web Crypto `SHA-256` — that would force every publish action to become
asynchronous for a feature the spec marks fully optional and explicitly
non-blocking. It exists only as a cheap client-side "have I seen this
exact content before" dedup hint for a *future* backend.

**`releaseId` (identity) and `contentHash` (content fingerprint) are
deliberately different fields and are never conflated.** Two Releases can
share an identical `contentHash` (the exact same Mods republished
unchanged) while always having distinct `releaseId`s — publishing is an
*event* (a new snapshot moment), fingerprinting is a property of the
*content* itself. `contentHash` is **never** presented as authenticity,
ownership, or a security signature anywhere in this Runtime.

## 10. Workspace provenance extension (no format break)

`.vwork`'s `provenance` object gains one new **optional** field,
`parentReleaseId`, alongside the existing `parentWorkspaceId`:

```jsonc
provenance: {
  parentWorkspaceId: string | null,   // set by a Workspace Fork
  parentReleaseId: string | null,     // NEW -- set by "Start Remix" from a Release
  parentTitle: string | null,
  generation: number,
  derivedFrom: {artifactType: 'vwork'|'vgame'|'standalone'|'release'} | null
}
```

This is purely additive — `WORKSPACE_FORMAT_VERSION` stays `1`, unchanged.
An older `.vwork` file written before this milestone simply lacks the
field; `importWorkspace` defaults it to `null`, exactly as it already
defaulted every other provenance field for a hypothetically-incomplete
file. **No Workspace Format 2 was needed and none was created** — the spec's
explicit "STOP and report before creating Workspace Format 2" condition
was never triggered.

`derivedFrom.artifactType` gains a fourth value, `'release'`, alongside
the three that already existed (`'vwork'` for a Fork, `'vgame'`/
`'standalone'` for a plain-package remix).

A Workspace Fork (`forkWorkspace()`) always sets the new
`parentReleaseId: null` explicitly — a Fork's lineage is workspace-to-
workspace by definition (§ 12 below), even if the workspace *being*
forked itself has a `parentReleaseId` from further back; that ancestor
information isn't lost, it just isn't the *immediate* parent of the new
fork.

## 11. Terminology — kept strictly distinct (spec § 26)

| Term | Scope | Mechanism |
|---|---|---|
| **Mod Branch** | One Mod's revision history, inside one Workspace | `RevisionHistoryStore.record()` with an explicit `parentId` ("Revise from this version") |
| **Workspace Fork** | An entire Workspace (all Mods + full private history) | `forkWorkspace()` — new `workspace.id`, `parentWorkspaceId` set |
| **Release Remix** | A brand-new Workspace derived from a *published, history-free* Release | `startRemixFromRelease()` — new `workspace.id`, `parentReleaseId` set, no private history available (correctly — there never was any to inherit) |

"Fork" is never used loosely for all three; each has its own function,
its own button label, and its own i18n string.

## 12. Publish UX

Export tab → **Publish Snapshot** section (alongside, and clearly
distinguished from, Export Project/Bake and Save Workspace — see § 15
below): Tags / Language / Release note inputs, a live **preview** showing
title, author, description, current Mods, language, tags, parent/remix
attribution, the release note, and — the single most important line —
**"Revision history: Not included."**, always shown, never buried. Only
after this does `[Publish Snapshot]` actually build+download the
`.vrelease` file.

## 13. Open Release UX

Export tab → **Open Release**: drop/choose a `.vrelease` → parse → preview
card (title, author, mod count, runtime version, tags, Original/Remix
label) → `[Cancel]`/`[Open Release]` → `openRelease()`. **Never
auto-imported as a private Workspace** (hard requirement, verified by
code inspection: `openRelease()` never touches `runtime.workspace`/
`__currentWorkspace` at all). Once open, a **Start Remix** button appears
(only for a session opened via Open Release specifically — see § 14's
button-conflict fix below), letting the player explicitly choose to begin
their own creative lineage from it.

### Reused "opened from a package" plumbing

`openRelease()` sets `__currentGamePackage` (the same variable a `.vgame`
import sets) purely so the Export tab's existing "This session was opened
from a Game Package: ..." notice and Mod-eligibility logic apply for free.
One real UX bug this surfaced and was fixed during testing: the *generic*
`.vgame`-remix "Start Remix Workspace" button (which cannot carry release
provenance — Package Format 1 has none) would otherwise also appear
alongside the Release-aware **Start Remix** button, letting a player pick
the wrong one and silently lose the chain. Fixed by suppressing the
generic button whenever `runtime.community.current` is set (i.e., the
session was opened via a Release specifically, not a plain `.vgame`).

Opening a Release also now populates the Export tab's title/description/
author/tags/language fields from the Release's own metadata (matching
`.vgame`/`.vwork` import's existing behavior) — found and fixed during
testing: a baked/exported artifact immediately after opening a Release
was defaulting to "My Voxel Game" instead of the Release's actual title.

## 14. Start Remix behavior

`startRemixFromRelease(release)` calls the existing
`runtime.workspace.startRemixWorkspace('release', release.game.title,
{parentReleaseId: release.releaseId, parentGeneration:
release.provenance.generation})`. Because a Release's own `generation` IS
known (unlike a plain `.vgame`/standalone, which carries none), the new
Workspace's `generation` genuinely continues the real chain
(`parentGeneration + 1`) rather than resetting to 0 the way a `.vgame`
remix necessarily must (documented, unchanged limitation from
`WORKSPACE_SPEC.md`). Each distributed Mod becomes that Workspace's own
Revision 1 for free, via `confirmImport`'s existing behavior (see
`REVISION_HISTORY_SPEC.md` § H1.3) — no Release-specific code was needed
for this part at all.

## 15. Save vs. Export vs. Publish — terminology (spec § 34)

Three distinct verbs, three distinct outputs, never blurred:

- **Save Creation Workspace (.vwork)** — preserves your *creative history*.
- **Export Project (.vgame)** — the *current playable composition*, no
  history.
- **Publish Snapshot (.vrelease)** — a *shareable* snapshot of the current
  playable composition, no history, plus lightweight presentation
  metadata and remix provenance.
- **Bake Standalone HTML** — a finished, distributable game file.

## 16. Session cleanliness

Opening a `.vrelease` into a session with any active imported Mod is
rejected with `RELEASE_SESSION_NOT_CLEAN` and a clear "reload the Runtime"
message — the same fresh-session-only policy `.vgame`/`.vwork` import
already use. No in-place project switching was built. Verified live.

## 17. Restore order / failure mode (mirrors `.vwork`)

```
1. validateReleaseShape() -- format/version/API/mod-shape. Never touches
   ModHost/Registries.
2. dirty-session check (RELEASE_SESSION_NOT_CLEAN).
3. reconstruct the composition via releaseToGamePackage() + the ORDINARY
   topoSortGamePackageMods() + ImportManager.importSource() pipeline --
   the exact same one .vgame import/.vwork import/baked-boot already use.
4. on any Mod activation failure, unload every Mod THIS load itself
   already activated before throwing RELEASE_MOD_ACTIVATION_FAILED --
   fail-whole, near-atomic, identical policy to importWorkspace.
```

## 18. Validation (spec § 21 — reuse, never duplicate)

`buildRelease()` reuses `buildGamePackage()`'s existing eligibility
(active + retained source) and dependency-cycle/missing-dependency checks
outright — publishing goes through no separate Mod validator.
`validateReleaseShape()` additionally checks: `format`/`formatVersion`/
`apiVersion` match, `releaseId`/`game.title` present, `mods` is a non-empty
array, and every Mod entry has both a `source` string and a `manifest.id`
string. Malformed entries are rejected with `RELEASE_VALIDATION_FAILED`
before any Mod activation is attempted (verified live).

## 19. Security / trust

Opening a `.vrelease` ultimately runs its included Mod source through the
same trusted, same-realm `captureDefinition`/`ModHost.activate` path any
other Mod import uses — **this is not a sandbox**, and Release-shape
validation provides none. The same trust notice already established for
`.vmod`/`.vgame`/`.vwork` is shown: "A Release contains Mod source, same
as a `.vmod`. Only open releases from sources you trust." /「作品发布包含
模组源码，与 .vmod 相同。仅打开来自可信来源的作品发布。」`contentHash`
(§ 9) is never presented as changing this boundary in any way.

`.vrelease` is plain JSON (no HTML embedding of its own); hostile content
in titles/descriptions/tags/release notes/Mod source (`</script>`, quotes,
backticks, emoji, Chinese text) needs only ordinary JSON string escaping,
which `JSON.stringify`/`JSON.parse` already provide — verified as part of
testing, which used Chinese text throughout. When a Release's Mods are
later Baked, the *existing, unmodified* Distribution-spec hostile-content
escaping (base64 payload encoding, HTML-comment `--` splitting) applies,
since baking a Release still goes through the unmodified
`bakeStandaloneHTML()`.

## 20. Error model

`RELEASE_PARSE_ERROR`, `RELEASE_FORMAT_INVALID`,
`RELEASE_FORMAT_VERSION_MISMATCH`, `RELEASE_API_VERSION_MISMATCH`,
`RELEASE_VALIDATION_FAILED`, `RELEASE_SESSION_NOT_CLEAN`,
`RELEASE_MOD_ACTIVATION_FAILED`, `RELEASE_MOD_NOT_ELIGIBLE` (publish-time).
All stable, English, structured — human explanations follow the
established **code → i18n key → localized renderer** discipline, several
reusing an existing `distribution.*` key where the underlying human
explanation is effectively identical to its `.vgame`/`.vwork` counterpart.

## 21. i18n

New `community.*` family (18 keys), plus reuse of several existing
`distribution.*`/`workshop.export.*` keys for shared wording (loaded
project/mod-count/etc. — no near-duplicate strings maintained). Catalog
parity reverified: 208 keys per locale, zero mismatch.

## 22. Community Card view model (spec § 27 — no browsing UI)

`buildCommunityCard(release)` → `{title, authorDisplayName, description,
tags, language, modCount, runtimeVersion, generation, remixParentTitle}`.
Used internally by the Open-Release preview card and nowhere else — no
list/grid/browsing UI exists or is implied. This exists purely so a
future card-list UI (still explicitly out of scope) has one pre-existing
function to call instead of re-deriving this shape from raw Release JSON.

## 23. Explicitly NOT built this milestone

Preview/screenshot images, likes, ratings, comments, download counts,
follows, user accounts, server-issued ids, authentication, marketplace
browsing, remote upload — all out of scope per the milestone's stop
condition. `contentHash` exists but is documented as non-authoritative
(§ 9); no signature/verification scheme was built.

## Testing — results (Test A–L)

All run live in a real browser session against the actual Workshop UI. To
work around a browser download-dedup quirk (repeated same-named-file
downloads in this automated environment were sometimes silently skipped),
`HTMLAnchorElement.prototype.click` was temporarily monkey-patched to
capture each Blob's content directly via `fetch(blobURL)` — the same
Blob-download code path (`downloadBlob()`) the Workshop UI already uses,
just observed rather than relying on the OS-level file landing on disk.

| Test | Result |
|---|---|
| A — Original Workspace → Release | **Pass** — `provenance.parentReleaseId: null`, `generation: 0` |
| B — Private history exclusion | **Pass** — a 4-revision, branched Workspace with secret revision-request strings published a Release containing only the current Mod's source; zero trace of prior versions, requests, or history-model keys, verified by direct file inspection |
| C — Release open/play | **Pass** — Mod activated and its `game.tick` listener confirmed live/incrementing |
| D — Release → Bake | **Pass** — baked filename/title correctly reflect the Release's own metadata (after fixing a found gap) |
| E — Release → Start Remix | **Pass** — new Workspace with `provenance.derivedFrom.artifactType:'release'`, correct `parentReleaseId`/`generation:1` |
| F — Remix Workspace → Release child | **Pass** — Release B's `parentReleaseId` exactly matched Release A's `releaseId`; `generation: 1` |
| G — Multi-generation A→B→C | **Pass** — verified with three DIRECTLY captured, distinct files: A (gen 0, no parent) → B (gen 1, parent = A's exact id) → C (gen 2, parent = B's exact id) |
| H — Multi-Mod Release | Covered by design (`buildRelease` iterates `pkg.mods` generically, no Mod-count-specific code path) — not re-run as a dedicated second browser pass this round |
| I — Corrupt Release | **Pass** — a Mod entry missing `source` was rejected with `RELEASE_VALIDATION_FAILED` before any activation attempt; current session unaffected |
| J — Dirty-session rejection | **Pass** — `RELEASE_SESSION_NOT_CLEAN` shown, existing active session completely undisturbed |
| K — zh-CN complete workflow | Catalog verified complete (208/208, zero mismatch) and every new string was exercised via the same rendering code path already proven bilingual in `REVISION_HISTORY_SPEC.md`/`WORKSPACE_SPEC.md`; a full live end-to-end publish→remix→publish pass specifically in `zh-CN` was not re-run as a separate pass this round given the identical underlying mechanism already verified in English |
| L — Hostile-content chain | Covered by construction (plain `JSON.stringify`/`JSON.parse`, unmodified Bake escaping) — Chinese text was used throughout the A→B→C chain tests without incident; a dedicated `</script>`/backtick-injection pass was not run as a separate test this round |

## Remaining limitations

- No backend, accounts, or verified identity of any kind — `releaseId`
  and `authorDisplayName` are local, opaque, and unverified.
- `contentHash` is a non-cryptographic fingerprint, not a security hash —
  explicitly documented as such everywhere it appears.
- A Release chain has no embedded full-ancestry array — reconstructing a
  complete graph requires walking `parentReleaseId` pointers across
  multiple files (by design — a future backend is expected to do this
  once, not every Runtime session).
- No preview images — deferred, would require canvas screenshot +
  embedding or remote storage, neither built.

## Recommended backend model (non-binding, for the next milestone)

A future Community backend should **persist this model, not invent a new
one**: store each published `.vrelease` verbatim (or its constituent
fields) keyed by `releaseId`, index `provenance.parentReleaseId` as a
foreign key to reconstruct remix graphs on demand, use `contentHash` only
as an optional dedup/caching hint (never as an identity or authenticity
signal), and layer real authentication/verified-author identity **on top
of**, not instead of, the existing local `authorDisplayName` field
(treating it as a display fallback for content published before accounts
existed). None of this is implemented in Runtime 0.2 — this section is
guidance for the next milestone, not a commitment made by this one.
