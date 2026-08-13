# Voxel Craft — MOD_REVISION_SPEC.md (Runtime 0.2.0-dev)

```
Runtime 0.2.0-dev
API 1 — frozen, unaffected
VMP 1 — frozen, unaffected
Voxel Game Package Format 1 — frozen, unaffected
```

This is the source of truth for **Transactional Mod Revision**: replacing an
already-loaded Mod with a revised version during the same Runtime session,
without a page reload, with automatic rollback if the replacement fails.

Do not confuse revision with "unload, then import again." Unload is a
player-initiated, one-way, permanent-for-the-session removal. Revision is a
single transaction: validate the new version first, swap it in, and — if
anything about the new version goes wrong — restore the exact working old
version automatically. The old Mod must survive a broken revision.

All revision infrastructure lives under `runtime.*` / Workshop internals /
`ModHost` internals. **Nothing here is exposed as `api.*`.** API 1 does not
grow a new surface just because the host can now hot-replace a Mod — a
`.vmod` has no idea whether it is a first import or a fifth revision; it
just exports `defineVoxelMod({manifest, setup, ...})` exactly as under
Runtime 0.1.

## Definition ownership model

Every entry in `BlockRegistry`/`EntityTypeRegistry` (both built on the same
`createIdRegistry(kind)` factory) now carries:

- `id` — the public `namespace:id` string (unchanged from 0.1).
- `numericId` — the internal array index (unchanged from 0.1).
- `ownerModId` — `manifest.id` of the Mod that registered it, or the literal
  string `'core'` for Runtime-owned core resources, or `null` for a
  definition somehow registered with no owner (shouldn't happen through any
  public path, but the field always exists rather than being absent).
- `removed` — the tombstone flag (see below). `false` for every live
  definition.

`registerCustomBlock`/`registerItem` (blocks/items) and `registerEntityType`
(entities) now thread `ownerModId` through to the registry exactly the way
`api.blocks.register`/`api.items.register`/`api.entities.registerType`
already threaded `modId` through `buildScopedApi` for other purposes (event
attribution, owned-resource tracking). No definition-owning registration
path bypasses this — that was audited across `BlockRegistry`, the `items`
alias, and `EntityTypeRegistry`; there is no other persistent
definition-owning subsystem in Runtime 0.1/0.2.

Owner metadata is **not** exposed through API 1. `api.blocks.get(id)` /
`api.blocks.list()` return exactly what they did in 0.1 — no
`ownerModId`/`removed` leak into a Mod's own view. This is Runtime/Workshop
internal bookkeeping only.

## Core namespace protection

`core:` resources (`core:air`, `core:grass`, `core:stone`, ...) are
registered with `ownerModId: 'core'` via the existing `withCoreRegistration`
gate, exactly as in 0.1. Revision infrastructure changes nothing here: the
`PROTECTED_NAMESPACE` check in `register()` fires before the
revision-replace path is ever considered, so no Mod — revising or not — can
ever register, replace, or tombstone a `core:` resource. There is no
revision flow that targets `core:` at all: revision only ever runs with
`revisionOwner` set to a Mod's own `manifest.id`, never `'core'`.

## Registry replacement semantics

`createIdRegistry(kind)` gained `beginRevision(ownerModId)` /
`endRevision()` / `getTouched()` / `getOwned(ownerModId)` / `tombstone(id)`,
alongside the unchanged `register`/`toNumeric`/`toString`/`get`/`list`.

**Outside an open revision window, `register()` is byte-identical to
Runtime 0.1.1.** `beginRevision`/`endRevision` are only ever called by
`ModHost.reviseMod` (see below) — ordinary `Import .vmod`
(`ImportManager.beginImport`/`confirmImport`) never opens one. A second
ordinary import of an already-loaded (or previously-imported-then-unloaded)
Mod still throws `DUPLICATE_ID` → `DUPLICATE_DEFINITION_ON_REIMPORT`
exactly as documented in Runtime 0.1's `RUNTIME_ARCHITECTURE.md` Option B.
**Runtime 0.2 does not suppress that error and does not blindly overwrite
Registry entries** — replacement only ever happens for the one Mod actively
being revised, inside the narrow window `ModHost.reviseMod` opens for it.

