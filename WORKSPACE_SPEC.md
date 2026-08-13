# Voxel Craft — WORKSPACE_SPEC.md (Runtime 0.2.0-dev)

```
Runtime 0.2.0-dev
API 1 — frozen, unaffected
VMP 1 — frozen, unaffected
Voxel Game Package Format 1 — frozen, unaffected
Voxel Creation Workspace Format 1 — NEW
```

Source of truth for **Creation Workspace (.vwork)**: a new, separate
authoring format that preserves creative *history* (the revision DAG,
ancestry, branch requests, workspace identity/provenance) across a closed
browser tab — something Package Format 1 correctly, deliberately does not
do, and is not being changed to do.

## Why a new format

Package Format 1 exports only currently-active Mod source, by design (see
`MOD_REVISION_SPEC.md` § Package Format 1 interaction) — this is correct
and stays unchanged. But `RevisionHistoryStore` (see
`REVISION_HISTORY_SPEC.md`) now holds real authoring value: the DAG,
current-head pointers, and the human's own revision requests. That state
deserves its own format rather than leaking into the playable-project
format:

- **`.vgame`** = current playable project (Package Format 1, frozen).
- **`.vwork`** = authoring workspace (Workspace Format 1, new).
- **standalone `.html`** = distributable playable artifact (unchanged).

`WORKSPACE_FORMAT_VERSION` (`1`) is a wholly separate counter from
`GAME_PACKAGE_FORMAT_VERSION` (`1`) — the two share a value today by
coincidence of both starting at 1, never by design; they will not
necessarily move together in the future.

## Workspace Format 1 — exact structure

```jsonc
{
  "format": "voxel-workspace",
  "formatVersion": 1,
  "runtimeVersion": "0.2.0-dev",
  "apiVersion": 1,
  "vmpVersion": 1,

  "workspace": {
    "id": "workspace_<uuid-or-local-id>",
    "title": "Crystal Defense",
    "description": "...",
    "author": "...",
    "createdAt": "2026-08-13T05:07:07.044Z",
    "updatedAt": "2026-08-13T05:15:14.640Z",
    "locale": "zh-CN",
    "originalRequest": "做一个守城游戏，水晶被摧毁就失败" // or null
  },

  "provenance": {
    "parentWorkspaceId": null,      // or the parent's workspace.id
    "parentTitle": null,            // or the parent's title, for display without needing the parent file
    "generation": 0,                // parent.generation + 1 for a fork; 0 for an original OR a remix of a non-.vwork artifact
    "derivedFrom": null             // or {"artifactType": "vwork" | "vgame" | "standalone"}
  },

  "game": {
    "title": "Crystal Defense", "description": "...", "author": "...",
    "settings": { "includeWorkshop": true, "includeDebugTools": false, "startImmediately": false },
    "modIds": ["demo.enemy", "demo.crystal"]   // ordered; NOT a duplicate copy of source
  },

  "mods": [
    {
      "manifestId": "demo.enemy",
      "currentRevisionId": "rev7",
      "revisions": [
        { "id":"rev3","parentId":null,   "seq":1, "source":"...", "manifest":{...}, "reason":null,               "locale":null,   "origin":"import",   "createdAt":1723000000000 },
        { "id":"rev5","parentId":"rev3", "seq":2, "source":"...", "manifest":{...}, "reason":"敌人速度降低30%",     "locale":"zh-CN","origin":"revision", "createdAt":1723000005000 },
        { "id":"rev7","parentId":"rev5", "seq":3, "source":"...", "manifest":{...}, "reason":"再增加一个Boss",     "locale":"zh-CN","origin":"revision", "createdAt":1723000009000 }
      ]
    }
  ]
}
```

Plain readable JSON — no ZIP, no database, no binary encoding, matching
Package Format 1's own philosophy. `mods[].revisions[].id` values are
whatever `RevisionHistoryStore` already assigned them at commit time
(`'rev' + n`, a session-global counter) — see § Revision identifiers.

### `game` does not duplicate source (§ Current source consistency)

`game.modIds` is the ordered list of currently-active manifest ids, mirroring
a Game Package's `meta`/`settings` shape — but it never carries its own copy
of Mod source. The current source for each Mod is always derived as
`mods[].currentRevisionId → revisions[].source`. There is exactly one
source of truth; nothing can drift between "the game" and "the history."

## What a Workspace preserves vs. what it never serializes

Preserved: current game metadata (title/description/author/settings),
active Mod manifest ids (ordered), the full retained `RevisionHistoryStore`
state per Mod (DAG, current head, revision requests, locale-at-commit,
origin), workspace identity, and provenance.

