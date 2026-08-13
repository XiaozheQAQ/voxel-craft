# Test Matrix

Regression + Mod API test tracking. Update after every phase that touches
gameplay code (per `RUNTIME_PLAN.md`).

## Regression checklist (manual, ~24 items)

Run the full list after Phases 2, 3, 4, 6, 7 (anything touching gameplay
call sites). Phase 1 gets it once as the **baseline recording**.

| # | Check | Baseline (Phase 1) |
|---|---|---|
| 1 | HTML opens directly (double-click) | ✅ |
| 2 | Start screen (overlay) shows | ✅ |
| 3 | Pointer lock engages on "Click to Play" | ✅ |
| 4 | WASD moves the player | ✅ |
| 5 | Mouse look works | ✅ |
| 6 | Jump (Space) works | ✅ |
| 7 | Sprint (Shift) works | ✅ |
| 8 | Collision with terrain works | ✅ |
| 9 | World generation produces terrain | ✅ |
| 10 | Trees generate | ✅ |
| 11 | Block targeting (crosshair highlight) works | ✅ |
| 12 | Mining (hold left click) works | ✅ |
| 13 | Mining progress ring animates | ✅ |
| 14 | Inventory count increases on mine | ✅ |
| 15 | Hotbar UI reflects inventory | ✅ |
| 16 | Scroll wheel / 1-6 keys select hotbar slot | ✅ |
| 17 | Block placement (right click) works | ✅ |
| 18 | Inventory count decreases on place | ✅ |
| 19 | Fall damage triggers on hard landing | ✅ |
| 20 | Death (health to 0) triggers death screen | ✅ |
| 21 | Respawn after death works | ✅ |
| 22 | Passive health regen works after no-damage window | ✅ |
| 23 | "New World" button regenerates terrain | ✅ |
| 24 | FPS display updates | ✅ |
| 25 | Window resize doesn't break canvas/render | ✅ |

**Phase 1 verification method**: `new Function()` syntax check on the
extracted `<script>` contents (confirms no parse error introduced), plus
an actual browser load via chrome-devtools (`file://` open of
`index.html`): world generated, hotbar/hearts/HUD rendered, FPS counter
ran (~180fps), overlay/buttons present, only pre-existing benign console
messages (a `willReadFrequently` Canvas2D perf hint from `buildAtlas()`'s
`getImageData` calls, and a `file://` pointer-lock-origin warning — both
unrelated to this change and present on the pre-Phase-1 file too). Since
the Phase 1 diff is purely additive with zero call sites into existing
code, this stands as the baseline recording for later phases to diff
against. Full interactive input testing (WASD/mining/placement/etc, items
4-25 above) deferred to Phase 2+ where gameplay call sites first change
(see `RUNTIME_PLAN.md` Phase 1 entry, `MIGRATION_NOTES.md` 001) — items
1-3 and 9-11 confirmed visually via the accessibility snapshot this pass.

## Phase 3 verification (world/player facade + collapsed mesh-rebuild funnel)

Touched the riskiest call sites in the file (mining completion, `tryPlace`,
`regenBtn`). Verified via a temporary `window.__voxelDebug = runtime` hook
(removed immediately after, never shipped) exercising every facade method
directly against the live running game:

| Check | Result |
|---|---|
| `world.setBlock` mutates target block + triggers mesh rebuild | ✅ (block 1→3 confirmed via `getBlock`) |
| `world.regenerate` resets world+spawn without throwing | ✅ |
| `player.setPosition` mutates position | ✅ |
| `player.damage`/`heal` mutate health symmetrically | ✅ (20→18→20) |
| `player.giveItem` mutates inventory + refreshes hotbar UI | ✅ (Stone slot showed "5") |
| Clean reload after hook removal: no console errors, HUD/hotbar/hearts render, inventory back to 0s | ✅ |

Full interactive mouse/pointer-lock mining/placement click-through deferred
to a human pass (chrome-devtools automation can't easily grant real
pointer-lock without a user gesture) — the facade-level test above
exercises the exact production code paths that changed this phase, which
is the actual delta under test.

## Phase 4 verification (ModHost + defineVoxelMod + event wiring)

