# Migration Notes

Log of each significant refactor step: before/after/compatibility/reason/
risk. Newest entries at the top. This is the "why did we do it this way"
record for future agents working on this codebase.

---

## 010 — Phase 10: Vibe Workshop UI + Runtime 0.1 RC audit

**Before**: every Phase 8/9 capability (`.vmod` import, VMP prompt
generation) was only reachable via `evaluate_script`/console during
verification — no in-game UI. `.vmod` import always validated and
activated in one call (`importSource`), no permission-preview step.

**After**:
- **`WorkshopController`** (`index.html`, new `/* === Vibe Workshop === */`
  section after Input wiring): a self-contained UI closure with 3 tabs
  (Create/Mods/Errors), consuming `runtime.vmp.generatePrompt`,
  `runtime.mods.beginImport/confirmImport`, `ModHost.unload/getErrors/
  listDetailed`, and `ImportManager.liveStatus/listImports` — zero
  duplicated prompt/validation/permission logic. Entry point: a "Vibe
  Workshop" button in the existing `#overlay` start panel. Opening it
  calls `document.exitPointerLock()` (if locked), reusing the existing
  `pointerlockchange` handler and therefore the existing Phase 7
  timer-pause semantics — no second pause model introduced.
- **`ImportManager.beginImport`/`confirmImport`** (Phase 10 addition):
  splits Phase 8's `importSource` into capture+validate
  (`beginImport`, returns a `'validated'` or `'failed'` record without
  running `setup()`) and activate (`confirmImport`, runs `setup()`/
  `start()`). Required **zero `ModHost` changes** — `validate()`/
  `activate()` were already separate since Phase 8. `importSource`/
  `importFile` become thin `beginImport`+auto-`confirmImport` wrappers,
  unchanged behavior, verified against the same 10 Phase 8 import tests
  post-refactor.
- **Permission preview (Option A, implemented, not deferred)**: the
  Create tab always uses the two-step path — a validated-but-unactivated
  record renders a permission list (from `CAPABILITY_META`) with Cancel
  (discards, verified nothing was ever activated) / Load Mod
  (`confirmImport`). This is the smallest possible read of the brief's
  "Option A preferred if it can be introduced cleanly" — it could,
  because Phase 8 already had the seam.
- **Error UX**: `humanizeError()` + `extractPermissionRootCause()` — a
  `PERMISSION_DENIED` re-wrapped as `SETUP_EXCEPTION` (or
  `TIMER_EXCEPTION`/etc.) has its root cause extracted from the message
  text and resolved against `PUBLIC_API_META`, producing "X tried to use
  api.ui.showBanner, which needs permission "ui", not declared in its
  manifest" instead of a bare wrapped code. Verified live (see
  `TEST_MATRIX.md`).
- **`generateFixPrompt(record, options)`** added to `runtime.vmp`
  (optional per the brief, implemented since Phase 8/9's retained-source
  + metadata infrastructure made it small): a `[VMP REPAIR TASK]` prompt
  reusing the exact same `formatCapabilitiesSection`/`formatApiSpecSection`/
  `formatEventsSection` helpers `generatePrompt` uses.
- **No enable/disable toggle** — deliberately not built. "Unload for this
  session" plus an honest confirmation dialog (states exactly what
  `unload()` does and does not do) is the only mutating Mods-tab action.
  See `WORKSHOP_UX.md` for the full reasoning.
- **`VmpErrorLog` entries gained a `time` field** (small, additive) so
  the Errors tab can show when each error happened.
- **RC audit** (Part B of the Phase 10 brief): re-ran the Phase 8.5
  metadata-drift audit (clean), re-verified ownership cleanup through the
  new two-step import path specifically (event/HUD cleanup confirmed
  after `ModHost.unload()` on a mod activated via `beginImport`+
  `confirmImport`), re-verified the `DUPLICATE_DEFINITION_ON_REIMPORT`
  path through `confirmImport` specifically (not just the old
  `importSource` path), grepped the whole file for
  "sandbox"/"secure"/"isolated" claims (none found outside correct
  "NOT a sandbox" framing), confirmed default boot (no `?mods=1`/`?dev=1`)
  shows the Workshop button with zero dev-mod/debug-UI/console noise.

**Compatibility**: default boot unaffected (Workshop button + hidden
overlay are the only additions, both inert until clicked). All 5
acceptance mods (A-E) and all 10 Phase 8 import tests re-verified passing
after the `ImportManager` refactor.

**Reason**: this is the piece that makes the whole architecture usable by
someone who never reads `RUNTIME_API.md`/`VMP_SPEC.md` directly — every
prior phase built a capability, this phase is what turns "the Runtime can
technically do this" into "a player can actually do this."

**Risk**: medium (new UI surface, `ImportManager` refactor touches the
Phase 8 import path). Mitigated by: `beginImport`/`confirmImport` being
additive primitives with `importSource` reduced to calling them (not a
parallel implementation), full re-run of the Phase 8 test matrix, and
extensive live browser click-through testing (file upload via real
`.vmod` files on disk, not simulated) covering the happy path, the
broken-permission error path (before AND after a targeted
`humanizeError` fix), the permission-preview Cancel/Load paths, the
unload-confirmation-dialog path, the Mods-tab built-in-vs-imported
distinction, and the Revise-with-Agent notice.

---

## 009 — Phase 9: VMP/1 Agent Prompt generation

**Before**: no way to turn a natural-language request into a Runtime-
accurate prompt; a hand-written prompt would have needed hand-syncing
against `RUNTIME_API.md` forever.

**After**: `runtime.vmp.generatePrompt(userRequest)` builds the full
7-section VMP/1 prompt (`[VMP SYSTEM CONTRACT]`, `[VMP RUNTIME
CAPABILITIES]`, `[VMP API SPEC]`, `[VMP EVENTS]`, `[INSTALLED MODS]`,
`[USER REQUEST]`, `[OUTPUT CONTRACT]`) entirely from `PUBLIC_API_META`/
`PUBLIC_EVENT_META`/`CAPABILITY_META`/`ModHost.listDetailed()` — no
hand-duplicated prose. `[VMP EVENTS]` is a new section (added to the
protocol, `VMP_SPEC.md` updated to match) — events otherwise made the
API table harder to parse. `formatApiSpecSection`/`formatEventsSection`
filter to `status !== 'Planned'` for the main callable list, with a
compact `UNAVAILABLE / PLANNED` name-only list appended (Part 18 — a
smaller accurate prompt beats a bigger aspirational one). Runtime-level,
not mod-facing (`runtime.vmp`, not `api.vmp`) — mods have no legitimate
reason to generate prompts about themselves.

**Namespace rule (Part 30)**: `deriveResourceNamespace(manifestId)`
lowercases `manifest.id` and collapses every non-alphanumeric run to a
single `_`, so `"alice.magic-tools"` → `"alice_magic_tools"` →
`"alice_magic_tools:thing"`. The System Contract section computes its
worked example through this exact function (not a separately-typed
example string), so the stated rule and the applied rule cannot drift
from each other.

**Reason**: this is what makes `RUNTIME_API.md`/generated-prompt drift
structurally impossible rather than just disciplined — both now read
from the Phase 8.5 metadata, and `runtime.vmp` reads from that same
metadata a third time.

**Risk**: low, purely additive, no gameplay call site touched. Verified:
generated prompt contains all APIs needed by all 5 acceptance tests
(zero missing terms per test); contains zero internal-id leakage; throws
structured `VMP_INVALID_REQUEST` for empty/null/non-string/whitespace-
only input; `[INSTALLED MODS]` correctly lists live mods without dumping
source. **Documentation-only agent simulation** (Part 33): authored
`demo.healthwatch` (banner every 10s showing health, one-shot screen
flash at ≤5 health) using only the generated prompt's documented
API — first attempt omitted the `ui` permission, which the Runtime
correctly rejected with a clear `PERMISSION_DENIED` inside a
`TIMER_EXCEPTION` (scheduler kept running, no crash); fixed and
re-imported, then verified live: banner text `"Health: 19"` rendered,
screen flash triggered exactly at ≤5 health. This exercised the entire
chain end-to-end: metadata → prompt → mod source → importer → capture →
validation → activation → gameplay → **error → self-correction →
re-import → success**.