Inside an open window (`revisionOwner === X`), `register(def, ownerModId)`
behaves as:

- `def.id` not yet registered → ordinary new registration, exactly as
  before, owned by `ownerModId`.
- `def.id` already registered, owned by `X` (live OR tombstoned — see
  `REVISION_HISTORY_SPEC.md` § H0.4 for why tombstoned state does not
  block this), AND `ownerModId === X` → **replace in place**: the existing `numericId` is
  reused verbatim; only the registry's stored fields (name/tiles/solid,
  etc.) are overwritten. `BLOCK_TILES[numericId]`/`BLOCK_HARDNESS[numericId]`
  (blocks) and `entityTypeDefs.get(id)` (entities) are likewise updated in
  place by the calling code (`registerCustomBlock`/`registerEntityType`),
  never reassigned to a different numeric slot.
- `def.id` already registered, owned by anyone else (a different Mod's
  resource namespace collision) → still `DUPLICATE_ID`/`PROTECTED_NAMESPACE`
  exactly as before. A revision window never grants cross-Mod replacement
  rights.

**`byNumeric` is append-only and is never compacted or shifted**, revision
or not. A tombstoned entry's numeric slot is permanently reserved.

## Numeric-id stability

> Replacing a definition with the same public resource ID preserves its
> internal numeric ID whenever possible.

This is guaranteed by construction, not by a best-effort heuristic: the
replace path above always reuses `existingNumeric` (the number already
mapped for that string id) rather than allocating a fresh one. Verified live
by acceptance Test D (see below) — a block placed by V1, then re-registered
with different hardness/texture by V2, keeps rendering/behaving correctly
at its original world coordinates with zero world regeneration, because
`world`'s `Uint8Array` cell still holds the same numeric byte the whole
time and that byte's registry entry was updated in place.

No slot-reuse/compaction scheme was built for *freed* numeric ids (tombstoned
ones) — see "Definition removal" below for why that's the safer choice.

## Definition removal ("tombstone") behavior

A Mod revision distinguishes **replacement** (same id, re-registered) from
**removal** (an id the old version owned that the new version's `setup()`
simply never calls `register()`/`registerType()` for again).

Detecting removal is *not* a before/after ownership diff — an id nobody
touches never has its ownership state change at all, so diffing "owned
before" vs "owned after" cannot distinguish "still there, untouched" from
"gone." Instead, `createIdRegistry` tracks a **touched-ids set**, populated
by every `register()` call made while a revision window is open for that
owner (whether it hit the replace path or the new-registration path).
`ModHost.reviseMod` diffs the pre-revision "owned" snapshot against this
touched set:

- in `touched`, not previously owned → **added**
- in `touched`, previously owned → **reused** (replaced in place)
- previously owned, **not** in `touched` → **removed**

Every `removed` id is tombstoned: `tombstone(id)` marks the entry
`removed:true` so `toNumeric()`/`get()`/`list()` all correctly stop seeing
it for ordinary lookups, while **permanently keeping both its numeric slot
AND its string→numeric mapping resolvable**. This is revised from this
document's first draft: an earlier version deleted the string mapping
entirely, which let a re-registration of that exact id allocate a *new*
numeric slot instead of reusing the original one — a real bug, found and
fixed during the Revision History milestone (see `REVISION_HISTORY_SPEC.md`
§ H0.4). The corrected, current rule: **a tombstoned id is permanently
reserved to its original owner.** That owner may reactivate it later, mid
a later revision, reusing the exact original numeric id (see "Registry
replacement semantics" above — the replace path no longer requires the
existing entry to be live). No *other* Mod can ever claim that exact
public id, live or tombstoned, for the rest of the page session. For blocks specifically,
`BLOCK_TILES[numericId]`/`BLOCK_HARDNESS[numericId]` are deliberately never
cleared, so a world cell that still contains that numeric id keeps
rendering and behaving exactly as it did before removal — **existing world
cells of a removed block type are never silently corrupted or reinterpreted
as a different block.** This is the "orphan/tombstone... until world
reload" behavior the spec explicitly allows, and Runtime 0.2 documents it
rather than pretending it solves world migration: a removed block type's
old placements are inert history for the rest of the page session. A Mod
that tries to `api.world.setBlock(...)` a tombstoned id gets a clean
`UNKNOWN_BLOCK_ID` — the existing 0.1 behavior for any unknown string id,
unchanged.