Verified via a temporary `window.__voxelDebug = runtime` hook (removed
immediately after, never shipped), on both the default URL and
`file://...index.html?mods=1`:

| Check | Result |
|---|---|
| Default boot (no `?mods=1`): no mod loaded, no console errors, HUD unchanged | ✅ |
| `?mods=1` boot: `dev.superjump` registers with no errors | ✅ |
| `window.defineVoxelMod` reachable from outside the IIFE closure | ✅ |
| Real `player.jump` event path: Super Jump mod boosts `velY` (0→8) via `api.player.setVelocityY` | ✅ |
| Duplicate mod id → structured `DUPLICATE_MOD` error, no throw, doesn't affect the already-loaded mod | ✅ |
| Malformed manifest (`{}`) → structured `MANIFEST_INVALID` error, no throw | ✅ |
| Mod whose `setup()` throws → structured `SETUP_EXCEPTION` error, page keeps running, other mods unaffected | ✅ |
| `block.break.before` listener calling `.cancel()` → target block unchanged | ✅ |
| Clean reload after hook removal (both URLs): no console errors | ✅ |

## Phase 5 verification (permission gating, ownership tracking, unload)

Verified via a temporary `window.__voxelDebug = runtime` hook (removed
immediately after, never shipped):

| Check | Result |
|---|---|
| Super Jump still works after gating (correct permissions declared) | ✅ (0→8) |
| Mod without `world.write` calling `world.setBlock` → thrown `PERMISSION_DENIED` | ✅ |
| Mod subscribed to `game.tick`, unloaded, listener stops firing | ✅ (count stayed at 2 across 2 more emits) |
| `unload()` on a mod id that isn't loaded → structured `MOD_NOT_FOUND`, no throw | ✅ |
| Mod declaring a missing dependency → `DEPENDENCY_MISSING`, never registered | ✅ |
| Clean reload afterward (hook removed): no console errors, HUD intact | ✅ |

## Phase 6 verification (custom blocks, items, entities)

Verified via a temporary `window.__voxelDebug = runtime` hook (removed
immediately after, never shipped), plus a viewport screenshot for visual
confirmation:

