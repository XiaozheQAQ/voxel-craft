# Runtime Architecture

Internal architecture source of truth. If code and this doc disagree, fix
one or the other before moving to the next phase — no silent divergence.

## Module graph (all inside the one `<script>` in index.html)

```
VoxelRuntime (const runtime, declared before the World data section)
├─ runtime.registry   BlockRegistry (items alias blocks — no separate ItemRegistry, see below)
├─ runtime.events     EventBus (per-listener error isolation, see § EventBus internals)
├─ runtime.time       Runtime-owned scheduler (after/every/cancel/tick), driven from loop()
├─ runtime.world      facade over getBlock/setBlock/isSolid/generateWorld/raycastBlock — numeric ids
├─ runtime.player     facade over pos/yaw/pitch/velY/grounded/health/inventory — numeric ids
├─ runtime.blocks     registry sugar: register/get/list (custom blocks land on spare atlas tiles)
├─ runtime.items      alias of runtime.blocks — no separate identity in v0.1 (final decision, not interim)
├─ runtime.entities   lightweight data-driven store + own tick, Map-based, not an ECS
├─ runtime.ui         text-only HUD/toast/banner/panel helpers, no HTML injection surface
├─ runtime.input      isKeyDown + on('keydown'|'keyup', {code}) — small Runtime-generated payload
├─ runtime.effects    flashScreen only; shake/particleBurst/explosion remain Planned, not stubbed
├─ runtime.audio      absent from real functionality — scoped api exposes NOT_IMPLEMENTED-throwing stubs
├─ runtime.storage    namespaced localStorage wrapper, unload-safe (not deleted on mod unload)
├─ runtime.renderer   INTERNAL ONLY, never exposed to mods — wraps buildMesh/rebuildWorldMesh/gl state
├─ runtime.modHost    defineVoxelMod + validate/activate split + lifecycle + permission gating + ownership tracking
├─ runtime.mods       ImportManager (.vmod capture/validate/activate) — Runtime-level, NOT api.mods
└─ runtime.vmp        VMP/1 prompt generator, built from PUBLIC_API_META/PUBLIC_EVENT_META — NOT api.vmp
```

Two more top-level data structures exist alongside `runtime.*` but are
plain consts, not namespaced under it: `PUBLIC_API_META`/
`PUBLIC_EVENT_META`/`CAPABILITY_META` (Phase 8.5 — the machine-readable
source both `RUNTIME_API.md` and `runtime.vmp.generatePrompt` are kept in
sync against).

Design rule: existing function bodies are **wrapped, not rewritten**. A
facade method calls the original closures verbatim; only call sites (mining,
placement, regen button, etc.) get rewired to go through the facade, one at
a time, each verified against `TEST_MATRIX.md` before the next.

## Vibe Workshop (Phase 10)

`WorkshopController` is a UI layer, not a Runtime module — it lives in
`index.html` alongside everything else (single-file constraint unchanged)
but is documented separately in **`WORKSHOP_UX.md`**, which is the
source of truth for its behavior/lifecycle decisions. It is a pure
consumer of `runtime.vmp`, `runtime.mods` (including two Phase-10-added
primitives, `beginImport`/`confirmImport`, which split Phase 8's
`importSource` into a preview-before-activate pair with zero `ModHost`
changes), and `ModHost` — it duplicates no prompt/validation/permission
logic. See `WORKSHOP_UX.md` for entry point, pointer-lock/timer-pause
behavior, permission preview, mod management semantics (and why there is
no enable/disable toggle), error UX, and the revision workflow.

## Current status

**Phases 1-10 (plus 6.5 reconciliation) are done and browser-verified.**
`EventBus`/`BlockRegistry` (Phase 1), core blocks mirrored into the
registry (Phase 2), `runtime.world`/`runtime.player` facades with the
collapsed mesh-rebuild funnel (Phase 3), `ModHost`/`defineVoxelMod` with
real event emission at gameplay call sites (Phase 4), permission gating +
ownership tracking + `unload` (Phase 5), custom blocks/items/entities
(Phase 6), the numeric→string mod-facing boundary + `player.step` +
ownership/reload-semantics reconciliation (Phase 6.5),
`time`/`ui`/`effects`/`storage`/`input` + an EventBus error-isolation fix
(Phase 7), `.vmod` import via a capture/validate/activate transaction
(Phase 8), machine-owned API metadata that immediately caught a real
`api.storage` permission-gating bug (Phase 8.5), VMP/1 prompt generation
built from that same metadata (Phase 9), and the Vibe Workshop UI
consuming all of it (Phase 10) all exist. See `RUNTIME_PLAN.md` for
per-phase status and `MIGRATION_NOTES.md` 001-010 for details. All five
mod acceptance tests (A-E) pass, plus a documentation-only agent
simulation (a new mod written from the generated prompt alone, imported
through the real import pipeline). **Runtime 0.1 is a declared Release
Candidate** as of the Phase 10 RC audit — see the chat checkpoint report
for the full assessment. Work stops here by design — Bake-to-HTML,
community publishing, LLM provider integration, a real sandbox, and
hot-reload are all explicitly out of scope for this milestone.