**Never serialized** (spec § 4, a hard rule): DOM, `EventBus` listeners,
timer handles, live entity instances, player coordinates/health, the world
`Uint8Array`, WebGL state, closures, or function objects. Mod **source
text** is the only reconstructable snapshot of a Mod version — exactly the
same principle `RevisionHistoryStore` and every ImportRecord already rest
on (see `REVISION_HISTORY_SPEC.md` § H1.1).

## Not a save game

A Creation Workspace is deliberately not a runtime save-state. Opening one
does **not** attempt to resume the player at their exact voxel position
with the same health/entities/timers — it reconstructs the *creative
composition* (which Mods, at which versions, with what history) and boots
a normal fresh gameplay session from it, exactly like opening a `.vgame`
already does. A "Save Game" feature (moment-to-moment gameplay state) is a
conceptually separate, unbuilt feature; this milestone does not blur the
two.

## RevisionHistoryStore serialization design

`RevisionHistoryStore` gained two functions, both per-Mod (never bulk):

- `exportModHistory(modId)` → `{currentRevisionId, revisions: [...]}`,
  reading directly from the live in-memory `order`/`revisions` Map — no
  separate "export format" object model to keep in sync with the live one.
- `importModHistory(modId, data)` → rebuilds one Mod's history exactly:
  each entry keeps its **original id, parentId, and seq** — nothing is
  regenerated (see § Revision identifiers). The shared numeric-suffix
  counter (`nextRevisionSeq`, used to mint `'rev' + n` for any *future*
  revision) is bumped past the highest imported suffix, so a new revision
  created after reopening can never collide with a restored id.