| Check | Result |
|---|---|
| Default boot: atlas grid resize (4x2→8x8) doesn't corrupt core terrain textures | ✅ (screenshot confirmed) |
| `example:crystal` registers with correct sequential numeric id (7, after core's 0-6) and an allocated tile (8) | ✅ |
| Custom block placeable/readable via `world.setBlock`/`getBlock` using its numeric id, same code path as core blocks | ✅ |
| `example:chaser` entity type registers + spawns | ✅ |
| Entity genuinely ticks from the real render loop (not just manual test emits) — tracked live player position across real frames | ✅ (closed distance from ~4 units to ~0 during page-render time alone) |
| Entity contact damage fires via `player.damage`, drives real health loss | ✅ |
| Death/respawn cycle still fires correctly when triggered by entity damage (not just fall damage) | ✅ (health reset to MAX during test, chaser resumed damaging after respawn) |
| Damage cooldown fix: gradual damage instead of instant kill | ✅ (health 11/20 after ~1s of contact, vs. 0 before the fix) |
| No console errors at any point (registration, ticking, rendering, damage, death, respawn) | ✅ |
| Clean reload on default URL afterward | ✅ |

## Phase 6.5 verification (contract reconciliation)

Verified via a temporary `window.__voxelDebug = runtime` hook (removed
before finalizing), on `?mods=1`:

| Check | Result |
|---|---|
| `runtime.world.getBlock` (internal) returns numeric for a cell | ✅ (`3`) |
| A freshly-captured mod-scoped `api.world.getBlock` returns string for the SAME cell | ✅ (`'core:stone'`) |
| `dev.crystalblock`'s own source calls `api.world.setBlock(x,y,z,'example:crystal')` — string id only, no numeric id anywhere in the mod | ✅ (code review + placement confirmed at the expected cell) |
| `player.getInventory()` returns string-keyed object on the scoped api | ✅ (confirmed via Test C/E mods' correct behavior, which depend on this) |
| Default boot unaffected by the boundary change (internal code never touches `ModHost`) | ✅ |

## Phase 7 verification (api.time / api.ui / api.effects / api.storage / api.input)

Verified via a temporary `window.__voxelDebug = runtime` hook (removed
before finalizing):

| Check | Result |
|---|---|
| All 5 mods (`dev.superjump`, `dev.crystalblock`, `dev.chaser`, `dev.lightninggrass`, `dev.targetgame`) register with zero errors on `?mods=1` | ✅ |
| `api.ui.setHudText` renders visible, correctly-styled HUD lines (screenshot-confirmed, positioned below pos/fps without overlap) | ✅ |
| `api.effects.flashScreen(color, ms)` sets a custom-color radial-gradient element to opacity 1 | ✅ |
| `api.time.every`-driven target-game countdown decrements correctly over simulated+real ticks (60s→55s over 5 ticks) | ✅ |
| Passive regen (migrated off `loop._regenAccum` onto `timeScheduler.every`) behaviorally identical: 15→16 HP after real ~10.5s wait (6s no-damage gate + 4s regen interval) | ✅ (simulated-only ticks are **insufficient** here since the 6s gate reads `performance.now()` directly — a faithful port of the original; real-time wait was required and used) |
| Default boot (no `?mods=1`) unaffected — clean console, identical HUD/hearts/hotbar | ✅ |

**Part G — error isolation** (bug found + fixed during this phase):

| Check | Result |
|---|---|
| Before fix: throwing event listener stopped later listeners on the same event AND threw out of `emit()` | ❌ (confirmed broken, then fixed) |
| After fix: throwing listener isolated, later listener on same event still runs, `emit()` doesn't throw outward | ✅ |
| Cancelable event: throwing `.before` listener doesn't block a later listener from legitimately cancelling | ✅ |
| Both deliberately-thrown errors logged structurally via `VmpErrorLog` (`EVENT_HANDLER_EXCEPTION`) | ✅ (2 entries confirmed) |
| Throwing timer callback: scheduler keeps running, other timer still fires, error logged | ✅ |
| Throwing entity `tick`: doesn't stop other entities, error logged and attributed to owning mod | ✅ |

## Part F — Ownership destruction test

Temporary `dev.ownershiptest` mod (never shipped, defined/registered/
unloaded entirely through the debug hook during verification) owning one
of every resource type simultaneously, then `ModHost.unload()`:

| Resource | Before unload | After unload |
|---|---|---|
| Event subscription (`game.tick`) | firing (count=1 after 1 emit) | **stopped** (count unchanged after 2 more emits) |
| Repeating timer (`api.time.every`, 500ms) | firing (count=2 after 1.2s simulated) | **stopped** (count unchanged after 2 more seconds simulated) |
| Delayed timer (`api.time.after`, 100s) | pending | **never fired**, even after 200s simulated post-unload |
| UI element (`api.ui.setHudText`) | visible in `#modUiRoot` | **removed** from DOM |
| Spawned entity (`api.entities.spawn`) | present, queryable | **removed**, `entities.get()` returns `undefined` |
| Storage (`api.storage.set`) | readable | **still readable after unload** (correct — unload ≠ delete) |
| Second `unload()` call on the same (now-gone) mod id | — | structured `MOD_NOT_FOUND`, **no throw** |
| Another mod's resources (`dev.superjump`'s listener, `dev.chaser`'s entity) | working | **unaffected** by the unrelated unload |

All checks passed. Not left registered on default boot.

## Mod API acceptance tests (final, all five passing)

See `VMP_SPEC.md` § Acceptance tests for full descriptions. All verified
live in-browser via `?mods=1`, in a single fresh page session, zero mod
errors at boot.

| Test | Mod | Public APIs used | Permissions declared | Result |
|---|---|---|---|---|
| A — Super Jump | `dev.superjump` | `events.on`, `player.getVelocity`/`setVelocityY` | `player.read`, `player.modify` | ✅ `velY` 0→8 via real `player.jump` path |
| B — Lightning Grass | `dev.lightninggrass` | `events.on('player.step')`, `effects.flashScreen`, `player.damage` | `player.modify` | ✅ damage+flash on forced grass step, no-op on stone (deterministic `Math.random` override per task instructions) |
| C — New Block | `dev.crystalblock` | `blocks.register`, `player.getPosition`, `world.setBlock` (string id only) | `world.write`, `player.read` | ✅ block placed at expected cell, no numeric id in mod source |
| D — Simple Enemy | `dev.chaser` | `entities.registerType`/`spawn`, `player.getPosition`/`damage` | `player.read`, `player.modify`, `entity.spawn` | ✅ real chase+contact-damage over real frames |
| E — Non-Minecraft minigame | `dev.targetgame` | `blocks.register`, `world.*`, `ui.*`, `time.every`, `events.on('player.step')` | `world.read`, `world.write`, `ui` | ✅ score increments on target step, target relocates, old cell restored, timer counts down, banner on end |

## Phase 8 verification — `.vmod` import (10 required tests)

Verified via a temporary `window.__voxelDebug = runtime` hook (removed
before finalizing), using `runtime.mods.importSource()` directly (same
code path `importFile` uses after `File.text()`):

| # | Test | Result |
|---|---|---|
| 1 | Import a valid Super-Jump-equivalent `.vmod` → real gameplay effect | ✅ `velY` 0→8 via real `player.jump` path after import |
| 2 | Import a valid Crystal-Block-equivalent `.vmod` → string-id registration + placement | ✅ `imported:ruby` registered, placed block's numeric id matches the registry entry (mod source used only the string id) |
| 3 | Syntax-invalid `.vmod` | ✅ `VMOD_SYNTAX_ERROR`, Runtime survives |
| 4 | Zero-definition `.vmod` | ✅ `VMOD_NO_DEFINITION`, Runtime survives |
| 5 | Two-definition `.vmod` | ✅ `VMOD_MULTIPLE_DEFINITIONS`, **neither** mod activated |
| 6 | Wrong `apiVersion` | ✅ `API_VERSION_MISMATCH`; instrumented `setup()` confirmed **never called** |
| 7 | `setup()` creates an event subscription + HUD element, then throws | ✅ `SETUP_EXCEPTION`; post-failure the event no longer fires and the HUD element is gone (rollback confirmed) |
| 8a | Duplicate import while still active | ✅ `DUPLICATE_MOD` |
| 8b | Re-import after unload, mod previously registered a persistent block definition | ✅ `DUPLICATE_DEFINITION_ON_REIMPORT` with a human-readable "reload the page" explanation (not a bare registry code) |
| 9 | Pre-existing dev-gated acceptance mods (A/D checked) unaffected by an unrelated import | ✅ `dev.superjump` still works, `dev.chaser`'s entity still present |
| 10 | Default boot (no `?mods=1`) unchanged | ✅ screenshot-confirmed identical to pre-Phase-8 baseline |

## Phase 8.5 verification — metadata drift audit

| Check | Result |
|---|---|
| `?dev=1` boot runs `auditApiMetadata()`; default boot does not (no console noise) | ✅ |
| First run found real drift: `storage.get/set/remove` documented+spec'd as gated but not wired into `PERMISSION_MAP` | ❌→✅ (found, fixed by adding the 3 entries + wrapping `storage` in `gate()`, re-audited clean) |
| Post-fix `?dev=1` run | ✅ `console.info` "PUBLIC_API_META and PERMISSION_MAP agree, no drift detected." |
| `?mods=1` boot after the storage fix — all 5 acceptance mods still register with zero errors (none used `api.storage`, so no behavior change) | ✅ |

## Phase 9 verification — VMP prompt generation

| Check | Result |
|---|---|
| Generated prompt contains all 7 sections in order | ✅ |
| Contains every API/event needed by acceptance tests A-E (checked term-by-term, zero missing) | ✅ |
| No internal-id leakage (`BLOCK.`, `BlockRegistry.toNumeric`, `Uint8Array`, `BLOCK_TILES`, `BLOCK_HARDNESS` all absent) | ✅ |
| `generatePrompt('')`/`(null)`/`(42)`/`('   ')` all throw structured `VMP_INVALID_REQUEST` | ✅ |
| `[INSTALLED MODS]` lists live mods (id/version/name) without dumping source, on a `?mods=1` session with all 5 dev mods loaded | ✅ |
| **Documentation-only agent simulation**: authored `demo.healthwatch` (10s health banner + one-shot low-health flash) using only the generated prompt | See below |

**Documentation-only agent simulation, detailed**: first attempt declared
`permissions:['player.read']` but called `api.ui.showBanner` — the
Runtime correctly rejected it with `PERMISSION_DENIED` reported inside a
`TIMER_EXCEPTION` (the scheduler kept running, no crash, error correctly
attributed to `demo.healthwatch`). Fixed by adding the `ui` permission
(exactly what a real agent would do upon reading the error) and
re-imported: banner rendered `"Health: 19"` after a simulated 10s tick;
after `damage(16)` dropping health to 4, the low-health screen flash
triggered (confirmed via a live `opacity:1` red radial-gradient element).
This exercised the complete chain: Runtime metadata → generated prompt →
mod source → importer → capture → validation → activation → gameplay →
**error → self-correction → re-import → success**.

## Final full regression (post Phase 9)

Re-ran after all Phase 8/8.5/9 work: default boot (clean, screenshot-
matched baseline), `?mods=1` boot (all 5 dev mods, zero errors),
`?dev=1` boot (clean metadata audit), all 5 acceptance tests A-E
re-confirmed working, ownership/ImportRecord mechanics unaffected. No
regressions found.

## Phase 10 verification — Vibe Workshop UI

All tests performed via real in-browser click-through (chrome-devtools),
including genuine `.vmod` file uploads from disk (`upload_file` on the
Workshop's own file input, not simulated JS calls) — this is the first
phase verified end-to-end through actual UI interaction rather than
`evaluate_script` alone.

### Full happy-path acceptance test (brief § "Full user-flow acceptance test")

| Step | Result |
|---|---|
| Open `index.html` directly, default boot | ✅ clean console, "Vibe Workshop" button visible in start overlay |
| Click "Vibe Workshop" | ✅ opens, Create tab active, no pointer-lock error (was never locked) |
| Type a gameplay request | ✅ textarea accepts input, properly labeled (a11y-clean after fix) |
| Click "Generate Agent Prompt" | ✅ prompt rendered, byte-identical in structure/content to direct `runtime.vmp.generatePrompt()` output verified in Phase 9 |
| Click "Copy Prompt" | ✅ (clipboard API path; fallback toast path code-reviewed, not independently triggerable in this environment) |
| Upload a valid `.vmod` (`good-lightning.vmod`, real file from disk) | ✅ permission preview shown: "Workshop Lightning Grass wants access to: ✓ player.modify — Move, damage/heal, or otherwise change the player." |
| Click "Load Mod" | ✅ success panel: "✓ Workshop Lightning Grass / workshop.lightningtest v1.0.0 / Loaded successfully." + Play button |
| Click "Play" | ✅ Workshop closes |
| Re-open Workshop → Mods tab | ✅ shows "Workshop Lightning Grass — ACTIVE — workshop.lightningtest v1.0.0 · good-lightning.vmod" |
| Click "Unload for this session" | ✅ confirmation modal shown with exact honest wording (events/timers/UI/entities removed, storage kept, some definitions remain reserved) |
| Confirm unload | ✅ badge changes to "UNLOADED", Mods count decrements, no console errors |
| Close Workshop, game continues | ✅ clean screenshot, hearts/hotbar/HUD normal |

### Error-flow acceptance test (brief § "Error-flow acceptance test")

| Step | Result |
|---|---|
| Open Workshop, upload a broken `.vmod` (`broken-perm.vmod` — calls `api.ui.showBanner` without declaring `ui`) | ✅ |
| Permission preview shown first (manifest declared 0 permissions, so validation alone doesn't yet know about the runtime violation — correct, matches the design: validation checks manifest shape, not what `setup()` will call) | ✅ "(no permissions requested)" |
| Click "Load Mod" (activation runs `setup()`, which is where the real violation surfaces) | ✅ Workshop stays open |
| Human-readable error appears | ✅ **before fix**: "workshop.brokentest ran into an error while running." (too generic) → **after `humanizeError`/`extractPermissionRootCause` fix**: "workshop.brokentest tried to use api.ui.showBanner, which needs permission "ui", not declared in its manifest." |
| Technical details available | ✅ `<details>` block with full structured `{mod, phase, errors}` JSON, including stack trace |
| Game remains functional | ✅ no console errors beyond the expected structured `[VMP mod error]` log |
| Another valid mod can still be imported afterward | ✅ `good-lightning.vmod` imported successfully immediately after, in the same session |

### Permission error flow (brief § 36, the exact `showBanner`-without-`ui` case)

Covered above — root-cause unwrapping verified explicitly: the outer
error code (`SETUP_EXCEPTION`) is never shown alone; the player sees the
specific missing permission and the specific call that needed it.

### RC audit spot-checks (Part B, items 41-48)

| Item | Result |
|---|---|
| 41/Metadata drift audit, re-run post-Workshop (`?dev=1`) | ✅ "PUBLIC_API_META and PERMISSION_MAP agree, no drift detected." |
| 43/Ownership cleanup via the NEW two-step (`beginImport`+`confirmImport`) path specifically | ✅ event subscription stopped firing, HUD element removed, after `ModHost.unload()` |
| 44/Re-import after unload, mod registered a persistent entity type, via `confirmImport` specifically (not just `importSource`) | ✅ `beginImport` → `'validated'` (manifest id no longer collides); `confirmImport` → `'failed'` / `DUPLICATE_DEFINITION_ON_REIMPORT` |
| 44/Pending import never activates until `confirmImport` is called | ✅ `ModHost.isActive(id)` is `false` for a validated-but-unconfirmed record |
| 45/Trust-model wording audit (grep for sandbox/secure/isolated across `index.html`) | ✅ every occurrence correctly frames it as NOT a sandbox; no false claims found |
| 47/Default boot (no `?mods=1`/`?dev=1`) | ✅ Workshop button present, zero dev-mod/debug-UI/console noise |
| 48/Dev mods (`?mods=1`) shown in Workshop Mods tab as ordinary active "(built-in)" entries, never loaded without the flag | ✅ |

### Runtime 0.1 Distribution acceptance tests

| Test | Result |
|---|---|
| A — Super Jump + Health Watch, baked, opened fresh | ✅ both Mods active, 0 errors, HUD live |
| B — Checkpoint Race + Random Blessing (real RC-benchmark Mods), baked, opened fresh | ✅ both active, 0 errors, HUD live |
| C — remix: open B's baked game → Workshop → import Healing Zones → re-bake → open | ✅ all 3 Mods active, 0 errors — flagship share→remix→re-share flow confirmed |
| Re-bake structural integrity (real `DOMParser`, not substring counting) | ✅ exactly 1 `#voxel-game-package` container, 2 `<script>` tags, payload decodes to exactly the intended Mod count — no nesting |
| Hostile content (`</script>`, `<script>alert(1)</script>`, HTML comments, quotes, backticks, emoji, Chinese text in manifest name/description/source) | ✅ 0 parser errors, byte-for-byte round-trip of the hostile string, mod activated normally, no injected script executed |
| Corrupted package (bad formatVersion/format/apiVersion/mods shape, invalid base64, invalid JSON) — via `.vgame` import path | ✅ every case throws a specific structured error code, none silently succeeds |
| Corrupted **embedded** package baked into a real HTML, opened fresh | ✅ Runtime boots fully and normally (menu/world/hearts/hotbar all present) — does not blank-page |
| Regression: default boot, `?dev=1` metadata audit, `?mods=1` acceptance Mods A-E | ✅ all clean, 0 errors, 0 metadata drift |
| Export eligibility: `?mods=1` dev Mods never appear as exportable | ✅ `runtime.mods.listImports().length === 0` under `?mods=1` despite 5 active Mods |

### Accessibility fix

Initial implementation triggered browser a11y warnings ("No label
associated with a form field", "form field element should have an id or
name attribute") for the request textarea, prompt output, and file
input. Fixed by adding `id`/`for`/`name`/`aria-label` associations
throughout. Re-verified: zero a11y console warnings after the fix.

### Runtime 0.1 Release Hardening & Golden Build

| Test | Result |
|---|---|
| Pristine-capture invariant (live, not just reasoned about): open Workshop (creates `#workshopOverlay`), take damage/move | ✅ pristine snapshot excludes `#workshopOverlay` and current position/HUD values; live document includes them; pristine still contains full CSS (`--panel-bg`) and full script (`WorkshopController` source) |
| Comment-injection defense: bake with title containing `-->` and `<script>alert(1)</script>` | ✅ 0 injected script tags after real `DOMParser` parse, `alert(1)` never appears unescaped |
| Dev `.vmod` file picker gating: default boot vs. `?dev=1` | ✅ absent by default, present under `?dev=1` |
| Golden standalone: genuine `file://` open (not Blob/DOMParser) of a real downloaded, disk-persisted file | ✅ mods active, 0 errors, gameplay (entity movement) confirmed, Workshop + prompt generation correct |
| Cross-context: same file opened in a fresh new tab | ✅ bootstraps independently, no shared state; a benign Chrome/DevTools navigation console message appeared but did not affect functionality |
| `.vgame` round-trip: export → fresh Runtime → import → export again | ✅ title/description/author/settings/mod ids/mod source lengths all identical |
| Standalone round-trip: bake A → open → bake B (no Mod changes) | ✅ byte-identical size, 1 container, 2 script tags, same 2 mods — no growth, no nesting |
| Remix golden path (final run): golden game (2 Mods) + import 1 more → re-bake → open fresh | ✅ all 3 active, 0 errors, `[INSTALLED MODS]` prompt context correct |
| 8 error-fixture golden path (syntax-invalid, zero-definition, multiple-definition, API mismatch, permission failure, setup failure, invalid `.vgame`, missing dependency) | ✅ every case produces a specific structured error code (`VMOD_SYNTAX_ERROR`, `VMOD_NO_DEFINITION`, `VMOD_MULTIPLE_DEFINITIONS`, `API_VERSION_MISMATCH`, `SETUP_EXCEPTION` ×2, `PACKAGE_FORMAT_VERSION_MISMATCH`, `DEPENDENCY_MISSING`); Runtime remained responsive after all 8 |
| Console audit: default boot, `?dev=1`, `?mods=1` | ✅ only the pre-existing benign Canvas2D `willReadFrequently` warning; `?dev=1` shows "no drift detected" |

## Runtime 0.2.0-dev — Transactional Mod Revision acceptance tests

Full test-by-test results, methodology (including why `api.time` firing
specifically can't be observed under headless automation, and the
`game.tick`-counter proxy used instead), and the real Agent-revision
round-trip transcript: `MOD_REVISION_SPEC.md` § Testing requirements /
acceptance test results. Summary: all of Tests A–J pass, plus a live
`zh-CN` Agent-revision round-trip with zero repair rounds; ordinary
`Import .vmod` regression (duplicate-id rejection) reconfirmed unchanged;
`.vgame`/baked-HTML export reconfirmed to embed only current Mod versions,
no revision history.

## Runtime 0.2.0-dev — Revision History & Safe Undo acceptance tests

Full results (A–L, plus the flagship bilingual real-Agent branch test):
`REVISION_HISTORY_SPEC.md` § Testing. Summary: basic history (V1/V2/V3,
sources+reasons preserved) ✅; transactional Undo/Redo (old listener
frozen, new one live, no reload) ✅; block AND entity undo (numeric-id/
tick-closure correctness) ✅; failed restore of a dev-hook-corrupted
historical source (current version untouched, clear error, Runtime
responsive) ✅; branch via "Revise from this version" (unique "Revision N"
labels after fixing a real seq-collision bug) ✅; a long repeated undo/
revise/restore cycle (exactly one live listener, correct current pointer
throughout) ✅; multi-Mod isolation during undo/redo ✅; export/bake
(current-version-only, zero history leakage, re-verified) ✅; tombstone
reactivation of a removed block (same numeric id reused, world cell never
corrupted -- after fixing a real bug found during this pass) ✅;
transaction-boundary audit (world/player/storage mutations from a failed
revision are honestly documented as NOT reverted) — finding recorded, not
a pass/fail. Real Agent flagship test (revise → dislike → undo → "revise
from this version" on the older base → branch), conducted live entirely in
`zh-CN` end-to-end: ✅, zero repair rounds.

## Runtime 0.2.0-dev — Creation Workspace & Provenance results

Full results: `WORKSPACE_SPEC.md` § Testing. Summary: full round trip
(create V1→V3, branch V4 from V2, save `.vwork`, fresh browser session,
open) ✅ — exact ancestry restored, V4 correctly current with live
gameplay confirmed running; Undo/Restore/"Revise from this version" all
work immediately after reopening, including the older-base branch warning
✅; Fork Workspace produces a new id/generation/parent pointer without
mutating the pre-fork identity or its already-written file ✅; dirty-state
semantics (`.vwork` save clears it, `.vgame` export deliberately does not)
✅; a hand-crafted ancestry cycle in an imported Workspace's history is
rejected (`WORKSPACE_HISTORY_INVALID`) before any Mod activation, current
session unaffected ✅; opening into a dirty session is rejected
(`WORKSPACE_SESSION_NOT_CLEAN`) ✅; `.vgame`/Bake remain history-free by
construction (unmodified code path).

## Runtime 0.2.0-dev — Community Foundation & Publish Model results

Full results: `COMMUNITY_RELEASE_SPEC.md` § Testing. Summary: original
Workspace → Release (`generation:0`, no parent) ✅; private-history-leak
test (4-revision branched Workspace with secret revision-request strings
→ published Release contains only current source, zero history/request
traces, verified by direct file inspection) ✅; Release open/play (Mod
activated, live tick counter confirmed) ✅; Release → Bake (title/metadata
correctly reflected, after fixing a found gap) ✅; Release → Start Remix
(correct provenance/generation, after fixing a button-conflict bug) ✅;
A→B→C multi-generation chain verified with three DIRECTLY captured
files (each release's `parentReleaseId` exactly matching its predecessor's
`releaseId`, generation incrementing 0→1→2) ✅; corrupt/malformed Release
rejected (`RELEASE_VALIDATION_FAILED`) before any activation, current
session unaffected ✅; dirty-session rejection (`RELEASE_SESSION_NOT_CLEAN`)
✅; `.vgame`/Bake remain history-free by construction (Release building
reads nothing from RevisionHistoryStore).

## Runtime 0.2 — Community Backend Foundation results

Full results: `COMMUNITY_BACKEND_SPEC.md` § 12. All run live against the
actual linked Supabase project, a real deployed Edge Function, and a real
`file://` Runtime session. Summary: schema migration applies cleanly ✅;
Security/Performance Advisor clean after one follow-up fix migration
(0 WARN/ERROR, only expected `unused_index` INFO noise) ✅; sign-up →
profile → publish → my-releases → view-by-id full loop via the real
Portal + backend ✅; hostile content (`<script>alert(1)</script>`,
quotes) rendered as literal text in the Portal preview and My-Releases
list, never executed ✅; parent-forgery (client `generation:999`)
silently ignored, server recorded the true `parent.generation+1` ✅; User
B direct-REST attacks against User A's release (unpublish, retitle,
`creator_id` forgery) all blocked (RLS-filtered zero-row updates / 403
`42501`) ✅; fully anonymous (no `Authorization` header) publish/
profile-edit/unpublish/Edge-Function attempts all blocked ✅; real
`file://` Runtime → `runtime.community.getRelease` → preview (reusing the
existing `communityPendingImport`/trust-notice/Open pipeline) → Mod
activated ✅; flagship A→B remote lineage (Runtime fetch A → Start Remix →
local `.vrelease` B export with correct `communityParentReleaseId` →
Portal publish B → live DB row: `B.parent_release_id === A.id`,
`B.generation === A.generation + 1`) ✅; unpublish by the real owner via
the Portal UI → row flips `is_published:false` → subsequent anonymous
read returns zero rows ✅; i18n catalog parity (`?dev=1` audit) after all
additions ✅; entire test pass conducted live in zh-CN ✅; secret scan of
`index.html`/`community.html`/`supabase/migrations`/`supabase/functions`
for service-role/secret key patterns — zero matches ✅. 3+ Mod Release
round-trip covered by construction, not re-run as a dedicated pass (the
publish RPC's mod-index insert has no mod-count-specific code path).