## The internal/public identity boundary (Phase 6.5)

This is the single most important architectural rule in the codebase, so
it gets its own section rather than living only in a migration note.

**Internal representation, unchanged since Phase 0**: `world` is a flat
`Uint8Array`; `BLOCK_TILES`/`BLOCK_HARDNESS`/`inventory` are numeric-id-
keyed plain objects; `BLOCK.GRASS === 1`, etc. Every hot path — meshing,
physics/collision, mining/placement's own bookkeeping, the hotbar —
reads and writes these numeric ids directly, exactly as it always has.
`runtime.world` and `runtime.player` (the internal facades introduced in
Phase 3) also speak numeric ids; they are thin wrappers over the original
functions, not a translation layer.

**Public representation, at exactly one seam**: `ModHost.buildScopedApi()`
is the only place numeric↔string translation happens. It wraps
`runtime.world.getBlock/setBlock` and `runtime.player.getInventory/
giveItem/takeItem` so that whatever a mod's `setup(api)` receives always
speaks string ids (`"core:stone"`, `"example:crystal"`, ...), via
`toPublicBlockId(numericId)`/`toInternalBlockId(stringId)` (thin wraps
over `BlockRegistry.toString`/`toNumeric`, defined right after the core
block registration block). `block.break(.before)`/`block.place(.before)`
event payloads and `player.step`'s payload are translated the same way,
at their emit sites in `updateMining`/`tryPlace`/`updatePhysics`.

**Why this split and not a full string migration**: rewriting `world` to
store strings would blow up memory and the meshing hot loop for zero
benefit — nothing internal needs string identity, and every mod-visible
surface already gets it for free at the one boundary that matters. This
was flagged and fixed in Phase 6.5 after Phase 6's own acceptance test
(`dev.crystalblock`) was found using a numeric id, which contradicted
`VMP_SPEC.md`'s promise. See `MIGRATION_NOTES.md` 007A.

## Items: a final decision, not a placeholder

`api.items.register`/`api.items.get` are explicit **aliases** of
`api.blocks.register`/`get`. There is no `ItemRegistry`. This was
originally going to be revisited "later," but Phase 6.5's documentation
audit converted that into a final decision: the base survival game
already treats "block you mined" and "carryable inventory entry" as the
same thing, and a parallel registry with no distinct behavior would be
unused scaffolding. If a future phase needs item-only concepts (stacking
rules, non-placeable consumables, durability), that's a new design
question to raise then, not a debt owed by v0.1.

## ModHost internals

`ModHost.buildScopedApi(modId, permissions, owned)` builds one fresh
scoped `api` object per mod. Two composable mechanisms layer on top of
`runtime.*`:

- **`gate(modId, granted, namespace, methods, overrides?)`**: for each
  method, if `PERMISSION_MAP[namespace.method]` is unset or the mod
  declared it, use `overrides[method]` (if provided) or the raw method;
  otherwise substitute a stub that reports+throws structured
  `PERMISSION_DENIED`. `overrides` is how the string-id translation and
  ownership-tracking wrappers compose with permission checks without
  duplicating the check logic — the override function calls through the
  gated method (or stub) internally, so denial still happens correctly.
  `storage` is gated this same way as of Phase 8.5 (see § Known
  limitations for the bug this fixed).
- **`owned` record**: `{subs, entities, timers, hud, panels}`, five
  `Set`s per mod. `events.on/once` and `input.on` all route through one
  shared `trackedSub()` (same unsubscribe-closure shape); `entities.spawn`,
  `time.after/every`, `ui.setHudText/addPanel` each add their handle/id
  to the matching set. `cleanupOwned(owned)` iterates all five and calls
  the appropriate cleanup (`unsubscribe()`, `timeScheduler.cancel`,
  `removeEntity`, `removeHudText`, `removePanel`) — shared between
  `unload()` and `activate()`'s setup-failure rollback (Phase 8, see
  below). **`storage` is deliberately absent from `owned`** — unload
  never deletes a mod's persisted data; ownership there means namespace
  isolation only.