Entity type removal is simpler and *is* fully cleaned up: because every
instance of the old Mod's spawned entities is already destroyed during
owned-resource cleanup (see below) before a revision's `setup()` even runs,
a tombstoned entity type has no live instances anywhere that could still
reference its old `tick`/model — so its `entityTypeDefs` Map entry is
deleted outright (not just hidden), and `api.entities.spawn()` of that
now-removed type correctly throws `UNKNOWN_ENTITY_TYPE` going forward.

No numeric slot is ever reused for an unrelated later registration (freed
or not) — reusing a tombstoned block's old slot for a completely different
new block would silently reinterpret any surviving world cells still
holding that numeric byte, which is exactly the corruption the spec
forbids. Growing `byNumeric` forever is the accepted, documented cost.

## Transaction lifecycle

`ModHost.reviseMod(targetModId, modDef)` (called from
`ImportManager.confirmRevision`, itself fed by
`ImportManager.beginRevisionImport` — the import-side pair mirroring
`beginImport`/`confirmImport`):

```
revised .vmod source
    ↓ captureDefinition()               (ImportManager.beginRevisionImport)
    ↓ ModHost.validateRevision()        -- READ-ONLY, never touches old Mod
    ↓ [Workshop: Replace Mod preview -- permission delta, Cancel/Replace]
    ↓ ModHost.reviseMod()               (ImportManager.confirmRevision)
        snapshot pre-revision owned block/entity ids
        stop() + cleanupOwned() the OLD Mod's dynamic resources only
        mods.delete(targetModId)
        beginRevision(targetModId) on both Registries
        activate(newModDef, newManifest)   -- runs the NEW setup()/start()
        endRevision()
        ├─ ok   → tombstone ids the new setup() didn't touch → COMMIT
        └─ fail → tombstone ids the FAILED setup() newly added
                  → beginRevision(targetModId) again
                  → activate(OLD modDef, OLD manifest)  -- re-run old setup()/start()
                  → endRevision()
                  ├─ ok   → REVISION_SETUP_FAILED, rollback:'success'
                  └─ fail → REVISION_ROLLBACK_FAILED, rollback:'failed'
```

`validateRevision(targetModId, modDef)` mirrors `validate()` (manifest
shape, `apiVersion`, dependencies, conflicts) but replaces the
`DUPLICATE_MOD` check with a **manifest.id-must-match-target** check, and
never touches `mods`, the old Mod, or either Registry. This is what makes
"validate before touching the old Mod" a hard guarantee rather than a
best-effort ordering: a syntax error, a manifest shape problem, an API
version mismatch, or a missing dependency in the revised source is rejected
here, before `reviseMod` has done anything at all. Confirmed live by
acceptance Tests E/F/G below — the old Mod is provably still running (its
`game.tick` listener keeps firing, unbroken) through every one of these
rejection paths.

**Manifest identity is mandatory, version is advisory.** `validateRevision`
rejects `manifest.id !== targetModId` with `REVISION_ID_MISMATCH` — an
Agent that returns `demo.magic-v2` for a `demo.magic` revision request gets
a clear, distinct error, and the old Mod is untouched (this case never even
reaches `reviseMod`). `manifest.version` is recorded (old → new shown in
the Workshop preview) but never validated or compared — Runtime 0.2 does
not require a version bump, does not compare semver, and does not reject a
same-version revision. Agents routinely forget to bump versions; that's a
UX nit, not a correctness problem.