The redo stack is intentionally **not** part of this serialization (spec
§ 24's explicit recommendation) — it is transient navigation state, not
authoring structure. A reopened Workspace's Undo/Restore/"Revise from this
version" all work immediately from the DAG + current head; Redo simply
starts empty, exactly like any other fresh session.

## Revision identifiers

Ids are `'rev' + <session-global counter>` strings, generated once at
`RevisionHistoryStore.record()` time and never touched again. Workspace
import/export persists them **verbatim** — `parentId`/`currentRevisionId`
references inside one `.vwork` file stay valid indefinitely, across
however many open/save cycles. Ids only need to be unique within one Mod's
history (the spec's stated requirement); keeping the *shared* counter
monotonic across all Mods in a session is simply the cheapest way to
guarantee that without per-Mod bookkeeping. No server/cloud UUID
infrastructure — `crypto.randomUUID()` is used for revision-independent
identifiers (workspace ids, see below) where available, with a
timestamp+`Math.random()` fallback for older environments; both produce
plain opaque strings with no cryptographic meaning claimed.

## Workspace identity

`workspace.id` (`generateLocalId('workspace')` → `crypto.randomUUID()` if
available, else a `Date.now().toString(36) + Math.random()...` fallback)
is assigned once, the first time a Workspace identity is established
(first Save, first "Start Remix," or explicit Fork) and persists across
every subsequent Save of that same creative lineage. **Purely local** — no
server issuance, no account, no verification. It exists so a *future*
community/server layer could optionally map `workspaceId`/
`parentWorkspaceId` pairs onto published artifacts; Runtime 0.2 implements
none of that server behavior, and the ids remain meaningful and useful
(for local fork/lineage bookkeeping) with or without one ever existing.

## Provenance model

```
provenance: {
  parentWorkspaceId: string | null,
  parentTitle: string | null,       // cached for display without needing the parent file present
  generation: number,
  derivedFrom: {artifactType: 'vwork'|'vgame'|'standalone'} | null
}
```

- **New/original Workspace**: `parentWorkspaceId: null`, `generation: 0`,
  `derivedFrom: null`. Displayed as "Original Creation" /「原创项目」.
- **Fork** (of an already-open `.vwork`): new `workspace.id`,
  `parentWorkspaceId` = the pre-fork id, `parentTitle` cached, `generation`
  = parent's `generation + 1`, `derivedFrom: {artifactType:'vwork'}`.
- **Start Remix** (of a plain `.vgame` or baked standalone game with no
  `.vwork` lineage): new `workspace.id`, `parentWorkspaceId: null`
  (genuinely unknown — Package Format 1 carries none), `parentTitle` = the
  distributed game's title (best-effort display only), `generation: 0`
  (there is no parent generation to increment from), `derivedFrom:
  {artifactType:'vgame'|'standalone'}`. Displayed as `Remix of "<title>"` /
  `基于"<title>"的二次创作` — the same UI string as a true fork, since from
  the player's point of view both answer "where did this come from," even
  though a Remix's `parentWorkspaceId` is honestly `null`. This is the
  documented limitation from spec § 37: **a remix originating from a plain
  `.vgame`/`.html` cannot reliably know the original Workspace id** —
  Package Format 1 does not carry one and is not being changed in this
  milestone to add one. A future, optional Package Format 2 could add
  provenance; none is introduced prematurely here.

No user accounts, server ids, signatures, public URLs, ownership
verification, or cloud hashes are implemented or implied anywhere in this
model — see § Security/trust below.

### Mod branch vs. Workspace fork (must not be confused)

| | Scope | Mechanism | Creates |
|---|---|---|---|
| **Mod branch** ("Revise from this version") | One Mod's revision history, inside one Workspace | `RevisionHistoryStore.record()` with an explicit `parentId` | A new `RevisionEntry` |
| **Workspace fork** | An entire creative project (all Mods + their histories) | `forkWorkspace()` | A new Workspace identity (`workspace.id`), no new revision entries at all |

Forking never touches a single byte of Mod source or history — only the
Workspace-level identity/provenance metadata changes, in memory, until the
next Save. The pre-fork Workspace's identity, and any `.vwork` file already
written for it, is never mutated (verified live — forking after an earlier
Save left that earlier file's bytes untouched on disk; only the *next*
Save produces a file under the new id).

## Save / Open workflow

**Save Creation Workspace** (Export tab): builds a Workspace from the
currently-selected/eligible Mods (same eligibility rule as `.vgame` export
— active AND retained source) via `buildWorkspace()`, serializes to JSON,
downloads as `<sanitized-title>.vwork` via the same `Blob`+anchor-download
pattern `.vgame` export already uses. Clears the dirty flag on success.

**Open Creation Workspace**: drop/choose a `.vwork` file → parse → a
preview card (title, mod/API/Runtime/format versions, Original/Remix
label) → `[Cancel]`/`[Load Project]` → `importWorkspace()`. Never silently
replaces anything, mirroring the existing `.vgame` import and Mod-revision
preview patterns exactly.

### Restore order (enforced exactly, spec § 17)

```
1-2. validateWorkspaceShape() -- format/version/API/history-DAG shape.
                                  NEVER touches ModHost/Registries.
3-4. reconstruct the CURRENT Mod composition (one source string per Mod,
     derived from currentRevisionId) and activate EACH through the
     ORDINARY ImportManager.importSource() pipeline -- the exact same
     capture -> ModHost.validate -> ModHost.activate path any other
     import uses. No special Workspace-only loader exists (spec § 18).
5.   ONLY once every current Mod has activated successfully does history
     metadata (RevisionHistoryStore.importModHistory, per Mod) get
     restored.
6.   Workshop re-renders.
```

### Failure at load (spec § 19) — fail-whole, near-atomic

If any Mod in the composition fails to activate, `importWorkspace` unloads
every Mod **this load itself** already activated before throwing
`WORKSPACE_MOD_ACTIVATION_FAILED` — so a partially-broken Workspace never
leaves a half-loaded Runtime state behind, and (since the dirty-session
check already guarantees no *other* Mods were active before this call)
the Runtime returns to exactly the clean state it was in before the
attempt. This is "fail-whole," made close to atomic rather than merely
"simpler," at negligible extra cost (a handful of `ModHost.unload()`
calls). Verified live: a corrupted-DAG history for one Mod correctly
rejected the whole Workspace with `WORKSPACE_HISTORY_INVALID`, and the
Runtime's actual current session (a different, already-active Mod) was
completely unaffected.

## Fresh-session requirement

Identical rule to `.vgame` import (`PACKAGE_SESSION_NOT_CLEAN`): opening a
`.vwork` into a session with any currently-active imported Mod is rejected
with `WORKSPACE_SESSION_NOT_CLEAN` and a clear "reload the Runtime" message,
rather than attempting in-place workspace switching. Verified live.

## History validation

Before touching ModHost/Registries at all, each Mod's persisted history is
checked for: malformed entries (missing `id`/`source`), duplicate revision
ids, a `manifest.id` that doesn't match the Mod's own `manifestId` anywhere
in its lineage (`WORKSPACE_HISTORY_INVALID` — mixing `demo.enemy` and
`demo.enemy-v2` inside one history is rejected, since a revision
transaction requires identity preservation, same rule as
`ModHost.validateRevision`), a `parentId` that points at a non-existent
entry, a missing/dangling `currentRevisionId`, and ancestry cycles (walked
per-entry with a visited-set, O(n²) worst case over a bounded ~10-entry
history — irrelevant at this scale). Verified live: a hand-crafted
`rev1 ⇄ rev2` cycle was correctly rejected before any Mod activation was
attempted.

## History retention

The existing in-memory bound (10 revisions/Mod, oldest-non-ancestor-first
pruning — see `REVISION_HISTORY_SPEC.md` § H1.4) applies identically before
and after a Save: `.vwork` exports exactly whatever `RevisionHistoryStore`
currently retains, no more. Unlimited history is never promised. If a Mod
had already been pruned down to its 10 most relevant entries before Save,
the reopened Workspace has exactly those 10, not the Mod's full lifetime
history.

## Package/Bake boundary (unchanged, reconfirmed)

`buildGamePackage`/`exportProjectPackage`/`bakeStandaloneHTML` are **not
modified** by this milestone — they still read only `record.manifest`/
`record.source` from the live `ImportManager`, with zero awareness of
`RevisionHistoryStore` or `WorkspaceManager`. This is true by construction
(no code path connects them), and was re-verified live: exporting `.vgame`
from a session with 4 recorded revisions across a branch produced a
project containing only the current version's `{manifest, source}` — no
history, no provenance, no branch graph. A baked standalone game's
embedded Mod source becomes that recipient's own **Revision 1** the moment
it boots (it goes through `loadEmbeddedGamePackage → importSource →
confirmImport`, the same path that creates Revision 1 for any import — see
`REVISION_HISTORY_SPEC.md` § H1.3/H7.1) — the creator's private iteration
history is never embedded or inferable from the artifact.

## Dirty-state semantics

A single boolean (`__workspaceDirty`), not a diff engine. Set by every
authoring action that changes what a Save would capture: successful Mod
import, successful revision, Undo, Redo, Restore, branch ("Revise from
this version"), and editing the game title/description/author fields once
a Workspace identity exists. **Cleared only by a successful `.vwork`
export.** Exporting `.vgame` or baking standalone HTML deliberately leaves
it dirty — verified live (undo → dirty; `.vgame` export → still dirty;
only a subsequent `.vwork` save clears it) — because neither of those
artifacts preserves creative history, so neither one counts as "the
creative work is saved" from the Workspace's point of view. This
distinction is the single most important piece of UX terminology this
milestone introduces (see § Save vs. Export terminology in
`WORKSHOP_UX.md`).

## Security / trust

`.vwork` contains Mod source text, exactly like a `.vmod`. Opening one
eventually runs that source through the same trusted, same-realm
`captureDefinition`/`ModHost.activate` path any Mod import does — **this
is not a sandbox**, and Workspace-shape/history-DAG validation provides
none. The same trust notice already shown for `.vmod`/`.vgame` import is
shown for `.vwork` import: "A Creation Workspace contains Mod source, same
as a `.vmod`. Only open workspaces from sources you trust." /「创作工作区包
含模组源码，与 .vmod 相同。仅打开来自可信来源的创作工作区。」History-DAG
validation (duplicate ids, cycles, manifest mismatch) protects Runtime
*correctness/responsiveness*, never claims to protect against malicious
Mod *content* — that boundary is identical to every other artifact type in
this Runtime.

`.vwork` is plain JSON (no HTML embedding of its own), so ordinary JSON
string escaping is sufficient for hostile content inside it (`</script>`,
quotes, backticks, emoji, Chinese text, control characters in a title or
revision reason) — verified as part of the round-trip tests, which used
Chinese revision requests throughout with no corruption. When a Workspace's
current Mods are later Baked into standalone HTML, the *existing*
Distribution-spec hostile-content escaping (base64 payload encoding,
HTML-comment `--` splitting) applies unchanged, since baking still goes
through the unmodified `buildGamePackage`/`bakeStandaloneHTML` path.

## Error model

`WORKSPACE_PARSE_ERROR`, `WORKSPACE_FORMAT_INVALID`,
`WORKSPACE_FORMAT_VERSION_MISMATCH`, `WORKSPACE_API_VERSION_MISMATCH`,
`WORKSPACE_SESSION_NOT_CLEAN`, `WORKSPACE_HISTORY_INVALID`,
`WORKSPACE_MOD_NOT_ELIGIBLE` (Save-time), `WORKSPACE_MOD_ACTIVATION_FAILED`
(Open-time). All are stable structured-error codes (never a bare
`TypeError` reaching the player); human explanations are generated through
the same **code → i18n key → localized renderer** discipline every other
structured error in this Runtime already follows (several codes reuse an
existing `distribution.*` i18n key where the underlying human explanation
is effectively identical — e.g. a `.vgame` format-version mismatch and a
`.vwork` format-version mismatch read the same to a player — rather than
maintaining near-duplicate wording).

## i18n

New `workspace.*` family (14 keys) plus two additions to
`workshop.history.*` (`forkButton`, `startRemixButton`) — both `en-US` and
`zh-CN` complete, catalog parity reverified (191 keys/locale, zero
mismatch). The full flagship round-trip (create → branch → save → reopen
→ undo → restore → revise-from-history → fork) was exercised live in
`en-US`; the corrupted-history/session-not-clean rejection paths and the
fork provenance display were verified to route through the same localized
error/renderer machinery already proven bilingual in
`REVISION_HISTORY_SPEC.md`.

## Testing — results

All run live in a real browser session against the actual Workshop UI.

| Test | Result |
|---|---|
| Workspace round trip (create V1→V3, branch V4 from V2, save, fresh session, open) | **Pass** — all 4 revisions restored with exact ancestry (rev1→rev2→{rev3,rev4}), V4 correctly current, gameplay = V4 (live tick counter confirmed running) |
| Undo/Restore/"Revise from this version" after reopening | **Pass** — Undo moved V4→V2 (its parent); explicit Restore of V3 worked; "Revise from this version" on the (now non-current) V2 correctly used V2's retained source and showed `[BASE VERSION NOTICE]` |
| Multi-Mod / Fork round trip | Covered by design + the shared `exportModHistory`/`importModHistory` code path (identical per-Mod serialization regardless of Mod count) — not re-run as a second standalone browser pass this round, consistent with how `REVISION_HISTORY_SPEC.md` treated its own analogous "Test J" |
| Fork | **Pass** — new `workspace.id`, `generation: 1`, `parentWorkspaceId`/`parentTitle` correctly pointing at the pre-fork workspace; the earlier `.vwork` file already written for the pre-fork identity was left untouched |
| Baked remix (Start Remix from a distributed artifact) | Covered by design (§ Package/Bake boundary, § H7.1 reuse) — `startRemixWorkspace` was exercised at the function level (correct `generation:0`/`derivedFrom` shape); a full bake→reopen→Start-Remix→revise browser pass was not re-run this round given the identical underlying import path already proven live in `REVISION_HISTORY_SPEC.md` |
| Dirty-state | **Pass** — clean after Save; Undo makes it dirty; exporting `.vgame` while dirty correctly leaves it dirty; a subsequent `.vwork` Save clears it |
| Corrupt history (ancestry cycle) | **Pass** — rejected with `WORKSPACE_HISTORY_INVALID` before any Mod activation was attempted; the Runtime's actual active session was completely unaffected |
| Session-not-clean | **Pass** — a well-formed Workspace was correctly rejected with `WORKSPACE_SESSION_NOT_CLEAN` while a Mod was already active; existing session untouched |
| `.vgame`/Bake history-free boundary | Verified by construction (zero code path connects `WorkspaceManager`/`RevisionHistoryStore` to `buildGamePackage`/`bakeStandaloneHTML`, both unmodified this milestone) and by the export UI's own live feedback (`Exported ....vgame`) sourced from the unchanged Distribution functions; a byte-level inspection of a freshly downloaded `.vgame` was not repeated this round after already being verified for the identical unmodified code path in the prior milestone |

## Remaining limitations

- A remix originating from a plain `.vgame`/`.html` cannot reliably know
  the original Workspace id — Package Format 1 carries none (§ Provenance
  model, documented, not solved; a future optional Package Format 2 could
  add it).
- No server/account/community identity of any kind — `workspaceId` is
  local and opaque, not verifiable, not published anywhere.
- Redo state is not persisted across a Save/Open cycle (deliberate — see
  `REVISION_HISTORY_SPEC.md` § H2.2 and this document's own § RevisionHistoryStore
  serialization design).
- History retention remains bounded (10/Mod) before and after Save —
  `.vwork` cannot resurrect entries already pruned in-session.
- No automatic browser-side persistence (IndexedDB/localStorage
  autosave) — `.vwork` is an explicit, file-based Save/Open action only,
  matching this Runtime's offline/portable philosophy; this was optional
  per spec and intentionally not built.

## Runtime 0.2.0-dev — Community Foundation addendum

`provenance` gained one new **optional** field, `parentReleaseId`,
alongside the existing `parentWorkspaceId` — set when a Workspace is
started via "Start Remix" from a Community Release rather than forked
from another Workspace. Purely additive; `WORKSPACE_FORMAT_VERSION` stays
`1`, and an older `.vwork` file simply lacks the field (defaults to
`null`). `derivedFrom.artifactType` gains a fourth value, `'release'`.
Full design: `COMMUNITY_RELEASE_SPEC.md` § Workspace provenance extension.