**`validate`/`activate` split (Phase 8)**: `ModHost.register(modDef)` —
the path the production global `defineVoxelMod` uses — is now just
`validate(modDef)` (manifest shape, duplicate id, `apiVersion`,
`dependencies`, `conflicts` — everything checkable before `setup()` may
run) followed by `activate(modDef, manifest)` (builds the scoped api,
runs `setup()`/`start()`, stores the mod). Both are exposed on the
returned `ModHost` object so the `.vmod` import pipeline (§ below) can
call `validate()` on a captured-but-unactivated definition and only call
`activate()` if validation passed — this is the actual mechanism that
makes "validate before activation" true rather than aspirational.
`activate()` rolls back any owned resources a throwing `setup()` created
via `cleanupOwned` before reporting the failure. A `setup()` that fails
because of a registry `DUPLICATE_ID`/`PROTECTED_NAMESPACE` (i.e. a mod
re-registering a definition it created in a previous, now-unloaded,
instance) gets a friendlier `DUPLICATE_DEFINITION_ON_REIMPORT` error
instead of the bare registry code.

`defineVoxelMod` is the one symbol deliberately exposed on `window` (not
closure-private) — any mod manually included via a `<script>` tag calls
it directly, immediately registering. This is a *different* path from
`.vmod` import: `runtime.mods.importSource()` (§ below) deliberately does
NOT go through this global; it captures with a local collector instead,
specifically so activation can be deferred past validation.

**Reminder — permissions are still not a sandbox**: gating only blocks
*accidental or undeclared* use of Runtime capabilities through the scoped
api. A mod that ignores the Agent Contract can still reach `window`/`gl`
directly, same JS realm. Never describe this as sandboxed in any
user-facing text (VMP_SPEC.md, in-game UI, docs).

## `.vmod` import pipeline (Phase 8)

```
File --File.text()--> source
  --captureDefinition()--> exactly one ModDefinition (or a structured failure)
  --ModHost.validate()--> validated manifest (or a structured failure)
  --ModHost.activate()--> running mod (or a structured failure, with rollback)
```

`captureDefinition(source)` is the mechanism that makes "validate before
activation" real rather than a naming convention:

```js
function captureDefinition(source){
  const definitions = [];
  function collector(def){ definitions.push(def); }
  const fn = new Function('defineVoxelMod', '"use strict";\n' + source);
  fn(collector);
  // definitions.length must be exactly 1
}
```

`new Function('defineVoxelMod', source)` compiles `source` as a function
body with `defineVoxelMod` as a **parameter name**. Inside that function
body, any `defineVoxelMod({...})` call resolves to the local parameter
(here, `collector`), not the real global of the same name — parameter
bindings shadow the outer/global scope. A normal, VMP-compliant `.vmod`
therefore cannot reach `ModHost.register` during capture; its `setup()`/
`start()` literally cannot run until this Runtime explicitly calls
`ModHost.activate()` on the definition it collected.

**This is a capture mechanism for lifecycle separation, NOT a sandbox.**
`new Function` still compiles and runs the source in the page's real
global scope — every other statement in the source executes exactly as
normal top-level JS would (a mod that ignores the Agent Contract and
references `window`/`document`/`fetch` directly still can, during
capture just as much as during activation). Only the `defineVoxelMod`
identifier specifically is intercepted. Never describe `captureDefinition`
as sandboxing in any user-facing text — same rule as the permission
gating reminder above, and for the same underlying reason (same JS
realm, always).

`ImportManager` (`runtime.mods`) drives this pipeline and produces an
`ImportRecord` per attempt: `{recordId, id, filename, source, manifest,
status, importedAt, errors}`, `status` one of `captured → validated →
active`, or `failed` at whichever step didn't pass. Source text is kept
in memory for the page session (useful for a future inspect/revise flow)
but never written to `localStorage` automatically. `runtime.mods` is
Runtime-level infrastructure, deliberately **not** `api.mods` — a
third-party mod has no legitimate reason to import or manage other mods.

**No enable/disable toggle exists**, and Phase 10 should not propose one
without extending v0.1's lifecycle semantics first: see § Definition
registration vs. runtime instances below. `unload()` is the only
supported operation on an active mod, and it is one-way within a page
session for any mod that registered persistent definitions.