## Rollback mechanism

On failure, Runtime 0.2 does **not** attempt to resurrect the old Mod's
live JS state (closures, subscriptions, timer handles) from a snapshot —
that is fragile and, for closures specifically, not really possible to
snapshot at all. Instead it **re-runs the old Mod's retained `modDef`**
(the exact object still held by the `mods` map entry, with its original
`setup`/`start`/`stop`/`unload` function references) through the same
`activate()` used for any normal activation. This is the same mechanism
that makes revision itself work — rollback is just "revise back to the
identical old version," using the *live definition object* Runtime already
holds, not the retained *source text* (though the source text is also
retained, in the `ImportRecord`, and used to regenerate a fresh revision
prompt or a fix prompt for the next attempt).

Because rollback re-runs `setup()` inside another `beginRevision`/
`endRevision` window for the same `targetModId`, its own
`blocks.register()`/`entities.registerType()` calls hit the exact same
replace-in-place path — restoring each definition's original fields at its
original numeric id, with no special-casing needed for "restore" as a
separate code path from "revise."

Storage, world blocks/entities placed outside owned tracking, and every
*other* Mod are never touched by rollback (or by a successful revision) —
see "World state" and "Multi-Mod isolation" below.

## Rollback failure

If the OLD Mod's own re-`activate()` also throws (a pre-existing, unrelated
bug in the old Mod's `setup()`, or some very unlucky Registry state), this
is reported as `REVISION_ROLLBACK_FAILED` — the Mod is left stopped
(removed from `mods`), a clear structured error is logged, and — critically
— nothing here throws out of `reviseMod`, so the Runtime keeps running and
every *other* Mod is completely unaffected. This is the one case where a
revision can leave a Mod non-functional; it requires two independent
failures (new version breaks AND the previously-working old version now
also breaks) and is documented as the sole such case.

## World state

Ordinary gameplay state (`world`'s `Uint8Array`, the player, other Mods'
entities) is never touched by a revision beyond what the revised Mod's own
`setup()` explicitly does. The world is never regenerated to reload one
Mod. This is why numeric-id preservation (above) matters: a block a Mod
placed stays exactly where and what it was unless the revision's own code
changes it.