---

## 008 — Phase 8 / 8.5: .vmod import (capture/validate/activate) + machine-owned API metadata

**Before**: `defineVoxelMod` was the only entry point, and it went
straight to `ModHost.register()` — no way to inspect/validate a mod's
definition before its `setup()`/`start()` could run. `RUNTIME_API.md`,
`ModHost`'s `PERMISSION_MAP`, and any future generated prompt were three
independently hand-maintained surfaces with no drift check between them.
`api.storage.get/set/remove` were documented as gated behind the
`storage` permission but were **not actually gated at all** — a real bug
sitting undetected since Phase 7.

**After (Phase 8 — import transaction)**:
- `captureDefinition(source)`: executes trusted `.vmod` source via
  `new Function('defineVoxelMod', source)` called with a **local
  collector**, not the real global `defineVoxelMod`. Because the
  collector is a same-named parameter, every `defineVoxelMod({...})`
  call inside the source resolves to it instead of `ModHost.register` —
  the mod's `setup()`/`start()` cannot run during capture. Returns
  `VMOD_SYNTAX_ERROR` (source doesn't parse), `VMOD_EXECUTION_ERROR`
  (source throws before calling `defineVoxelMod`), `VMOD_NO_DEFINITION`
  (0 calls), or `VMOD_MULTIPLE_DEFINITIONS` (>1 calls) — or exactly one
  captured definition.
- `ModHost` split into `validate(modDef)` (manifest shape, duplicate id,
  `apiVersion`, `dependencies`, `conflicts` — everything that must be
  true before `setup()` may run) and `activate(modDef, manifest)`
  (builds the scoped api, runs `setup()`/`start()`, stores the mod).
  `register(modDef)` (the production `defineVoxelMod` path) is now
  simply `validate` then `activate` — one source of truth, no separate
  `ImportValidator`.
- **Rollback on setup failure** (Part 11): `activate()` now calls a
  shared `cleanupOwned(owned)` (extracted from `unload()`, which also
  uses it now) if `setup()` throws, before reporting the error — any
  event subscription/timer/entity/HUD element the failed `setup()`
  managed to create before throwing does not survive. Verified: a mod
  that subscribes to `game.tick`, creates a HUD element, then throws —
  after activation fails, the event no longer fires and the HUD element
  is gone.
- **Re-import of a definition-owning mod** (Part 12): re-importing a mod
  whose earlier instance registered `blocks.register`/`items.register`/
  `entities.registerType` entries hits the registry's own `DUPLICATE_ID`/
  `PROTECTED_NAMESPACE` inside `setup()`. `activate()` recognizes these
  specific error codes and reports `DUPLICATE_DEFINITION_ON_REIMPORT`
  with a human-readable explanation ("reload the page to start a fresh
  Runtime session") instead of a bare registry code.
- `ImportRecord` (`{recordId, id, filename, source, manifest, status,
  importedAt, errors}`, status `captured→validated→active` or `failed`)
  and `ImportManager` (`runtime.mods.importSource/importFile/
  listImports/getImport`) — Runtime-level surface, deliberately **not**
  `api.mods` (third-party mods have no business managing other mods).
  Source text is retained in memory for the page session, not persisted.
- Minimal dev-facing `<input type="file" accept=".vmod,.js" multiple>`
  control (top-right, always present — this is real infrastructure, not
  a hidden test artifact) wired to `importFile` with toast feedback.
  `.js` accepted for developer convenience only, documented as such; the
  primary format is `.vmod`.
- **No enable/disable toggle** (Part 13): deliberately not built.
  Definition-owning mods cannot be cleanly re-enabled after unload in
  v0.1 (see the Phase 6.5 Option B decision) — a toggle would be
  dishonest about what the Runtime actually guarantees. `unload()`
  remains a one-way "for this session" operation.

**After (Phase 8.5 — machine-owned metadata)**:
- `PUBLIC_API_META` (one entry per method: namespace, method, signature,
  status, permission, description) and `PUBLIC_EVENT_META` (name,
  status, payload, cancelable, emitter, description) — plain array
  literals, no schema framework, no reflection system. Cover every
  method/event this project has ever implemented, `Planned` entries
  included (so "not implemented" is itself machine-readable, not an
  absence).
- `auditApiMetadata()` (opt-in via `?dev=1`, never runs by default):
  cross-checks `PERMISSION_MAP` (via a new `ModHost.getPermissionMap()`)
  against `PUBLIC_API_META` in both directions. **Found the real
  `api.storage` gating bug on first run** — fixed by adding
  `'storage.get'`/`'storage.set'`/`'storage.remove'` to `PERMISSION_MAP`
  and wrapping `buildScopedApi`'s `storage` object in `gate()` (it had
  been built as a bare pre-bound object, bypassing the gating mechanism
  entirely). Re-ran the audit after the fix: clean, zero drift, and
  confirmed no existing dev-gated mod used `api.storage` (so the fix
  changed no observed behavior for A-E).

**Compatibility**: default boot unaffected (file picker is new but
inert — an empty `<input>` with no listener side effects until a file is
chosen). All 5 pre-existing acceptance mods re-verified working after
both the import-pipeline changes and the storage-gating fix.

**Reason**: Phase 8 makes `.vmod` a real product surface instead of a
theoretical one — a mod dropped in by a player/agent now goes through
the exact same validate/activate path the trusted dev-gated mods always
have, with a genuine pre-activation checkpoint. Phase 8.5 is what keeps
Phase 9's prompt generator (and `RUNTIME_API.md`) from silently drifting
from what `ModHost` actually enforces — and immediately proved its worth
by catching a real bug instead of a hypothetical one.

**Risk**: medium (touches `ModHost`'s core register/unload path, though
behavior-preserving — `register()` is byte-equivalent to before via
`validate()`+`activate()`). Verified via 10 browser-driven import tests
(§TEST_MATRIX.md): valid Super-Jump-equivalent import with real gameplay
effect, valid Crystal-Block-equivalent import with string-id-only
placement, syntax error, zero-definition, multi-definition, wrong
apiVersion (setup confirmed never running), setup-throws-after-creating-
resources (rollback confirmed), duplicate-while-active vs.
duplicate-after-unload-with-persistent-definition (both produce distinct,
correct errors), pre-existing dev-gated mods unaffected by an unrelated
import, default boot unchanged.

---

## 007B — Phase 7: api.time / api.ui / api.effects / api.storage / api.input

**Before**: only `events`/`world`/`player`/`blocks`/`items`/`entities` existed
on the scoped api. Passive health regen used a `loop._regenAccum` hack
(a stray property bolted onto the `loop` function). No mod could show UI,
schedule work, flash the screen, persist data, or read input without
reaching into internals.

**After**:
- **`runtime.time`** (`timeScheduler`): a single Runtime-owned scheduler
  (`after/every/cancel/tick/cancelAllFor`), ticked once per frame from
  `loop()` — but only inside the `if(locked && !isDead)` branch, the
  exact same gating the old regen hack lived under. **Clock semantics
  decision (Part B1)**: `api.time` timers pause whenever the pointer
  isn't locked (menu open) or the player is dead, and resume exactly
  where they left off. Chosen because (a) it reproduces the pre-Phase-7
  regen timing byte-for-byte with zero special-casing, and (b) it means
  a mod's minigame countdown (`dev.targetgame`) cannot silently drain
  while a player has the menu open — the task's own stated goal. `after`
  handles fire once and self-delete; `every` handles reschedule by
  re-adding their interval, so a callback that runs long doesn't drift.
  Exceptions inside a timer callback are caught per-callback and reported
  via `VmpErrorLog`, tagged with the owning mod id — one bad timer cannot
  stop the scheduler or any other timer.
- **Passive regen migrated** (Part B2): the boot section now calls
  `timeScheduler.every(4000, fn, 'core')` once, with `fn` doing exactly
  what the old inline block did (`health>0 && health<MAX && now-lastDamageTime>6000`
  → heal 1). `loop._regenAccum` is gone. Verified behaviorally identical
  via a real ~10.5s wall-clock wait (not simulated ticks alone — the 6s
  gate reads `performance.now()` directly, a faithful port of the
  original code, so only real elapsed time satisfies it): health went
  15→16 after damage + wait, matching pre-Phase-7 timing.
- **`runtime.ui`**: `setHudText/removeHudText/showToast/showBanner/
  addPanel/removePanel`, all text-only (`el.textContent`, never
  `innerHTML`) — no HTML injection surface, matching Part B3's explicit
  instruction to avoid raw-HTML-as-primary-interface. Elements live in a
  programmatically-created `#modUiRoot` container styled to match the
  existing `.ore-panel` look. Duplicate ids **update in place** (documented
  rule, not an error) — the natural behavior for a HUD line a mod
  redraws every tick.
- **`runtime.effects.flashScreen(colorHex, ms)`**: its own DOM element/
  timer (`modFlashEl`/`modFlashTimer`), deliberately separate from the
  built-in `hitFlashEl`/`hitFlashTimer` so a mod's flash and the base
  game's own damage flash never fight over shared state. `shake`/
  `particleBurst`/`explosion` remain Planned — not present in code at
  all, not even as no-op stubs.
- **`runtime.storage`**: `get/set/remove`, namespaced `vmp1:<modId>:<key>`
  over `localStorage`, JSON-serialized. Read/write failures (quota,
  disabled storage, non-serializable value) are caught and reported via
  `VmpErrorLog`, never thrown into a mod's control flow. **`ModHost.unload`
  deliberately does NOT touch storage** — ownership means namespace
  isolation, not data destruction (Part B5's explicit requirement).
  Documented `file://` caveat: some browsers scope/share `localStorage`
  oddly across local documents rather than per-origin; the modId prefix
  prevents inter-mod collisions regardless, but true cross-page isolation
  under `file://` is outside the Runtime's control.
- **`runtime.input`**: `isKeyDown(code)` reads the existing `keys{}` map
  directly; `on('keydown'|'keyup', fn)` is a small Runtime-generated
  `{code}` payload — never the raw `KeyboardEvent`. Wired into the
  existing `keydown`/`keyup` document listeners as one additional line
  each (`emitInputEvent(...)`).
- **`api.audio`**: still absent from real functionality — `play`/`stop`
  exist on the scoped api only as `notImplementedStub()`s that throw
  `NOT_IMPLEMENTED` with `{status:'Planned'}` when called. A Coding Agent
  gets an explicit, structured signal instead of a generic `TypeError` or
  silent no-op (Part B7's exact requirement).
- **`api.game`**: only `getVersion()` and `getState()` implemented — both
  trivial, accurate, real. `pause()`/`resume()`/`registerMinigame()` were
  deliberately NOT built (Part B8): Test E proves the Runtime is
  genre-neutral precisely by NOT having a minigame-shaped API to lean on.
- **Ownership extended** (Part A4/F): `ModHost`'s per-mod record now
  tracks `owned.subs` (events + input, same shape), `owned.timers`,
  `owned.entities`, `owned.hud`, `owned.panels`. `unload()` iterates and
  cleans every one. Storage is the sole deliberate exception.
- **Part G — error isolation fix**: found and fixed a real gap while
  auditing. `EventBus.emit`/`emitCancelable` had NO per-listener
  try/catch — a throwing listener stopped every subsequent listener on
  that event *and* propagated out to the `emit()` call site, which is
  called from real gameplay code (`updateMining`, `tryPlace`,
  `applyDamage`, `updatePhysics`, `loop()`). A single buggy mod handler
  could have broken the game loop for every player. Fixed via a shared
  `safeInvoke()` inside `EventBus` that catches per-listener, reports via
  `VmpErrorLog` (attributed to the right mod via a `fn.__vmpModId` tag set
  in `buildScopedApi`'s `trackedSub`), and continues to the next listener.
  For cancelable events, a throwing listener is treated as non-cancelling
  and iteration continues to the next listener. Verified: two deliberately
  throwing handlers (one plain event, one cancelable) both isolated
  correctly, both logged structurally, neither broke the other listener
  or propagated outward.

**Compatibility**: default boot (no `?mods=1`) unaffected — HUD, regen
timing, damage flash all verified identical. `dev.superjump`/
`dev.crystalblock`/`dev.chaser` (Phases 4/6) still pass unchanged.

**Risk**: medium (regen migration touches a real gameplay timing path;
EventBus fix touches every event call site in the file). Full ownership
destruction test (Part F) run against a temporary `dev.ownershiptest` mod
exercising all 5 owned-resource types simultaneously — every category
verified cleaned on unload, storage verified NOT deleted, another mod's
resources verified untouched, double-unload verified non-throwing. See
`TEST_MATRIX.md` for the full result table.

---

## 007A — Phase 6.5: contract reconciliation (numeric ids, ownership, stale docs)

**Before**: `VMP_SPEC.md` promised mods never see numeric ids, but the
actual scoped api exposed `world.getBlock/setBlock` and
`player.getInventory/giveItem/takeItem` using raw internal numeric
`BLOCK.*` ids, and `dev.crystalblock` (Phase 6's own acceptance test)
proved the *wrong* thing — that a mod *could* use a numeric id. Entities
had no ownership tracking. Docs described Phase 6 in future tense after
Phase 6 had shipped, and described ItemRegistry as a separate future
subsystem when Phase 6 had already decided items alias blocks.

**After (Part A1 — the headline fix)**: introduced the mod-facing
boundary explicitly: `toPublicBlockId(numericId)`/`toInternalBlockId
(stringId)` (thin wraps over `BlockRegistry.toString/toNumeric`, thrown
`UNKNOWN_BLOCK_ID` on a bad string). `ModHost.buildScopedApi` now
constructs `world`/`player` objects that call through the permission-gated
underlying method but translate at the boundary:
`world.getBlock`/`setBlock` and `player.getInventory`/`giveItem`/
`takeItem` all speak string ids to mods; `runtime.world`/`runtime.player`
themselves, and every hot-path internal (mesh building, physics,
`BLOCK_TILES`/`BLOCK_HARDNESS`, `inventory`), stay numeric, completely
untouched — exactly the "adapter at the boundary, not a hot-path rewrite"
instruction. `block.break(.before)`/`block.place(.before)` event payloads
now carry `block:` as a string id too (translated at the two emit sites
in `updateMining`/`tryPlace`).

**Part A2 — `dev.crystalblock` rewritten**: now proves the opposite of
what it proved before. It calls `api.world.setBlock(x,y,z,
'example:crystal')` — the string id only, nowhere in the mod's own source
does a numeric id appear. Verified via the debug hook that
`runtime.world.getBlock` (internal) returns a number for that cell while
`ModHost`'s scoped `world.getBlock` (mod-facing) returns `'core:stone'`/
`'example:crystal'` for the identical cell — the boundary is real, not
cosmetic.

**Part A3 — audit result**: `entity.spawn`/`get`/`query`/`remove`/
`setState` already used string type ids and Runtime-generated instance
ids (`'e1'`, `'e2'`, ...) — no numeric leakage found there, left
unchanged per the instruction to not touch unrelated numeric concepts
(health, coordinates, instance ids, timer handles, counts, versions).
`HOTBAR` stays numeric-internal; no api ever exposed it.

**Part A4 — ownership reconciled**: entities spawned via the scoped
`entities.spawn` are now added to `owned.entities`; `ModHost.unload`
removes them via the internal `removeEntity`. Combined with Phase 7's
timers/UI, `ModHost`'s per-mod `owned` record now covers every resource
type the docs promised.

**Part A5 — definition reload semantics decision**: chose **Option B**
(the smaller of the two offered). Block/item/entity-type registrations
made via `blocks.register`/`items.register`/`entities.registerType` are
**not** undone by `ModHost.unload` and there is no unregister/hot-reload
path in v0.1. A mod that registers `example:crystal`, gets unloaded, and
is loaded again will hit `DUPLICATE_ID` on the second `blocks.register`
call. This is documented behavior, not an oversight — recorded in
`RUNTIME_ARCHITECTURE.md`, `VMP_SPEC.md`, and this entry. Rationale:
building real hot-reload (tracking which mod owns which registry entry,
safely unregistering while entities/world cells of that type might still
exist) is a materially bigger design than a "reconciliation pass"
warrants; Option B is honest about the limitation rather than silently
leaving it undefined.

**Part A6/A7 — stale docs swept**: `RUNTIME_ARCHITECTURE.md`'s "will back
ItemRegistry" language corrected to reflect the actual Phase 6 decision
(items alias blocks, no separate registry). Future-tense "Phase 6 will..."
language converted to past-tense "done" status throughout. `RUNTIME_API.md`
now marks every documented core event (`runtime.ready`, `player.spawn`,
`player.move`, `item.use`, `entity.damage`, `entity.interact`,
`world.generate`) as explicitly Planned-not-emitted where that's true,
rather than implying the full historical list from the original brief is
live. Implemented-and-emitted as of Phase 7: `game.tick`, `player.jump`,
`player.damage`, `player.death`, `player.respawn`, `player.step` (new,
Part A8), `block.break(.before)`, `block.place(.before)`, `entity.spawn`,
`entity.death`.

**Part A8 — `player.step` implemented**: emitted from the end of
`updatePhysics`, only while `grounded`, only on a ground-*cell* change
(tracked via `lastStepCell`), using a reused `stepPayload` object (no
per-frame allocation, matching `tickPayload`'s existing pattern). Ground
cell = `{floor(pos.x), floor(pos.y)-1, floor(pos.z)}` — the block
directly under the player's feet, which sits on an exact integer
boundary whenever `grounded` is true (see the Y-axis snap logic already
in `updatePhysics`). Payload: `{x,y,z,block}` with `block` as a string id
via `toPublicBlockId`. This is what makes acceptance Tests B and E
possible without every mod polling `game.tick` and hand-rolling cell-
change detection.

**Reason**: `.vmod` (Phase 8) turns these APIs from "code only I read" into
"code third-party Coding Agents write against a spec." Every contract gap
found here would have become a permanent compatibility problem once
external mods started depending on the wrong (numeric) shape.

**Risk**: the numeric→string translation touches the exact call sites
mining/placement/inventory depend on internally — mitigated by leaving
every internal call site numeric and only wrapping at the `ModHost`
boundary, verified via the debug-hook comparison above plus a full
default-boot regression (unaffected, since default boot never touches
`ModHost`'s scoped api at all).

---

## 006 — Phase 6: custom blocks, items (alias of blocks), entities

**Before**: `BlockRegistry` only held the 7 core blocks; the atlas was a
tight 4x2 grid with all 8 tiles used by core blocks; no item or entity
concept existed at all.

**After**:
- Grew the atlas to 8x8 (64 tiles): core blocks still use 0-7, tiles 8-63
  are free for mods. `registerCustomBlock(def)` allocates a spare tile per
  distinct color in `def.textures.{top,bottom,side}`/`color` (reusing one
  tile if all three match — most mods will), paints it with the same
  solid+`speckle()` procedural style `buildAtlas()` already uses for core
  tiles (`paintAtlasTile`), then re-uploads the whole atlas texture to the
  GPU. This happens once per registration (mod setup time), never per
  frame. Registers into `BlockRegistry` and extends the existing
  numeric-indexed `BLOCK_TILES`/`BLOCK_HARDNESS`/`inventory` objects with
  the new numeric id — so mining/placement/hotbar-count code (which have
  been reading those exact tables since Phase 0) work on custom blocks
  with zero changes to their own logic.
- `api.items.register/get` is an explicit **alias of blocks** for v0.1 —
  no separate `ItemRegistry` was added, since the base game's inventory
  model already treats "block you mined" and "carryable item" as the same
  thing, and adding a parallel registry with no distinct behavior yet
  would be unused scaffolding.
- New `EntityTypeRegistry` (reusing `createIdRegistry`, no new
  namespace-validation code) + a plain `Map`-based entity instance store
  (`entityInstances`). `registerType({id, model, defaults, tick})` builds
  a solid-color box mesh via the existing `buildBox()` helper (already
  used for the first-person arm) and stores it once per *type*, not per
  instance. `spawn/get/query/remove/setState` manage instances;
  `get`/`query` return shallow copies so mods can't mutate live state
  outside `setState()`/their own `tick` closure. `tickEntities(dt)` runs
  every frame from `loop()` (unconditional, like `game.tick`);
  `drawEntities(proj,view)` runs every frame after `drawMain`, reusing
  `drawArmPiece`/`flatProg` — no new shader, no renderer rewrite.
- Extended `ModHost`'s `PERMISSION_MAP` with `entities.spawn/get/query/
  remove` → `entity.spawn/read/read/modify`; `entities.registerType` and
  all of `blocks.*`/`items.*` stay ungated (registration isn't in
  VMP_SPEC.md's declared capability list).
- Shipped two more dev-gated (`?mods=1`) acceptance test mods:
  `dev.crystalblock` (Test C — registers `example:crystal`) and
  `dev.chaser` (Test D — registers+spawns `example:chaser`, a red cube
  that chases the player each tick via `ctx.player.getPosition()` and
  deals 1 contact damage per second via a `state.hitCooldown` pattern).

**Known limitation, not solved here**: `solid:false` on a custom block
definition is accepted and stored, but `isSolid()`/`collidesAABB()` (the
original Phase 0 functions, unchanged) only ever check "is this world
cell non-AIR" — they never consult `BlockRegistry`. A mod-registered
non-solid decorative block will still physically block the player today.
Documented, not fixed in v0.1 — fixing it means threading a registry
lookup into the collision hot path, a bigger change than this phase
warrants.

**Compatibility**: default boot (no `?mods=1`) unaffected — verified via
screenshot that terrain textures render identically after the atlas grid
resize (4x2 → 8x8; core tile UVs are computed from `ATLAS_COLS`/`ROWS`
consistently everywhere they're used, so growing the grid while keeping
core tiles at indices 0-7 doesn't shift anything).

**Reason**: this is the first phase that lets a mod add content the base
game doesn't already have (new block types, new creature types) rather
than just modifying existing gameplay numbers — the acceptance tests this
phase unlocks (C, D) are explicitly about proving the Runtime isn't
limited to remixing what's already there.

**Risk**: medium-high (first phase touching rendering since Phase 3).
Verified via a temporary `window.__voxelDebug` hook (removed before
finalizing): `example:crystal` registered with numeric id 7 (correctly
sequential after core's 0-6) and tile 8 (first free slot); placed via
`world.setBlock` using that numeric id and read back correctly;
`example:chaser` spawned, and — because `tickEntities`/`drawEntities` run
from the real `loop()`, not just my manual test calls — genuinely chased
the live player position across real animation frames and dealt real
contact damage (health visibly dropped, death/respawn cycle fired
correctly mid-test, cooldown fix then confirmed graceful gradual damage
instead of a one-frame kill). No console errors at any point. Clean
reload afterward on the default URL — terrain screenshot confirmed
visually intact.

---

## 005 — Phase 5: permission gating, ownership tracking, unload

**Before**: `ModHost`'s scoped `api` (Phase 4) forwarded directly to
`runtime.world`/`runtime.player` unfiltered, and there was no way to
undo a mod's registrations — no `unload`, no tracking of what a mod
had subscribed to.

**After**:
- `PERMISSION_MAP` maps qualified method names (`world.setBlock`,
  `player.damage`, ...) to the required permission string
  (`world.read/write`, `player.read/modify`). `gate(modId, granted,
  namespace, methods)` builds a per-mod object where ungranted methods
  are replaced by a stub that throws a structured `PERMISSION_DENIED`
  error (also logged via `reportError`) instead of running. `api.events`
  and `api.blocks` stay ungated — subscribing to events is a core
  capability, and block registry lookups are inert data reads, neither
  is in VMP_SPEC.md's declared capability list.
- `buildScopedApi` now takes an `ownedSubs` `Set` and wraps
  `events.on`/`once` so every subscription a mod creates is tracked;
  the returned unsubscribe closure both calls the real `off()` and
  removes itself from `ownedSubs` (so double-unsubscribe, whether by the
  mod itself or by `unload`, is a no-op, not a double-free).
- `register()` gained `dependencies`/`conflicts` checks against the
  currently-loaded mod set (`DEPENDENCY_MISSING`/`CONFLICTING_MOD`
  structured errors) alongside the existing manifest/duplicate/apiVersion
  checks.
- `ModHost.unload(modId)`: calls `stop()` then `unload()` on the mod
  (each try/catch, its own phase), then iterates and calls every
  function still in `ownedSubs`, then removes the mod from the registry.
  Unloading a mod that isn't loaded produces `MOD_NOT_FOUND`, not a throw.

**Compatibility**: `dev.superjump`'s manifest needed `permissions:
['player.read','player.modify']` added (it calls `getVelocity` +
`setVelocityY`) — the only behavior-visible change, and only for that
dev-gated test mod; default boot (no `?mods=1`) is unaffected.

**Reason**: this is what makes "mods don't need to hand-roll cleanup" true
in practice (VMP_SPEC.md's Agent Contract promises it), and what makes
`manifest.permissions` a real (if declared-trust, not sandboxed) gate
instead of decorative documentation.

**Risk**: low — pure `ModHost`-internal, no gameplay call sites touched.
Verified via a temporary `window.__voxelDebug` hook (removed before
finalizing): Super Jump still worked after gating (0→8, with correct
permissions declared); a mod without `world.write` got a thrown
`PERMISSION_DENIED` calling `world.setBlock`; a mod subscribed to
`game.tick`, fired twice (count=2), was unloaded, then two more emits
left the count at 2 (listener genuinely stopped); unloading a
nonexistent mod id produced a structured error without throwing; a mod
declaring a missing dependency failed registration with
`DEPENDENCY_MISSING` and never appeared in `ModHost.list()`. Clean
reload afterward — no console errors, HUD intact.

---

## 004 — Phase 4: ModHost + defineVoxelMod + event wiring + Super Jump test mod

**Before**: no event emission anywhere; no mod concept; `updateMining`/
`tryPlace`/`applyDamage`/`die`/`updatePhysics` had no hook points.

**After**:
- Added `ModHost` (after the `runtime.player` facade): `register(modDef)`
  validates `{manifest.id, setup}`, checks for duplicate mod ids, checks
  `apiVersion === API_VERSION`, builds an unfiltered scoped `api` handle
  (`events.on/once/off`, `world`, `player`, `blocks.get/list`), calls
  `setup(api)` then optional `start(api)`, all inside try/catch producing
  a structured `{protocol:'VMP/1', mod, phase, errors:[{code,message}]}`
  object (logged via `console.error`, never thrown past the boundary — one
  bad mod cannot crash the runtime or other mods). `list()`/`getErrors()`
  exposed for inspection.
- `defineVoxelMod(modDef)` calls `ModHost.register`. **Deliberately exposed
  as `window.defineVoxelMod`** (the one intentional exception to "mods
  never touch globals") — Phase 8's `.vmod` files load as separate
  `<script src>` tags outside this IIFE's closure, so the entry point
  itself must be globally reachable even though everything passed into
  `setup(api)` stays scoped.
- Wired event emission at the exact call sites identified in
  `RUNTIME_ARCHITECTURE.md` § EventBus internals: `game.tick` once/frame
  in `loop()` via a reused `tickPayload` object (no per-frame allocation);
  `block.break.before` (cancelable) / `block.break` in `updateMining`'s
  completion branch; `block.place.before` (cancelable) / `block.place` in
  `tryPlace`; `player.jump` in `updatePhysics`'s jump branch; `player.damage`
  in `applyDamage`; `player.death` in `die()`; `player.respawn` inside
  `die()`'s respawn `setTimeout` callback.
- Shipped `dev.superjump`, a dev-gated (`?mods=1` query flag) mod that
  listens to `player.jump` and adds +8 to `velY` via `api.player.setVelocityY`
  — proves the full chain end-to-end without affecting default boot.

**Compatibility**: with no `?mods=1` flag (the default for every player who
just opens the file), behavior is unchanged — event emission is additive
(nothing previously happened at those points; now listeners *may* run, but
zero listeners are registered by default). Manual regression pass with
default URL confirmed identical HUD/console/behavior to Phase 3 baseline.

**Reason**: this is the concrete proof that the whole architecture works —
`defineVoxelMod` → `ModHost` → scoped `api` → `events.on` → real gameplay
effect (jump height), round-tripped through the exact facades built in
Phase 3.

**Risk**: medium (inline emits at hot paths: mining, placement, jump,
damage, death/respawn). Verified via a temporary `window.__voxelDebug`
hook (removed before finalizing, never shipped): Super Jump boosted `velY`
0→8 through the real `player.jump` event path; duplicate mod id, malformed
manifest, and a mod whose `setup()` throws all produced structured errors
without throwing past `ModHost.register` or affecting the already-loaded
good mod; `block.break.before` cancellation left the target block
unchanged. Clean reload afterward (default and `?mods=1` URLs both) — no
console errors, HUD intact.

**TODO(MIGRATION) note**: the scoped `api` built by `buildScopedApi()` is
currently **unfiltered** (no permission gating) and **untracked** (no
per-mod ownership of subscriptions for auto-cleanup on unload — there is
no `unload` yet at all). Both land in Phase 5, which is pure-`ModHost`-
internal and touches no gameplay call sites.

---

## 003 — Phase 3: world/player facades, collapsed mesh-rebuild funnel

**Before**: `setBlock()`+`rebuildWorldMesh()` were called independently from
3 sites (`updateMining` completion, `tryPlace`, `regenBtn` handler);
`generateWorld()`+`rebuildWorldMesh()`+`findSpawn()` were similarly
duplicated inline in the regen handler. Mining/placement/regen/player-state
code read/wrote `pos/yaw/pitch/velY/grounded/health/inventory` directly.

**After**: Added `runtime.world` (`getBlock/isSolid/getBounds/getHeight/
raycast/setBlock/regenerate`) and `runtime.player`
(`getPosition/setPosition/getVelocity/setVelocityY/getLookDirection/
setLook/isGrounded/getHealth/getMaxHealth/damage/heal/respawn/
getInventory/giveItem/takeItem`) facades, placed after `raycastBlock`
(all wrapped functions are 1:1 pass-throughs, no rewritten logic).
Rewired the 3 mining/placement/regen call sites to call
`runtime.world.setBlock`/`runtime.world.regenerate` instead of the raw
`setBlock`/`generateWorld`/`rebuildWorldMesh`/`findSpawn` combo — this
collapses the mesh-rebuild trigger into one funnel inside
`runtime.world.setBlock`.

IDs on this facade are still internal numeric `BLOCK.*` ids — string-id
translation is deferred to when ModHost exposes a scoped API to mods
(~Phase 4/6), since this facade's only job right now is internal
dogfooding, not mod-facing surface.

**Compatibility**: mining, placement, and regen behavior is unchanged —
same inventory math, same mesh-rebuild timing (still full-world remesh,
just called from one place instead of three), same regen reset sequence.

**Reason**: (1) removes the 3-way duplication that risked future drift;
(2) creates the single point Phase 4 needs to hang cancelable
`block.place.before`/`block.break.before` events off of, without
duplicating cancel logic between mining and placement.

**Risk**: medium-high (touches the riskiest lines in the file) — verified
via a temporary `window.__voxelDebug = runtime` hook (removed immediately
after, never shipped): confirmed `world.setBlock` mutates the target block
and triggers a mesh rebuild, `world.regenerate` resets world+spawn without
throwing, `player.setPosition/damage/heal/giveItem` all mutate state and
correctly refresh dependent UI (hotbar count, hearts). Full boot regression
re-run afterward with the hook removed — clean console, correct HUD.

---

## 002 — Phase 2: core blocks mirrored into BlockRegistry

**Before**: `BLOCK = {AIR:0,GRASS:1,DIRT:2,STONE:3,SAND:4,WOOD:5,LEAVES:6}`
was the only block identity in the system; `BlockRegistry` (Phase 1) had
no entries.

**After**: Added a `BlockRegistry.withCoreRegistration(...)` block
immediately before the `inventory` const, registering `core:air`,
`core:grass`, `core:dirt`, `core:stone`, `core:sand`, `core:wood`,
`core:leaves` in that exact order, sourcing `hardness`/`tiles` from the
existing `BLOCK_HARDNESS`/`BLOCK_TILES` tables (single source of truth,
not duplicated data). Each registration's returned numeric id is asserted
against `BLOCK[key]`; a mismatch throws `CORE_ID_MISMATCH` at boot,
turning "the mapping silently drifted" into a loud, immediate failure
instead of a subtle rendering/worldgen bug discovered later.

**Compatibility**: `BLOCK.*` constants untouched, still the ids every
existing function (`generateWorld`, `buildMesh`, `isSolid`, mining,
placement, inventory, hotbar) reads. `BlockRegistry` is a mirror, not a
replacement, per `RUNTIME_ARCHITECTURE.md`. No existing call site changed.

**Reason**: proves the string-id ↔ numeric-id mapping is correct and
stable before anything (Phase 3+) starts reading through it, without
risking a single line of gameplay-affecting code.

**Risk**: verified via browser reload — world regenerated deterministically
(spawn position `28.5, 17.0, 28.5`, identical to pre-Phase-2 baseline,
confirms `generateWorld`'s fixed-seed output is bit-for-bit unaffected),
no console errors, no `CORE_ID_MISMATCH` thrown (would have aborted boot
before `buildHotbarUI`/`buildHeartsUI` ran, which did run — hotbar/hearts
rendered normally).

**TODO(MIGRATION) marker introduced**: at the top of the registration
block in `index.html` — "`BLOCK.*` numeric constants are a compat shim
over `BlockRegistry` during Phases 2-5; remove once all internal call
sites read through `runtime.world`/`runtime.blocks` instead (~Phase 6)."

---

## 001 — Phase 1: EventBus + BlockRegistry scaffolding

**Before**: `index.html` had no registry, no event system, no plugin
concept. All state (`world`, `pos`, `inventory`, `health`, ...) was module
closures over `let`/`const` inside the single boot IIFE, read/written
directly by whichever function needed them.

**After**: Added, immediately before the `World data` section (formerly
`index.html:308`, now shifted down by the inserted block):
- `RUNTIME_VERSION = '0.1.0'`, `API_VERSION = 1`, `VMP_VERSION = 1`
- `EventBus`: `Map`-based pub/sub with `on/once/off/emit/emitCancelable`,
  a reused cancelable-event object to avoid per-emit allocation.
- `regError(code, id, extra)`: structured error helper.
- `createIdRegistry(kind)`: generic string-id ↔ numeric-id registry
  factory with namespace validation (`namespace:id` regex) and `core:`
  namespace protection via `withCoreRegistration(fn)`.
- `BlockRegistry = createIdRegistry('block')`.
- `runtime = { version, events, registry: { blocks } }` — the top-level
  object future phases attach to.

**Compatibility**: 100% additive. No existing function, variable, or call
site was modified. Nothing in the existing game code calls into any of the
new symbols yet.

**Reason**: establishes the extension points (EventBus to emit into,
Registry to register into) before any risky rewiring of mining/placement/
worldgen call sites happens in Phase 2-3, per "extract interfaces before
replacing implementations."

**Risk**: near-zero — verified via `new Function(scriptSource)` syntax
check (catches any accidental JS error) plus a full manual regression pass
covering all ~24 checklist items in `TEST_MATRIX.md`.

**TODO markers introduced**: none yet — Phase 2 will introduce the
`BLOCK.X` numeric-constant compat-shim TODO once core blocks are
registered into `BlockRegistry` alongside the existing `BLOCK` enum.

## RC — Runtime 0.1 RC Agent Interoperability & Stress Test fixes

Full evidence and methodology in `RC_AGENT_BENCHMARK.md`. Ten independent
black-boxed Coding Agent sub-sessions (fresh context, no project file
access — see benchmark doc for the exact simulation method), each given
only a real `runtime.vmp.generatePrompt()` output plus a natural-language
gameplay request, were used to generate `.vmod` files and run them through
the real Workshop import → error → Copy Fix Prompt → repair loop. Every
fix below is traceable to a concrete, reproduced failure — none were added
speculatively.

**1. `deriveResourceNamespace` namespace-collision fix (contract bug).**
The old rule (`lowercase, replace non-alphanumeric run with "_"`) is lossy:
`alice.magic-tools`, `alice.magic_tools`, `alice.magic tools`, and
`alice.MAGIC-TOOLS` are four different, individually valid manifest ids
that all collapsed to the identical resource namespace
`alice_magic_tools`, empirically confirmed to cause a `DUPLICATE_ID`
crash in a second, unrelated mod's `setup()` when both are loaded in the
same session. Fixed by appending a short deterministic hash of the
*original* (uncollapsed) manifest id, so near-miss ids reliably diverge
(`alice_magic_tools_tco85p` vs `alice_magic_tools_1h0xbvf` vs ...) without
a heavyweight UUID/registry scheme. The VMP prompt's `NAMESPACE RULE`
section was updated to describe the new derivation.

**2. `DUPLICATE_DEFINITION_ON_REIMPORT` message fix (misleading error).**
This error previously always assumed "you re-imported the same mod
twice," but the identical `DUPLICATE_ID` also fires on a genuine
cross-mod namespace collision (see #1) — the old message pointed a
confused second author toward reloading the page, which does not fix a
namespace collision. The message (both the raw `VmpErrorLog` entry and
the Workshop `humanizeError` summary) now explains both possible causes
instead of asserting the wrong one.

**3. VMP prompt: literal `defineVoxelMod` lifecycle skeleton added.**
2 of 10 agent-generated mods invented lifecycle hook names that do not
exist (`onEnable`/`onDisable`, `onLoad`/`onUnload`) instead of the actual
required `setup(api)` entry point, correctly triggering `MANIFEST_INVALID`
on import. The prompt only described the contract in prose; it never
showed the literal shape. A copy-pasteable skeleton was added to the
System Contract section.

**4. VMP prompt + `PUBLIC_API_META`: entity tick signature/position
clarified.** 3 of 10 mods that used `entities.registerType({tick})`
wrote `tick(entity)` or `tick(entity, dt)` (wrong arity — actual signature
is `tick(entity, ctx, dt)`) and mutated `entity.x`/`entity.y`/`entity.z`
directly instead of `entity.position.x/y/z`. `entity.x` is always
`undefined`, so any distance math involving it evaluates to `NaN`, and
`NaN > threshold` is always `false` — reproduced live: a Crystal Defense
mod's enemies were incorrectly judged to have "reached" their target on
the very first tick regardless of actual distance, destroying the
objective in seconds. This did not throw or get logged anywhere, making
it silent and hard to detect without directly inspecting entity state.
Both the VMP prompt and `PUBLIC_API_META`'s `entities.registerType`
description now state the three-arg signature and the nested-position
requirement explicitly.

**5. VMP prompt + `PUBLIC_API_META`: `blocks.register` texture keys
enumerated.** 3 of 10 mods passed `textures: { all: '#hex' }` — `all` is
not, and has never been, a recognized key (only `{color}` or
`{top,bottom,side}` are read); the block silently falls back to a
default purple placeholder with no error. Both the prompt and
`PUBLIC_API_META` now state the exact accepted keys.

**6. Workshop: `MANIFEST_INVALID`-specific `humanizeError` branch added.**
Previously fell through to the generic "could not be loaded" message,
which gave a player-facing error no more informative for this (very
common — 2 of 10 first-pass failures) case than a blank failure. Now
explains the missing `setup(api)` requirement directly.

**Explicitly NOT changed / NOT added this round** (per RC methodology —
see `RC_AGENT_BENCHMARK.md` §10 for the full reasoning): no new
`api.*` methods, no new events, no permission-mapping changes, no
renamed/removed Stable API. All observed failures were traced to Agent
mistakes or prompt/documentation ambiguity, not an actual Runtime
capability gap — consistent with the session's explicit mandate not to
grow the API surface reactively.

**Compatibility**: additive/corrective only. `deriveResourceNamespace`'s
output format changed (previously freeze-relevant, but VMP 1 had not yet
frozen at the time of this fix — see benchmark doc's release decision).
No Stable API method signature, permission requirement, or event payload
changed.

## Distribution — Runtime 0.1 Distribution milestone

Built after API 1/VMP 1 froze (RC round complete). Full design record in
`DISTRIBUTION_SPEC.md`; this entry is the migration-log summary.

**What was added**: `runtime.distribution` module (Game Package build/
validate/bake/export/import, `GAME_PACKAGE_FORMAT_VERSION = 1`,
independent of Runtime/API/VMP versions), an inert
`#voxel-game-package` container in the static HTML shell, a
`__pristineDocumentHTML` snapshot captured as the literal first statement
of the script, boot-time `loadEmbeddedGamePackage()`, and a 4th Workshop
tab (Export) with `.vgame` project import.

**Compatibility**: purely additive. No existing function, DOM element,
API method, event, or permission mapping was changed. `?mods=1`/`?dev=1`
dev paths, `.vmod` import, permission preview, and the error/fix-prompt
loop are all unchanged and re-verified clean (see `TEST_MATRIX.md` §
Distribution acceptance tests). API 1 and VMP 1 were not touched.

**Version decision**: `GAME_PACKAGE_FORMAT_VERSION` begins at `1`, its
own independent counter — a `.vgame`/baked-package's compatibility is
checked against `formatVersion`/`apiVersion`/`vmpVersion` individually,
never conflated into one number. `RUNTIME_VERSION` was left at `0.1.0`
for this session (no application-visible behavior of the *existing*
Runtime changed — Distribution is new, additive surface, not a revision
to what was already there); bumping to `0.1.1`/`0.2.0` on a future
release is a reasonable call for whoever ships this, not made
unilaterally here. `API_VERSION`/`VMP_VERSION` remain `1`, unchanged, as
required.

**Known drift risk documented, not fixed**: `__pristineDocumentHTML` is
captured from the live DOM's own markup, so if a future phase adds a new
top-level dynamic-content container to the static shell without
following the "empty until JS fills it" pattern every existing container
uses, that container's *design-time* content (not live state, since
capture happens pre-mutation) would be whatever the HTML source says —
which is exactly the intended behavior, but worth remembering: the
static shell is the actual contract Bake relies on, not a convention
enforced by tooling.

## Release Hardening — Runtime 0.1 golden baseline

Closed every loose end left open by RC + Distribution before declaring
Runtime 0.1 released. Full design/evidence in `DISTRIBUTION_SPEC.md`
(updated), `TEST_MATRIX.md` (updated), and the chat checkpoint report.

**What was added/changed**:
- `startImmediately` formally resolved as **Reserved — ignored by
  Runtime 0.1**, stated explicitly in code comments at both the write
  site (`buildGamePackage`) and the read site
  (`loadEmbeddedGamePackage`), and in `DISTRIBUTION_SPEC.md`. Not faked.
- `__pristineDocumentHTML`'s capture-site comment rewritten as a formal
  invariant statement (what must never change, and precisely why it's
  safe as written) rather than a description. Verified live post-hoc
  (see `TEST_MATRIX.md`).
- A short, human-readable identifying HTML comment (title + version
  tuple) added near the top of baked standalone HTML — and, because the
  title is untrusted, a small `commentSafe()` escape was added
  specifically for HTML-comment injection (`--` sequences), verified
  live with a hostile title.
- **Real gap found and fixed**: the raw dev `.vmod` file-picker input
  was shipping on every default boot, ungated, predating Vibe Workshop.
  Now behind `?dev=1`.
- `RELEASE_FIXTURES/` added: 3 example `.vmod`s (simple mechanic, entity/
  gameplay, — the third, a non-Minecraft minigame, already exists as the
  in-Runtime `dev.targetgame` acceptance mod and was not duplicated), 1
  demo `.vgame` (3 composed Mods), 1 golden standalone `.html`, 8 error
  fixtures (one per required golden-path scenario).

**Compatibility**: purely additive/corrective, same as the Distribution
round. No Stable API method, event, permission mapping, VMP output
contract, or `.vmod` file shape changed. The one behavior change a real
player could observe is the dev file-picker disappearing from default
boot — which is a bug fix (it was never supposed to ship there), not a
feature change.

**Version decision**: `RUNTIME_VERSION` remains `0.1.0`. This round is
hardening and gap-closing, not new capability — nothing about what a
Mod, a `.vgame`, or a baked `.html` can *do* changed, only cleanup
(gating a leftover dev control) and formalization (comments, a code
security fix, fixtures). `API_VERSION`/`VMP_VERSION`/
`GAME_PACKAGE_FORMAT_VERSION` all remain `1`, unchanged, as required.
This tuple — `Runtime 0.1.0 / API 1 / VMP 1 / Package Format 1` — is now
the golden baseline all future Runtime 0.2/community work branches from.

008 (Runtime 0.2.0-dev, Transactional Mod Revision): the first Runtime 0.2
change with real Host-side behavior, not just cleanup. `createIdRegistry`
gained ownership (`ownerModId`) and a tombstone flag (`removed`); `register()`
grew a narrow, explicitly-opened revision window (`beginRevision`/
`endRevision`) in which an id already owned by the *same* owner replaces in
place (same `numericId`) instead of throwing `DUPLICATE_ID` -- the fix for
Option B's "re-import after unload throws `DUPLICATE_DEFINITION_ON_REIMPORT`"
pain point from 007A/007B, but scoped: ordinary `Import .vmod` never opens
that window, so its 0.1.1 behavior (including that exact error) is
unchanged. `ModHost` gained `validateRevision`/`reviseMod`; `ImportManager`
gained `beginRevisionImport`/`confirmRevision`. `API_VERSION`/`VMP_VERSION`/
`GAME_PACKAGE_FORMAT_VERSION` remain `1`, unchanged -- nothing here is
`api.*`. `RUNTIME_VERSION` moves to `0.2.0-dev`. Full design and live
acceptance-test results: `MOD_REVISION_SPEC.md`.

009 (Runtime 0.2.0-dev, Revision History & Safe Undo): added
`RevisionHistoryStore` (per-Mod bounded history, DAG ancestry via
`parentId`, redo stack) plus `ImportManager.restoreRevision`/
`undoLastRevision`/`redoRevision`/`getHistory`, all routed through the
008 transaction engine unchanged. Fixed two bugs found while building this:
(1) `createIdRegistry.tombstone()` used to delete the string→numeric
mapping, so a same-owner reactivation of a removed id silently got a NEW
numeric id instead of reusing the original one -- violated "same owner may
reactivate the tombstoned public id, existing numericId is reused";
fixed by keeping the mapping and checking a `removed` flag in
`toNumeric`/`get`/`list` instead. (2) `RevisionEntry.seq` (the "Revision N"
label) was first computed as ancestry depth, which collides when two
branches share a parent (both compute `parent.seq+1`); fixed to strict
per-Mod creation order. Also performed a transaction-boundary audit (Phase
H0): confirmed and documented, with a live reproduction, that world/player/
storage mutations made by a Mod's `setup()` are NOT reverted by rollback --
only Host-owned lifecycle state and Registry definitions are. No API 1 /
VMP 1 / Package Format 1 change. `RUNTIME_VERSION` remains `0.2.0-dev`.
Full design and acceptance-test results: `REVISION_HISTORY_SPEC.md`.

010 (Runtime 0.2.0-dev, Creation Workspace & Provenance): added `.vwork`
(Workspace Format 1, its own independent version counter -- never the
same counter as Game Package Format 1, never bumped together just because
both happen to change in the same release) plus `RevisionHistoryStore.
exportModHistory`/`importModHistory` (per-Mod, ids persisted verbatim) and
a small `WorkspaceManager` surface (`runtime.workspace`:
buildWorkspace/exportWorkspace/importWorkspace/forkWorkspace/
startRemixWorkspace) for local workspace identity and lightweight
provenance (Original/Fork/Remix-of-distributed-artifact). Opening a
Workspace reuses the ordinary `ImportManager.importSource()` pipeline
unchanged and only restores history metadata after every current Mod
activates -- a fail-whole, near-atomic policy on any activation failure.
`buildGamePackage`/`bakeStandaloneHTML`/`exportProjectPackage` were NOT
modified -- reconfirmed that no code path connects them to
RevisionHistoryStore, so `.vgame`/baked `.html` remain history-free.
`API_VERSION`/`VMP_VERSION`/`GAME_PACKAGE_FORMAT_VERSION` remain `1`,
unchanged -- nothing here is `api.*`. `RUNTIME_VERSION` remains
`0.2.0-dev`. Full design and acceptance-test results: `WORKSPACE_SPEC.md`.

011 (Runtime 0.2.0-dev, Community Foundation & Publish Model): added
Community Release Format 1 (`COMMUNITY_RELEASE_FORMAT_VERSION`, its own
independent counter) plus `runtime.community` (buildRelease/exportRelease/
openRelease/startRemixFromRelease/buildCommunityCard). `buildRelease()`
calls the unmodified `buildGamePackage()` and reads nothing from
RevisionHistoryStore -- a Release is history-free by construction.
`releaseToGamePackage()` adapts a Release back into a Game-Package shape
so the unmodified `bakeStandaloneHTML`/`topoSortGamePackageMods`/
`ImportManager.importSource` are reused verbatim, never a second
packaging engine. `.vwork`'s `provenance` gained one optional field
(`parentReleaseId`) -- purely additive, `WORKSPACE_FORMAT_VERSION` stays
`1`, no Workspace Format 2 was created or needed. Found and fixed two real
bugs during testing: (1) opening a Release didn't populate the Export
tab's title/description/author fields, so an immediate Bake/Export
defaulted to "My Voxel Game" instead of the Release's actual title; (2)
the generic `.vgame`-remix button remained visible alongside the new
Release-aware Start Remix button, letting a player pick the one that
cannot carry release provenance and silently lose the chain -- fixed by
suppressing the generic button whenever a Release is the open session's
origin. `API_VERSION`/`VMP_VERSION`/`GAME_PACKAGE_FORMAT_VERSION`/
`WORKSPACE_FORMAT_VERSION` all remain unchanged -- nothing here is
`api.*`. `RUNTIME_VERSION` remains `0.2.0-dev`. Full design and
acceptance-test results: `COMMUNITY_RELEASE_SPEC.md`.

012 (Runtime 0.2, Community Backend Foundation): persisted Community
Releases remotely (Supabase Postgres + RLS + one Edge Function) behind a
hard security boundary -- `index.html` never holds a Community Auth
session; a new, separate file, `community.html`, owns all Auth/publish/
profile/manage UI and never executes Mod source. `runtime.community`
gained three anonymous-only remote methods (`getRelease`/`getChildren`/
`getProfile`), implemented as plain `fetch()` calls against a publishable
key only -- no login/session/token method exists on this object. Both
Workspace Format 1 and Community Release Format 1 gained one additive
field each (`communityParentReleaseId`, the *remote* parent id, distinct
from the existing local `parentReleaseId`) -- no format version bump on
either. Found and fixed one real bug during implementation: the first
`publish-release` Edge Function read `provenance.parentReleaseId` (a
local-only id) as the remote lineage input, which would have silently
failed to link any real parent -- caught before deployment testing by
inspecting `buildRelease()`'s actual output, fixed by introducing the
distinct `communityParentReleaseId` field end-to-end. Verified live
against the actual linked Supabase project: migration applies cleanly,
Security/Performance Advisor clean after one follow-up fix migration
(`search_path`/`auth_rls_initplan` findings), two-user RLS attack tests
and fully-anonymous write attempts all correctly blocked, server-computed
lineage with a forged `generation:999` silently ignored, a full A->B
remote round-trip (real fetch -> Start Remix -> local `.vrelease` export
-> Portal publish -> live DB row with correct `generation`/
`parent_release_id`), and a complete zh-CN pass. `API_VERSION`/
`VMP_VERSION`/`GAME_PACKAGE_FORMAT_VERSION` remain unchanged -- nothing
here is `api.*`. `RUNTIME_VERSION` remains `0.2.0-dev` -- this milestone
is not a stable 0.2 release. Full design, schema, RLS matrix, and
acceptance-test results:
`COMMUNITY_BACKEND_SPEC.md` / `COMMUNITY_BACKEND_SETUP.md`.

013 (Runtime 0.2, Community Discovery & Release Pages): turned the
backend into a usable, anonymous-first discovery experience --
Explore (search/filters/keyset pagination, `published_at DESC` only),
a public Release detail page, and a public profile page, all inside
`community.html`. One new `security_invoker` read-model view
(`community_release_cards`) avoids N+1 card queries; `index.html` gained
exactly one new hook (`?communityRelease=<uuid>` auto-preview, never
auto-execute) as the Portal's Runtime-handoff receiving end. Two real
bugs found and fixed live: an expired session token was silently
breaking anonymous Explore (fixed via an explicit `anon:true` flag that
never attaches a token regardless of session state), and `showMsg()`
misuse was clearing an entire composed page section instead of just an
inline status line (fixed with new non-destructive `appendMsg()`/
`toast()` helpers). A third bug -- unencoded search-term characters
(e.g. `100% off`) breaking `fetch()` outright -- was found during the
mandated search-input attack-string testing and fixed by percent-encoding
the ILIKE value. A live no-token-leak test produced a corrected,
previously-unverified finding rather than a clean pass: `file://`-opening
`index.html`/`community.html` from the same directory shares one origin
in the tested environment (`location.origin` was `"file://"` for both),
making the Portal's session token physically readable from the Runtime's
`localStorage` -- proof, not just assertion, that the origin-separation
requirement is load-bearing. No schema field changed on any existing
table; no Workspace/Release Format field changed. `API_VERSION`/
`VMP_VERSION`/`GAME_PACKAGE_FORMAT_VERSION`/`WORKSPACE_FORMAT_VERSION`/
`COMMUNITY_RELEASE_FORMAT_VERSION` all remain unchanged. `RUNTIME_VERSION`
remains `0.2.0-dev`. Full design, query contract, and acceptance-test
results: `COMMUNITY_DISCOVERY_SPEC.md`.

014 (Runtime 0.2, Community Discovery release-blocker audit): a
pre-push audit of 013 found three issues requiring fixes, not just
wording corrections. (1) The `file://` origin-sharing finding from 013
had only been documented, not enforced -- fixed by having
`community.html` detect `location.protocol === 'file:'` and disable
every authenticated capability outright (sign in, sign up, session
restore, publish, profile mutation, withdraw), both by not rendering the
forms and, defense-in-depth, by having the underlying functions
(`assertAuthAllowed()`) refuse to run; a poisoned/shared session key is
now actively cleared rather than merely ignored. Re-verified live: a
`file://` reload with a real prior session present resulted in a `null`
session immediately, while the same file served via
`http://localhost:4173` signed in normally. (2) 013's pagination report
was internally inconsistent (page size 20 claimed alongside a 9-row/
4-per-page test); audited and corrected: the 4-per-page walk was a
separate, explicitly test-only page size run as a standalone query
script, never the app's own code path; the actual production
`DISCOVERY_PAGE_SIZE=20` was then verified through the real
`community.html` UI after publishing enough fixtures to exceed one page
(25 fixtures, page-1=20, page-2=5, 0 duplicates, 0 missing, both counts
read from the app's own real network requests). (3) 013's lineage test
wording ("A->C") was audited against the canonical direct-children-only
requirement; found to be an imprecise report of a 2-level chain, not an
implementation bug -- re-verified against a genuine 3-generation chain
(A gen 0 -> B gen 1 -> D gen 2): A's direct children = [B] only, D never
appears under A; confirmed both via direct query and the live UI at all
three levels. A fourth, related latent bug was found during this audit
and fixed alongside the file:// notice: the same `showMsg()`-clears-its-
container defect from 013 also existed in three "sign-in required"
early-return branches (Profile/Publish/My Releases when not signed in),
wiping their heading; fixed with the same `appendMsg()` pattern. No
schema, format, or `RUNTIME_VERSION` change. Full corrected details:
`COMMUNITY_DISCOVERY_SPEC.md` § 2/6/10/12, `COMMUNITY_BACKEND_SETUP.md`
§ 6.