## VMP/1 prompt generation (Phase 9)

`runtime.vmp.generatePrompt(userRequest)` — Runtime-level, not
mod-facing (`runtime.vmp`, not `api.vmp`) — assembles all 7 VMP/1
sections by reading three plain data structures, never hand-duplicated
prose:

- `PUBLIC_API_META` (Phase 8.5): one entry per method —
  `{namespace, method, signature, status, permission, description}`.
- `PUBLIC_EVENT_META` (Phase 8.5): one entry per event —
  `{name, status, payload, cancelable, emitter, description}`.
- `CAPABILITY_META` (Phase 9): one entry per permission —
  `{permission, enforced, description}`. `enforced:false` marks
  `audio`/`network` as declarable-but-inert, honestly.

`[VMP API SPEC]`/`[VMP EVENTS]` filter both arrays to `status !==
'Planned'` for the main list, with a compact name-only `UNAVAILABLE /
PLANNED` list appended — a smaller, accurate prompt over a larger,
aspirational one. `[INSTALLED MODS]` reads `ModHost.listDetailed()`
(id/version/name only, never source — dumping every installed mod's full
source into every generated prompt would scale badly; a future
"Revise this mod" feature can selectively attach one mod's source
instead, not built here). `deriveResourceNamespace(manifestId)` is a
real function, not prose: lowercases `manifest.id` and collapses every
non-alphanumeric run to one `_` (`"alice.magic-tools"` →
`"alice_magic_tools"`), and the System Contract section's worked example
is computed through this exact function — the stated rule and the
applied rule are the same code, cannot drift from each other.

This is *why* Phase 8.5 came before Phase 9: `PUBLIC_API_META` existing
first, and being audited against `PERMISSION_MAP` before the prompt
generator was written, is what caught the `api.storage` gating bug (see
§ Known limitations) before it could have been baked into a
generated prompt as "here's how storage works" while being silently
wrong at runtime.

## Definition registration vs. runtime instances (Phase 6.5, Part A5)

`blocks.register`/`items.register`/`entities.registerType` create
**definitions** (registry entries, atlas tiles, entity-type mesh
buffers). `entities.spawn`/`world.setBlock` create or reference
**instances**. `ModHost.unload` cleans up instances a mod owns (spawned
entities) but **never** undoes definition registrations — there is no
`unregister`. This was a deliberate, smallest-correct-design choice
(Option B from two offered): a mod that registers `example:crystal`,
gets unloaded, and is loaded again will hit `DUPLICATE_ID` on its second
`blocks.register` call. Hot-reloading a definition-owning mod is **not
supported** in v0.1 — building it correctly would mean tracking which mod
owns which registry entry and deciding what happens to existing world
cells/entities of that type when the definition is pulled, a materially
bigger design than this reconciliation pass warranted. This matters for
the Phase 10 Vibe Workshop iteration loop and is called out there as a
known constraint, not forgotten.

**Phase 8 addendum**: this exact `DUPLICATE_ID` now surfaces through
`.vmod` re-import with a human-readable explanation
(`DUPLICATE_DEFINITION_ON_REIMPORT`, see § ModHost internals) instead of
the bare registry code — the underlying limitation is unchanged, only the
error message a player/agent sees improved.

## Registry internals

String id (`"core:stone"`) is the public identity. Numeric id stays the
internal storage key — required because `world` is a `Uint8Array` and
`BLOCK_TILES`/`BLOCK_HARDNESS` are numeric-indexed hot-path arrays; a
string-keyed world array would blow up memory and the meshing hot loop.

`createIdRegistry` maintains `byString: Map<string,number>` and
`byNumeric: array`, assigns numeric ids sequentially starting at 0, rejects
duplicate string ids, rejects ids that don't match `namespace:id`, and
rejects registration under the `core` namespace unless called inside
`withCoreRegistration(fn)` (used only by Runtime boot code, never by mods).