`inventory[numericId]` (the player's held count of a block/item) is reset
to `0` only the **first** time a numeric id is registered — a revision that
reuses the same numeric id (the normal case) leaves the player's existing
carried count untouched. Resetting it on every revision would be a visible,
unwanted gameplay regression every time a Mod is revised.

## Storage

`api.storage` is namespaced by `manifest.id` and was already never cleared
on `unload()` in 0.1 ("ownership means namespace isolation, not data
destruction"). Revision changes nothing here: old and new versions with the
same `manifest.id` naturally read/write the identical storage namespace,
with no special revision-aware code at all. This means a Mod author can use
`api.storage` deliberately as a migration mechanism (e.g. bump a stored
`schemaVersion` field and branch on it in the new `setup()`) if their
revision changes what shape of data it expects — Runtime 0.2 does not do
this for them, it just never gets in the way.

## Entity instance reset

Successful revision removes every entity instance the old Mod had spawned
(as part of the same owned-resource cleanup `unload()` already used in
0.1 — `cleanupOwned(owned)` iterates `owned.entities` and calls
`removeEntity` for each). **Runtime 0.2 does not serialize or revive entity
instance state across a revision.** If the revised `setup()` wants
instances to exist again, it must spawn them itself, exactly as the
original `setup()` did. This is a deliberate scope decision, not an
oversight — attempting instance-state migration is explicitly out of scope
for this milestone. Generic world/player state is unaffected.

## Multi-Mod isolation

Revising Mod A never touches Mod B's timers, event subscriptions, UI, or
entities. `reviseMod` only ever calls `stop()`/`cleanupOwned()` on the
*target* Mod's own `owned` set and only ever opens a `beginRevision` window
scoped to the target Mod's own id — every other Mod's registry entries,
`owned` set, and `mods` map entry are never read or written. Verified live
(see acceptance Test I) by revising one Mod while a second, unrelated Mod's
`game.tick` counter and HUD marker kept running completely undisturbed
throughout.

## Repeated revisions

Revising the same Mod repeatedly (V1→V2→V3→V4, no reload) leaks nothing:
each revision's `beginRevision`/`endRevision` window is short-lived and
self-contained; only the *current* version's subscriptions/timers/UI/entity
instances are ever alive at once (every prior version's were torn down by
the *next* revision's own `stop()`+`cleanupOwned()` step, one hop back, same
as any single revision); the Mods-tab row count never grows (see "Workshop
revision UX" below — a revision folds into the one canonical
`ImportRecord`, it never adds a new row); and Registry numeric ids stay
stable and coherent (verified live, acceptance Test J).

## Revision source history

Each canonical `ImportRecord` for a revisable Mod now also carries:

- `previousSource` / `previousManifest` — the immediately-prior version.
- `history` — a bounded array (last 5) of prior source strings, oldest
  dropped first.

This is intentionally lightweight page-session bookkeeping, not source
control — no diffing, no branches, no persistence beyond the current
Runtime session. It exists to make a future "Undo Last Revision" a small,
natural addition (revise back to `previousSource` through the exact same
`reviseMod` transaction) without requiring new transaction machinery.
**"Undo Last Revision" itself is not implemented in this checkpoint** — the
spec marks it explicitly optional, and skipping it kept the core
transaction semantics simpler to get right and thoroughly test. The history
field is not serialized into `.vgame`/baked `.html` output (see "Package
Format interaction" below).

## Workshop revision UX

- **Revise with Agent** (Mods tab) is only offered for a Mod with a
  retained `ImportRecord.source` — the same precondition "View Source"
  already had in 0.1. A built-in Mod (`?mods=1` dev fixtures, or one
  registered via a raw `<script>` calling `defineVoxelMod` directly) has no
  retained source to build a revision prompt from or diff against, exactly
  the pre-existing 0.1 limitation for "View Source."
- Clicking it switches to the Create tab in **revision mode**
  (`revisingModId` set): "Generate Agent Prompt" now calls
  `runtime.vmp.generateRevisionPrompt` instead of `generatePrompt`, and
  the `.vmod` drop zone routes through `beginRevisionImport`/
  `confirmRevision` instead of `beginImport`/`confirmImport`.
- Dropping a file in revision mode never silently replaces anything — it
  shows a **Replace Mod** preview: Mod name, `oldVersion → newVersion`,
  and the full permission list, with **`+ permission`** highlighted for
  anything newly requested (and **`− permission`** for anything dropped),
  plus a "New permissions requested" notice when applicable. Only
  `[Cancel]` / `[Replace Mod]` proceeds; Cancel leaves the old Mod running
  untouched and **stays in revision mode** so the user can drop a
  corrected file without re-clicking "Revise with Agent."
- **No pre-commit resource-change (reused/added/removed) preview.**
  Computing it before commit would require actually running the new
  `setup()` — exactly the one action this whole preview screen exists to
  gate behind explicit confirmation — which is precisely the "duplicate
  the Registry into a speculative dry-run engine" complexity this spec's
  Registry design deliberately avoids. Permissions, unlike resources, are
  known statically from both manifests without running anything, so they
  *are* shown pre-commit. The resource-change summary (Reused/Added/
  Removed, block and entity ids only — never internal numeric ids) is
  instead shown honestly, from real post-commit data, on the result panel
  immediately after a successful replace.
- On success, a revision is **folded into the target Mod's existing
  canonical `ImportRecord`** (source/manifest/filename updated in place,
  `previousSource` stashed) — it never becomes a second Mods-tab row for
  the same Mod.
- On failure, the attempt is **never** added to the Mods-tab list at all
  (ephemeral) — the failure is shown immediately as a result panel in the
  Create tab, with a distinct banner stating what happened to the *old*
  Mod (never touched / restored / restore also failed — see "Error model"
  below), reusing the existing "Copy Error"/"Copy Fix Prompt" machinery
  unchanged.

## Error model

Revision introduces four new codes, layered on top of (not replacing) the
existing VMP/1 structured-error codes, which continue to appear unchanged
as the underlying cause where applicable (e.g. a revision whose `setup()`
throws still reports the real `SETUP_EXCEPTION` from that attempt as
`errors[0]`, exactly like an ordinary import failure would):

- `REVISION_ID_MISMATCH` — revised `manifest.id` doesn't match the Mod
  being revised. Never touches the old Mod.
- `MOD_NOT_FOUND` — the revision's target Mod isn't currently loaded
  (rare/edge case; e.g. it was unloaded in another tab/flow between
  opening the revision UI and confirming). Never touches anything.
- `REVISION_SETUP_FAILED` — a **phase**, not a code on the error entry
  itself: the new version's `activate()` failed (see its own `errors[0]`
  for the real code/message) but the old version was **successfully**
  restored. Surfaced to the player as "Revision failed" + "Previous
  version restored."
- `REVISION_ROLLBACK_FAILED` — both the new version AND restoring the old
  version failed. Surfaced as "Revision failed" + a severe "restoring the
  previous version also failed" notice. The Mod is left stopped; nothing
  else in the Runtime is affected.

Human-facing text is generated the same way 0.1.1 already established for
every other structured error: **code → i18n key → localized renderer**,
never a hand-scattered sentence inline at the throw site. See
`I18N_SPEC.md` — the same rule, extended with the same discipline, not a
parallel error model.

## Package Format 1 / .vgame / Bake interaction

Package Format 1 is unchanged: an included Mod is still exactly
`{manifest, source}`, one source string per Mod. `previousSource`/`history`
are fields on the *Runtime-session* `ImportRecord` only — `buildGamePackage`
reads `record.manifest`/`record.source` (the *current* version) exactly as
it did in 0.1, and neither of those two new fields, nor a Mod's revision
count, is ever written into an exported `.vgame` or a baked standalone
`.html`. Verified live: a session with a Mod revised 4 times, baked, embeds
only that Mod's final (v4) source — confirmed by inspecting the payload
directly (no `previousSource`/`history` keys present, source text does not
contain the string `"1.0.0"` from the discarded V1). A receiver opening
that baked game (or re-imported `.vgame`) sees one Mod, at its latest
version, with no session revision history — exactly as if it had been a
plain first-time import.

## Ordinary import regression

Plain `Import .vmod` (`beginImport`/`confirmImport`/`importSource`/
`importFile`) is untouched code, calling the exact same functions it called
in 0.1.1. A second ordinary import of an already-loaded `manifest.id`
still throws `DUPLICATE_MOD` (if attempted while still active) or
`DUPLICATE_ID`→`DUPLICATE_DEFINITION_ON_REIMPORT` (if attempted after
`unload()`, since Option B — persistent definitions — is unchanged).
Verified live: importing a duplicate `manifest.id` through the plain drop
zone (not via "Revise with Agent") still fails exactly this way.

## Testing requirements / acceptance test results

All tests below were run live in a real browser session (not simulated),
using the actual Workshop UI (file drop → preview → confirm), with
`api.events.on('game.tick', ...)` counters as an always-firing (no
pointer-lock required) observable proxy for "is this specific
subscription/tick-closure still alive," since `api.time.after/every` only
ticks during active (pointer-locked) gameplay, which headless browser
automation cannot trigger. This is a testing-infrastructure limitation
already inherent to Runtime 0.1's timer semantics, not something Runtime
0.2 changes; the exact same `cleanupOwned`/`owned.timers` code path is
exercised structurally in every test that registers a timer, just not
observed via live fire-count for that specific API.

| Test | Result |
|---|---|
| A — simple revision (event listener swap) | **Pass** — old `game.tick` listener count frozen post-revision, new one active, single HUD marker, same `manifest.id` |
| B — UI/timer revision | **Pass** — HUD replaced with no duplication; `api.time.every` registration/cleanup completes without error (see note above on timer-firing verification limits) |
| C — entity type revision | **Pass** — old spawned instance's tick closure verified dead (counter frozen) after revision; new instance (new tick fn, new color, reduced speed) ticking; also doubled as the real Agent-revision test (below) |
| D — block definition revision (**most important**) | **Pass** — same public id, same numeric slot (existing world cell keeps resolving `revtest:crystal` with zero regeneration), new hardness/texture applied (verified via a new atlas tile index), result panel correctly reports "Reused: revtest:crystal" |
| E — failed revision (`setup()` throws) | **Pass** — new version's listener/HUD never persisted; old version's listener/HUD fully restored and running; "Previous version restored" shown |
| F — invalid file (syntax error) | **Pass** — old Mod's listener kept firing uninterrupted throughout; "The previous version was never touched" shown (distinct from Test E's restored-after-touch case) |
| G — permission change | **Pass** — `+ world.write` highlighted with "New permissions requested"; Cancel left old Mod untouched and stayed in revision mode; approving proceeded normally |
| H — definition removal | **Pass** — result panel correctly reports "Reused: block_a" / "Removed: block_b"; `block_b`'s existing world cell still resolves correctly (not corrupted); `api.blocks.get`/`list` correctly stop exposing `block_b` for new use |
| I — multi-Mod isolation | **Pass** — an unrelated Mod's `game.tick` counter and HUD marker ran continuously, unaffected, through two other Mods' revisions |
| J — repeated revisions (V1→V2→V3→V4) | **Pass** — only the latest version's listener/HUD alive at any time; Mods-tab row count stayed at one per Mod (no leak) |
| Real Agent revision test | **Pass** — generated an actual `zh-CN` revision prompt via the Workshop for a live Chinese-language request ("把敌人移动速度降低 30%，并且生命值低于 5 时显示红色警告。"), produced a genuine complete replacement `.vmod` honoring every hard requirement (id unchanged, full file not a diff, preserved existing chase/damage behavior, only documented APIs), imported it through the real Replace Mod flow, and verified the new tick behavior replaced the old one transactionally. Zero repair rounds needed. |

"Undo Last Revision" (spec-optional) was not implemented this checkpoint —
see "Revision source history" above.

## i18n

All new revision UX strings live in `I18N_MESSAGES` under existing families
(`workshop.create.*`, `workshop.errors.*`, `errors.*`) — no new top-level
family was needed. Both `en-US` and `zh-CN` are complete (verified by the
existing `?dev=1` completeness audit, which reports catalogs in sync after
this milestone's additions) and were exercised live end-to-end: the entire
"Revise with Agent → Replace Mod preview → permission delta → result →
error" flow was run once in English and once in Chinese, including a real
Agent-revision round-trip conducted entirely in `zh-CN`. See `I18N_SPEC.md`
for the general contract this extends unchanged.

## Runtime 0.2.0-dev — Creation Workspace addendum

Nothing in this document's transaction engine (`ModHost.reviseMod`,
`validateRevision`, the Registry replace/tombstone path) changed for the
Creation Workspace milestone. Restoring a `.vwork`'s Mods reuses the
*ordinary* `ImportManager.importSource()` path (the same one `.vgame`
import and baked-boot already use), never this document's revision
transaction directly — a Workspace establishes the STARTING state a session
boots into; every revision made *after* that point still goes through
exactly the pipeline described above. See `WORKSPACE_SPEC.md`.