`BlockRegistry.register()` was called for `core:air`, `core:grass`,
`core:dirt`, `core:stone`, `core:sand`, `core:wood`, `core:leaves` **in
that exact order** during boot, so the resulting numeric ids (0-6) are
byte-identical to the original `BLOCK` enum — `BLOCK.GRASS === 1` and
`BlockRegistry.toNumeric('core:grass') === 1`, provably, by construction
(asserted at boot via `CORE_ID_MISMATCH`, which has never fired). Custom
blocks registered by mods (`blocks.register`) continue the same sequence
(`example:crystal` got numeric id `7`, the first id after core's 0-6).

## EventBus internals

`Map<name, Set<fn>>`. `on()` returns an unsubscribe closure. `game.tick`
reuses one mutated `{dt}` object per frame — no per-frame allocation.
Cancelable `.before` events (`emitCancelable`) reuse a single shared event
object (`name/data/cancelled/cancel()`), safe only because emission is
fully synchronous — no async listeners are supported, a documented
constraint, not an oversight.

**Per-listener error isolation (Phase 7, Part G)**: both `emit` and
`emitCancelable` route each listener call through a shared `safeInvoke()`
that catches per-listener, reports via `VmpErrorLog` (attributed to the
owning mod via a `fn.__vmpModId` tag set by `buildScopedApi`'s
`trackedSub`), and continues to the next listener. A throwing `.before`
listener is treated as non-cancelling, not as "block the operation" —
the operation still proceeds unless a *different* listener legitimately
calls `.cancel()`. This was a real bug found during the Phase 7 audit,
not a preexisting design: before the fix, a throwing listener silently
broke every other listener on that event *and* propagated the exception
out to the emit call site — which is called from real gameplay code
(`updateMining`, `tryPlace`, `applyDamage`, `updatePhysics`, `loop()`).
See `MIGRATION_NOTES.md` 007B.

`VmpErrorLog` (defined once, near the top of the file, before
`BlockRegistry`) is the single shared structured-error sink used by
`ModHost`, the time scheduler, entity tick, `runtime.storage`, and
`EventBus` — one log, one shape, matching `VMP_SPEC.md`'s Error Model.

## Time scheduler internals (Phase 7)

`timeScheduler` (`runtime.time`) is a `Map<handle, {type, remaining,
interval, fn, ownerId}>`, ticked once per frame via `timeScheduler.tick(dt)`
called from `loop()` — but **only inside the `if(locked && !isDead)`
branch**, matching where the pre-Phase-7 passive-regen accumulator used
to live. This is a deliberate clock-semantics decision, not an oversight:
`api.time` timers (and the internal `'core'`-tagged passive regen timer
built on the same scheduler) pause whenever the pointer isn't locked
(menu open) or the player is dead, and resume exactly where they left
off. A mod's 60-second countdown genuinely cannot drain in the
background while a player has the menu open. `after` timers self-delete
on fire; `every` timers reschedule by re-adding their interval (not
resetting to a fresh full interval), so a slow frame doesn't cause drift
accumulation. Timer callback exceptions are caught per-callback and
reported via `VmpErrorLog`, tagged with the owning mod id (or `'core'`
for the internal regen timer) — one bad timer cannot stop the scheduler
or any other timer.

## UI internals (Phase 7)

`runtime.ui` creates a programmatic `#modUiRoot` container (styled to
match the existing `.ore-panel` HUD look) and never accepts HTML from a
mod — every method takes plain text, assigned via `el.textContent`. This
is a deliberate constraint (Part B3 of the Phase 7 brief): raw HTML as
the primary interface would both be an injection surface and make Agent
output unpredictable. Duplicate ids **update the existing element in
place** rather than erroring — the natural behavior for something like a
score HUD line a mod redraws every tick.

## Metadata internals (Phase 8.5) and the audit that caught a real bug

`PUBLIC_API_META`/`PUBLIC_EVENT_META`/`CAPABILITY_META` are plain array
literals (see § VMP/1 prompt generation above for shape). `ModHost`
exposes `getPermissionMap()` (a copy of its private `PERMISSION_MAP`)
specifically so `auditApiMetadata()` — defined outside `ModHost`'s
closure, opt-in via `?dev=1`, never runs by default — can cross-check the
two in both directions: every gated `PERMISSION_MAP` entry must have a
matching `PUBLIC_API_META` entry with the same permission, and every
non-`Planned` `PUBLIC_API_META` entry that claims a permission must
actually be gated. **This caught a real bug the first time it ran**:
`api.storage.get/set/remove` were documented (`RUNTIME_API.md`) and
spec'd (`VMP_SPEC.md`) as gated behind `storage`, but Phase 7's
`buildScopedApi` had built the `storage` object as a bare pre-bound
object, never passed through `gate()` — so the permission was declarable
but had zero effect. Fixed by adding the three `PERMISSION_MAP` entries
and wrapping `storage` in `gate()`, same pattern as every other gated
namespace. This is the audit doing exactly its job: a maintenance-risk
question ("do these three surfaces agree?") turned into a concrete,
fixed bug within the same session it was asked, before Phase 9's prompt
generator could have baked the wrong claim into every generated prompt.

## Known limitations (accepted, not solved in v0.1)

- **`.vmod` capture is not a sandbox**: `captureDefinition()`'s
  `new Function('defineVoxelMod', source)` trick only intercepts the
  `defineVoxelMod` identifier — every other statement in imported source
  runs in the real global scope, exactly like any other same-realm mod.
  See § `.vmod` import pipeline above. Never describe this as sandboxing.
- **Mesh rebuild per `setBlock`**: every mutation triggers a full
  `buildMesh()` remesh (O(W·D·H·6)). The 3 original duplicate call sites
  were collapsed into one funnel (Phase 3) but there is no dirty-chunk
  tracking or batching. Mods that call `world.setBlock` in a tight loop
  will visibly stall the frame (`dev.targetgame` calls it only a few
  times per second, well within budget). Future work: dirty-chunk/batch
  mutation — out of scope for v0.1.
- **Same-realm mod execution**: mods run in the same JS realm as the
  Runtime (no iframe/Worker sandbox). Permissions are a declared-trust
  convention, not enforced isolation. A mod that ignores the Agent
  Contract can still reach `window`/`document`/`gl` directly. Documented
  explicitly in `VMP_SPEC.md` as the v0.x trust model.
- **Mod cleanup completeness**: ownership tracking only catches cleanup
  for calls routed through the scoped API handle. A mod that stashes a
  raw reference outside any tracked call (e.g. holds onto a DOM node it
  built manually, which it shouldn't be able to get in the first place
  since `api.ui` never exposes one — but nothing stops a mod that
  ignores the Agent Contract and touches `document` directly) bypasses
  auto-cleanup.
- **Definition registration has no unregister/hot-reload path** (Phase
  6.5, Part A5): see § Definition registration vs. runtime instances
  above.
- **`solid:false` not honored**: `isSolid()`/`collidesAABB()` (unchanged
  since Phase 0) only check "is this world cell non-AIR" — they never
  consult `BlockRegistry`. A mod-registered non-solid decorative block
  still physically blocks the player. Not fixed in v0.1; would require
  threading a registry lookup into the collision hot path.
- **`file://` storage caveat**: some browsers scope or share
  `localStorage` oddly across all local documents rather than strictly
  per-origin the way http(s) does. The `vmp1:<modId>:<key>` prefix
  prevents different mods' keys from colliding regardless, but true
  cross-page isolation under `file://` is a browser behavior outside the
  Runtime's control. Documented, not solved — the project must keep
  working from `file://` with no server, so this is accepted.
- **Save compatibility**: no save/serialization system exists yet (world
  regenerates from seed each boot), so there is no format to migrate.
  Deferred until a save feature is proposed.
- **Single-file discipline drift**: as namespaces accumulate, enforce
  `/* === runtime.x === */` section comments and keep each facade under
  ~50 lines — a thin wrapper, never a reimplementation.

## Distribution module (`runtime.distribution`)

Added after API 1/VMP 1 froze; full design in `DISTRIBUTION_SPEC.md`.
Lives between the VMP prompt generator and `WorkshopController` in file
order. Not exposed through `api.*` — Mods cannot bake or export the
Runtime. Key invariant: `__pristineDocumentHTML` is captured as the
literal first statement of the whole script, before any other code
touches the DOM, which is what lets Bake avoid ever having to sanitize
live/mutated DOM state (see spec § 3 for why this matters). The embedded-
package container (`<script type="application/x-voxel-game"
id="voxel-game-package">`) sits in the static HTML shell, immediately
before the real `<script>` tag, always present, empty in the plain
Runtime.

**Release Hardening pass (formalized the invariant, fixed real gaps)**:
the capture-site comment now states the invariant explicitly as a rule
("must remain the first executable statement") with the reasoning why,
not just a description of what it does — aimed at stopping a future
edit from casually moving it. Verified live, not just documented: opened
Workshop (creates `#workshopOverlay`) and moved/took damage, then
confirmed the pristine snapshot excludes both while still containing the
full static CSS and script text. Also found and fixed one real
release-blocking gap in this pass: the dev-only raw `.vmod` file-picker
input (predates Vibe Workshop) was shipping ungated on every default
boot; it's now behind `?dev=1` like the metadata-drift audit. And fixed
a comment-injection risk in the new baked-HTML identifying comment (an
HTML comment ends at the first `--`, not `-->`; untrusted title text is
now passed through a small escaping helper before being interpolated).

## Runtime 0.2.0-dev — Transactional Mod Revision

`BlockRegistry`/`EntityTypeRegistry` (both built on `createIdRegistry`)
gained per-entry `ownerModId` + a `removed` tombstone flag, and three new
methods: `beginRevision(ownerModId)`/`endRevision()` (opens/closes a narrow
window in which `register()` may replace-in-place an id already owned by
that same owner, instead of throwing `DUPLICATE_ID`) and `getTouched()`
(the set of ids actually `register()`-ed while that window was open — the
basis for correctly detecting "removed," which a before/after ownership
diff cannot do, since an untouched id's ownership never visibly changes).
`ModHost` gained `validateRevision`/`reviseMod`, and `ImportManager` gained
`beginRevisionImport`/`confirmRevision`, mirroring the existing
validate/activate and beginImport/confirmImport pairs rather than
introducing a parallel pipeline. Outside an open revision window, every one
of these registries and `ModHost.validate`/`activate`/`register` behaves
byte-identically to Runtime 0.1.1 — ordinary `Import .vmod` never opens a
revision window. Full design: `MOD_REVISION_SPEC.md`.

## Runtime 0.2.0-dev — Revision History & Safe Undo

A new internal module, `RevisionHistoryStore`, sits beside `ImportManager`:
one bounded, append-mostly per-Mod list of successfully-committed
`{id, parentId, seq, source, manifestSnapshot, reason, origin}` entries
plus a `currentRevisionId` pointer and a small redo stack — never live
callback/entity/DOM/Registry state, only the retained source text (the
reconstructable snapshot). `ImportManager.confirmImport`/`confirmRevision`
call `RevisionHistoryStore.record()` immediately after a real success (never
for a failed attempt); `ImportManager.restoreRevision`/`undoLastRevision`/
`redoRevision` all funnel through one `restoreToEntry()` helper that re-runs
`captureDefinition` → `ModHost.validateRevision` → `ModHost.reviseMod` on a
historical entry's source — the exact same transaction engine as any other
revision, never a direct Registry mutation. Two real bugs surfaced and were
fixed while building this: `createIdRegistry`'s tombstone path previously
deleted the string→numeric mapping (so a same-owner reactivation of a
removed id got a NEW numeric id instead of reusing the original — fixed by
keeping the mapping and gating on the `removed` flag instead), and
`RevisionEntry.seq` was first computed as ancestry depth (`parent.seq + 1`),
which collides when two branches share a parent (fixed to strict creation
order). Full design, the transaction-boundary audit (what rollback does and
does NOT revert — world/player/storage mutations are NOT undone), and live
test results: `REVISION_HISTORY_SPEC.md`.

## Runtime 0.2.0-dev — Creation Workspace (.vwork)

A new module, `WorkspaceManager`-equivalent functions (`buildWorkspace`/
`exportWorkspace`/`importWorkspace`/`forkWorkspace`/`startRemixWorkspace`,
exposed as `runtime.workspace`), sits beside `runtime.distribution` — a
deliberately separate format (`WORKSPACE_FORMAT_VERSION`, its own counter,
never conflated with `GAME_PACKAGE_FORMAT_VERSION`) for authoring state
(the revision DAG, ancestry, workspace identity/provenance) that Package
Format 1 correctly never carries. `buildGamePackage`/`bakeStandaloneHTML`/
`exportProjectPackage` are unmodified — zero code path connects them to
`RevisionHistoryStore` or the new workspace functions. Opening a `.vwork`
reconstructs the current Mod composition through the ordinary
`ImportManager.importSource()` pipeline (never a special loader) and only
restores history metadata (`RevisionHistoryStore.importModHistory`, added
alongside the existing store) after every current Mod has activated
successfully — a near-atomic fail-whole-workspace policy that unloads
anything this load itself activated before surfacing
`WORKSPACE_MOD_ACTIVATION_FAILED`. Full design: `WORKSPACE_SPEC.md`.

## Runtime 0.2.0-dev — Community Foundation & Publish Model

A new module (`runtime.community`: `buildRelease`/`exportRelease`/
`openRelease`/`startRemixFromRelease`/`buildCommunityCard`) defines
Community Release Format 1 (`COMMUNITY_RELEASE_FORMAT_VERSION`, its own
independent counter), local-only. `buildRelease()` calls the unmodified
`buildGamePackage()` for eligibility/dependency/topo-sort and reads
NOTHING from `RevisionHistoryStore` — a Release is provably history-free
by construction, not by filtering. `releaseToGamePackage()` adapts a
Release back into a Game-Package-shaped object so the unmodified
`bakeStandaloneHTML()`/`topoSortGamePackageMods()`/
`ImportManager.importSource()` are reused verbatim for both baking and
opening a Release — no second packaging engine. `.vwork`'s `provenance`
gained one optional field (`parentReleaseId`) to support Release-derived
Workspaces without a format bump. Full design: `COMMUNITY_RELEASE_SPEC.md`.

## Runtime 0.2 — Community Backend Foundation

`runtime.community` gains three anonymous-only remote methods —
`getRelease(remoteId)`, `getChildren(remoteId)`, `getProfile(userId)` —
implemented as plain `fetch()` calls against a Supabase project's REST
API using only a client-safe publishable key
(`COMMUNITY_BACKEND_CONFIG`). **There is no login/session/token method on
this object, and none should ever be added** — this Runtime module is,
and must remain, an anonymous Community *consumer* only. `getRelease`
reconstructs the exact original `.vrelease` object from the fetched row's
verbatim `snapshot_text` (never re-derived from normalized columns), so
it slots into the *same* `communityPendingImport` preview/
`openRelease()`/Start Remix pipeline a locally-dropped `.vrelease` file
already used — no second Mod-loading path was introduced. None of these
methods run at load time; every one is reachable only from the new
"Open Community Release (remote)" Workshop button, so a missing or
unreachable backend can never block booting or playing purely local
content.

This is deliberately the Runtime's *only* change this milestone besides
the matching `communityParentReleaseId` provenance field (see
`COMMUNITY_RELEASE_SPEC.md`'s addendum). All Auth/publish/profile/manage
surfaces live in a new, separate file, `community.html` — never inside
`index.html` — because Mods execute as trusted, same-realm code inside
`index.html` (see "The internal/public identity boundary" above): any
Auth token present there would be reachable from Mod code.

Being a separate *file* using a separate `localStorage` key is hygiene,
not the security boundary — it does not, by itself, stop a Mod from
reaching a Community session token. **The actual requirement is that
`community.html` be deployed on a different *origin* than `index.html`**
(e.g. `community.example.com` vs. `play.example.com`) whenever the
Runtime also serves untrusted/third-party Mods: same-realm JavaScript
running inside `index.html` can read any `localStorage` key and call any
authenticated browser API available to whatever origin `index.html`
happens to be served from, regardless of which file or key name a token
is stored under. This Runtime never gives a Mod a *reason* to go looking
(no token is ever placed in `index.html`'s storage in the first place),
but that is a property of this Runtime's own code, not a substitute for
origin separation in deployment — the two are complementary, and neither
is claimed to be sufficient on its own. Full design, RLS matrix, and the
security rationale: `COMMUNITY_BACKEND_SPEC.md` § 1.

**This was proven, not just asserted, during the Community Discovery
milestone**: opening `index.html` and `community.html` via `file://`
from the same directory (the setup used for this project's own live
testing) resulted in both files reporting `location.origin === "file://"`
— the same origin — and `community.html`'s live session token was
directly readable from `index.html`'s `localStorage`. `index.html`'s own
code still never touched it (confirmed by inspection), but this is
concrete proof that a `file://`-based local setup does not by itself
demonstrate the isolation this design depends on. See
`COMMUNITY_DISCOVERY_SPEC.md` § 2/10 for the full test and
`COMMUNITY_BACKEND_SETUP.md` § 6 for corrected local-dev guidance.

## Runtime 0.2 — Community Discovery & Release Pages

`index.html` gained exactly one new boot-time hook: if the page loads
with `?communityRelease=<uuid>` in the URL, the `WorkshopController` IIFE
opens the Workshop to the Export tab and calls the *existing*
`runtime.community.getRelease()` anonymous client, populating the
*existing* `communityPendingImport` preview -- no new preview UI, no new
Mod-loading path, and critically, no automatic Mod activation. This is
the receiving end of the Community Portal's "Open in Runtime"/"Remix"
handoff (`COMMUNITY_DISCOVERY_SPEC.md` § 10) -- the URL carries only the
public remote Release id, never a token, and this Runtime still never
holds a Community Auth session. Everything else this milestone built
(Explore, search, filters, Release/profile pages, pagination) lives
entirely in `community.html`; `index.html`'s only other footprint is
this one query-parameter check.
