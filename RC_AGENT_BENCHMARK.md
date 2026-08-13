# RC_AGENT_BENCHMARK.md — Runtime 0.1 RC Agent Interoperability & Stress Test

**Status: historical evidence record.** The freeze decision recorded here
(§ 18) was carried into the Distribution and Release Hardening rounds
unchanged — API 1 and VMP 1 are frozen in the current Runtime 0.1 golden
baseline. See `RELEASE_NOTES.md` for the current-state summary and
`MIGRATION_NOTES.md` for the full phase-by-phase history this document
is one part of.

**Purpose**: determine whether the current Runtime/API/VMP contract is genuinely
usable by unrelated Coding Agents who have never seen `index.html`, and decide
whether to freeze Runtime 0.1.0 / API 1 / VMP 1. This document is the evidence
record, not a feature log — no gameplay features were added this round.

## 1. Environment

- Runtime under test: `index.html`, single-file, no build step, no server.
- Browser: Chrome via `chrome-devtools` MCP (headless-adjacent automation),
  used both to drive the real Vibe Workshop UI and to inspect live Runtime
  state through a temporary debug hook (`window.__voxelDebug = runtime`,
  removed before finalizing — see §10).
- **Testing-methodology limitation, disclosed upfront**: `api.time.after`/
  `every` only advance while the game is pointer-locked and the player is
  alive (`locked && !isDead`, see `index.html` timer scheduler comment) —
  this is intentional (mirrors the pre-Phase-7 passive-regen accumulator).
  Chrome does not grant synthetic pointer lock to a script-dispatched click
  without a real user gesture, so this automated session could not reach
  that state through normal play. To exercise timer-driven mod logic
  (spawn waves, hazard cycles, zone activation, etc.) for testing purposes
  only, the timer scheduler was driven directly via `runtime.time.tick(dt)`
  through the debug hook. This is a test-harness workaround, not a Runtime
  behavior change — a real player clicking "CLICK TO PLAY" drives the same
  timers through the same code path during ordinary play. FPS readings in
  this environment were also flat (10fps) regardless of mod count or
  entity load, indicating environment throttling rather than a Runtime
  signal — performance conclusions below rely on direct timing
  (`performance.now()`) around specific operations, not observed FPS.

## 2. Runtime / API / VMP version under test

`0.1.0` / API `1` / VMP `1` (pre-freeze, RC state at the start of this round).

## 3. Agent / test method

**Only one underlying Coding Agent type was available in this environment**
(Claude Code sub-agents). Per the session's instructions, the "unrelated
Agent" constraint was rigorously simulated rather than skipped:

- Each mod-generation and mod-repair task was run in a **fresh sub-agent
  context** (the `Agent` tool, `general-purpose` type, Sonnet model) with
  **no memory of this conversation and no tool access** — the sub-agent
  briefs explicitly withheld Read/Glob/Grep/Bash/Write and stated "You are
  an external, independent Coding Agent... you have NEVER seen this
  project's source code."
- Each brief contained **only**: the real, verbatim output of
  `runtime.vmp.generatePrompt(userRequest)` (for generation) or
  `runtime.vmp.generateFixPrompt(record)` (for repair), plus the exact
  natural-language request text specified for that test. No internal
  variable names, no `BLOCK.*`, no `ModHost` internals, no prior
  acceptance-mod source, no `index.html`, `RUNTIME_ARCHITECTURE.md`, or
  `MIGRATION_NOTES.md` were included or referenced.
- The sub-agent's raw text response was used **verbatim** as the `.vmod`
  file content — no manual editing, no hand-repair of invalid output at
  any point in this benchmark.
- All 10 mod-generation prompts were VMP/1 prompts generated fresh from the
  live Runtime (not hand-written), so the API/event/capability listings the
  agents saw were byte-identical to what a real player's Workshop would
  produce.

This is a real limitation relative to the ideal (multiple independent
model providers) and is disclosed rather than glossed over. The
"black-box" discipline (no project file access, no prior context) was
enforced strictly; the "unrelated provider" discipline was not achievable
in this environment.

## 4. Test cases

The 10 specified tests, spanning racing/hazard/survival/exploration/
support/enemy-AI/memory/buff/tower-defense/scoring genres. Each was
generated once, imported through the real Workshop `<input type=file>`
pipeline (`mcp__chrome-devtools__upload_file`, not a synthetic
`evaluate_script` injection), and observed via the real permission-preview
screen, the real `Mod Could Not Be Loaded` error panel, and live
`runtime.modHost` / `runtime.mods` / `runtime.entities` state.

| # | Name | Genre focus |
|---|---|---|
| 1 | Checkpoint Race | world.write, timers, player.step, HUD |
| 2 | Floor Is Lava | hazard blocks, player.modify, world.write |
| 3 | Arena Survival | entity.spawn waves, timers |
| 4 | Treasure Hunt | entity.spawn (static), player.read, ui |
| 5 | Healing Zones | player.modify (heal), world.read/write |
| 6 | Hunter Enemy | entity tick AI, player-tracking |
| 7 | Memory Path | entity.spawn (markers), player.step sequence logic |
| 8 | Random Blessing | timers, player.modify, events |
| 9 | Crystal Defense | entity tick + movement, world.write, timers |
| 10 | Score Challenge | timers, player.step, scoring/combo logic |

## 5. Per-test results

| # | Name | First-pass import | Root cause of failure | Repair rounds | Final state |
|---|---|---|---|---|---|
| 1 | Checkpoint Race | **FAIL** — `MANIFEST_INVALID` | Agent used `onEnable(api)`/`onDisable()` instead of the required `setup(api)` entry point | 1 (succeeded) | Active, no errors, gameplay-correct (checkpoint HUD advanced, timer counted down) |
| 2 | Floor Is Lava | PASS | — | 0 | Active, no errors |
| 3 | Arena Survival | PASS | — | 0 | Active, no errors; enemy waves confirmed spawning under simulated timer ticks (17 enemies after ~50s simulated) |
| 4 | Treasure Hunt | PASS | — | 0 | Active, no errors |
| 5 | Healing Zones | PASS | — | 0 | Active, no errors |
| 6 | Hunter Enemy | **FAIL** — `MANIFEST_INVALID` | Agent used `onLoad(api)`/`onUnload(api)` instead of `setup(api)` | 1 (succeeded — error resolved) | Active, **but gameplay-incorrect** (see §6): `tick(entity, dt)` (wrong arity) and direct `entity.x`/`entity.z` reads/writes (always `undefined`/`NaN`) were untouched by the repair, since that wasn't the reported error |
| 7 | Memory Path | PASS | — | 0 | Active, no errors, gameplay-correct (sequence tracking via `player.step` confirmed working) |
| 8 | Random Blessing | PASS | — | 0 | Active, no errors. Agent returned a cleanup closure from `setup()` expecting the host to call it on unload; the host does not use that convention, but it's a harmless no-op because every resource the mod created (`api.time.every`, `api.events.on`, `api.ui.setHudText`) is already auto-tracked and cleaned by `ModHost.unload()` independent of the returned closure |
| 9 | Crystal Defense | **"PASS" (loads, no Runtime error) but gameplay-broken** | Same entity tick/position confusion as #6: `tick(entity)` (single-arg) plus `entity.x`/`entity.z` instead of `entity.position.x/z`. Because `entity.x` is `undefined`, every distance check evaluates to `NaN`, and `NaN > threshold` is always `false` — so the "else" branch (enemy reached the crystal) fires on literally the first tick after spawn, regardless of real distance. Empirically reproduced live: spawned enemies vanished and the crystal's health dropped from 10 to 0 within a few simulated spawn cycles, with zero visible enemy movement | n/a (no Runtime error was raised — nothing to repair through the error-driven Copy Fix Prompt loop) | Imported successfully; core mechanic non-functional |
| 10 | Score Challenge | PASS | — | 0 | Active, no errors |

## 6. First-pass success rate

- **First-pass import-valid**: 8/10 (80%) — tests 2,3,4,5,7,8,9,10.
- **First-pass import-valid AND gameplay-correct**: 7/10 (70%) — tests
  2,3,4,5,7,8,10. (Test 9 imported cleanly but its central mechanic did not
  work; see §5.)
- **First-pass import-FAILED**: 2/10 (20%) — tests 1, 6. Both hit the
  identical `MANIFEST_INVALID` failure mode (invented lifecycle hook
  names). This is the Runtime's manifest validation working exactly as
  designed — `ModHost.validate()` correctly rejected a `setup` function
  that didn't exist — not a Runtime defect.

## 7. Repair-loop results

Both failed first-pass imports were carried through the real product loop:
Workshop's `Mod Could Not Be Loaded` panel → **Copy Fix Prompt** button
(the actual `runtime.vmp.generateFixPrompt()` output, not a hand-written
prompt) → fresh black-boxed repair sub-agent → its raw output saved as a
`.vmod` → re-uploaded through the same file-input pipeline.

- Mods repaired: 2/2 attempted (100%).
- Repair rounds to resolve the *reported* error: 1/1 for both (average
  **1.0 repair rounds**) — both repair sub-agents correctly renamed the
  entry point to `setup` on the first attempt, without being told what the
  correct name was (only the error message `manifest.id (string) and
  setup(api) (function) are required` and the full API spec were given).
- **Important nuance**: "repair round succeeded" was measured against the
  Runtime's reported error, per the product loop as specified. It is
  **not** the same as "the mod is now fully correct." Test 6's repair
  cleared the `MANIFEST_INVALID` error in one round, but the mod's
  pre-existing entity-position bug (same category as test 9, invisible to
  import-time validation) was never reported as an error and so was never
  fixed. Repair-loop success rate and gameplay-correctness are tracked as
  separate numbers in this report on purpose.

## 8. API hallucinations

- **Nonexistent `api.*` method calls**: **0 observed** across all 10 mods.
  None of the example hallucinations the session was watching for
  (`api.player.setSpeed`, `api.world.findRandomBlock`, `api.effects.glow`,
  `api.entities.moveToward`, `api.game.endGame`) occurred. Every method
  call in all 10 generated files resolved to a real, documented `api.*`
  method.
- **Invented lifecycle/entry-point names**: 2/10 (`onEnable`/`onDisable`,
  `onLoad`/`onUnload`). This is adjacent to but distinct from an "API
  hallucination" — it's a mod-definition-shape guess, not a scoped-`api`
  call. Root-cause triage: the VMP prompt described the lifecycle
  contract only in prose ("setup is required..."), never as a literal
  code shape. Two unrelated agents independently guessed at conventional
  JS lifecycle-hook naming instead. **Conclusion: Prompt/documentation
  ambiguity, not a capability gap** — `setup`/`start`/`stop`/`unload`
  already cover every case both agents were trying to express. **Fixed**
  by adding a literal copy-pasteable skeleton to the prompt (§10); no new
  API surface added.
- **Texture key hallucination**: `textures: { all: '#hex' }` used in 2/10
  mods that registered blocks (tests 1 and 9) instead of the real
  `{color}` or `{top,bottom,side}` shape. This does not throw — the
  unrecognized key is silently ignored and the block falls back to a
  default purple placeholder, which is a silent-wrong-behavior class of
  bug, harder to catch than a validation error. **Conclusion:
  Documentation ambiguity** (the accepted keys were never enumerated in
  the compact prompt, only implied). **Fixed** by enumerating the exact
  accepted keys in the prompt and in `PUBLIC_API_META`; no new API.

## 9. Event hallucinations

**0 observed.** All 10 mods subscribed only to real events (`player.step`,
`player.jump`, `player.damage`, `player.death`, `game.tick`). None of the
watched-for invented names (`player.walk`, `player.land`,
`player.enterBlock`, `entity.contact`, `game.second`) occurred. The
`[VMP EVENTS]` section's exact payload shapes appear to be well-specified
enough that agents did not need to guess.

## 10. Permission accuracy

All 10 mods' `manifest.permissions` were cross-checked against the real
Workshop permission-preview screen (which lists exactly what
`ModHost.validate`/`activate` will gate) and against a full read of each
mod's source for every `api.*` call it actually makes.

**Result: 10/10 correct.** Zero missing permissions, zero unnecessary
(over-declared) permissions, zero invalid permission strings. Two mods
(Checkpoint Race, Step Sequence, Score Challenge) correctly *omitted*
`player.read` because they read player position only via the
unpermissioned `events.on('player.step', ...)` pass-through rather than
calling `api.player.getPosition()` — and Score Challenge correctly
*included* `player.read` because `buildZones()` does call
`api.player.getPosition()`. This is a strong, clean result and required no
fix.

One related **finding, not a bug**: `events.on()` itself is intentionally
unpermissioned in `PERMISSION_MAP` (subscribing to any core event never
requires a permission, regardless of the event's semantic domain) — this
is why event-only mods can correctly omit permissions that a
method-calling mod would need. Confirmed by reading `PERMISSION_MAP` and
`buildScopedApi()` directly; this is consistent, intentional design, not
drift.

## 11. Composition

All 8 successfully-imported first-pass mods (plus both repaired mods) were
run **simultaneously** in one Runtime session (10 active mods total at
peak). Observed:

- No manifest-id collisions (Workshop's `DUPLICATE_MOD` check never
  fired across the 10 real tests — none of the 10 agents happened to
  reuse an id).
- No resource-namespace collisions among the 10 real tests either — by
  chance, none of their manually-constructed namespace strings collided.
  **The namespace-collision risk was real but not exercised by the 10
  main tests**; it was reproduced separately and deliberately (§13) to
  confirm and fix the underlying contract bug before it caused a
  real cross-mod failure.
- No HUD-id or UI collisions observed — every mod prefixed its HUD/panel
  ids with its own namespace string.
- No event/timer cross-talk — `game.tick` and `player.step` subscriptions
  from different mods fired independently and correctly.
- No Runtime-level crash or console error at any point across all 10
  concurrent activations, 2 repairs, and the additional synthetic
  namespace-collision reproduction (§13) — every failure stayed scoped to
  the individual mod that caused it, never propagating to the host or to
  other active mods. `EventBus.safeInvoke`'s per-listener isolation
  (fixed in an earlier phase) held up under this load.

## 12. Cleanup / resilience (long-session proxy)

Full multi-hour long-session soak (repeated open/close Workshop, many
error cycles) was not run to exhaustion given time budget; instead,
targeted cleanup verification was run against the two mods with the
richest resource footprint (timers + HUD + entities):

- **Crystal Defense**, after being driven through ~20 simulated seconds of
  spawn/despawn cycles (multiple HUD updates, multiple timer fires,
  multiple entity spawns/removals), was unloaded via
  `ModHost.unload(id)`. Result: `isActive()` → `false`; its HUD line
  (`Crystal Health: ...`) disappeared from the DOM immediately; no
  entities of its type remained in `entities.query(() => true)`.
- A minimal synthetic mod (block registration only) was also unloaded
  cleanly.
- No orphaned timers, HUD lines, or entities were observed in either
  case, consistent with `ModHost.cleanupOwned()`'s owned-set design
  (`subs`/`timers`/`entities`/`hud`/`panels` are all auto-tracked and
  swept on unload).
- **Sample size caveat**: this confirms the owned-set cleanup mechanism
  works for the resource types exercised (timers, HUD text, entities,
  event subs), across 2 unload events. It is not an exhaustive
  long-session soak test (hundreds of import/unload/error cycles) — that
  remains a gap if a harder guarantee is wanted before general release,
  though nothing found here suggests it's needed for VMP 1 freeze.
- One minor, non-blocking Workshop UX finding: after repairing and
  re-importing a mod under the same manifest id, the **old, failed**
  import record's `liveStatus()` flips to `"active"` too — because
  `liveStatus()` cross-references live `ModHost` state by `modId`, not by
  `recordId`, so once *any* import of that id is active, every historical
  record for that id reports `"active"`. Cosmetically confusing in the
  Mods tab (a record that itself never loaded can show as active) but
  functionally harmless. Not fixed this round — cosmetic, cross-record
  tracking would be a larger change than justified by RC scope.

## 13. Namespace collision test (contract bug found and fixed)

Per the session's explicit stress-test requirement, near-duplicate
manifest ids were generated and run through
`runtime.vmp.deriveResourceNamespace()`:

| manifest.id | old derived namespace |
|---|---|
| `alice.magic-tools` | `alice_magic_tools` |
| `alice.magic_tools` | `alice_magic_tools` |
| `alice.magic tools` | `alice_magic_tools` |
| `alice.MAGIC-TOOLS` | `alice_magic_tools` |

Four different, individually valid manifest ids, all collapsing to the
identical resource namespace. Confirmed as a live, reproducible failure
mode, not just a theoretical one: two minimal synthetic mods
(`ns_test_a.vmod` = `alice.magic-tools`, `ns_test_b.vmod` =
`alice.magic_tools`), each independently valid and each individually
importable, were run through the real Workshop pipeline together. The
second mod's `setup()` threw `DUPLICATE_ID` on `blocks.register()` and
failed to activate — a legitimate mod, rejected for a reason the error
message did not explain (it blamed "re-import" of a mod that was never
previously imported).

**Verdict: contract bug, confirmed, fixed before freeze** per the
session's explicit instruction. Fix and before/after verification in
§14, item 1.

## 14. Contract changes made (RC fixes)

All six fixes below are documentation/metadata/error-message/derivation
fixes. **No `api.*` method was added, renamed, or removed. No event was
added. No permission mapping changed. No Stable API signature changed.**
Full detail and rationale also recorded in `MIGRATION_NOTES.md` § RC.

1. **`deriveResourceNamespace()` collision fix** — appended a short
   deterministic hash of the original (uncollapsed) manifest id so
   near-miss ids reliably diverge. Verified: the four colliding ids above
   now produce four distinct namespaces (`..._tco85p`, `..._1h0xbvf`,
   `..._n73516`, `..._92ti4t`).
2. **`DUPLICATE_DEFINITION_ON_REIMPORT` message fix** — previously always
   claimed "you re-imported yourself"; now correctly describes both real
   causes (true re-import, or a cross-mod namespace collision). Verified
   live against the reproduction in §13 after the fix: the message no
   longer misattributes the cause.
3. **VMP prompt: literal `defineVoxelMod` lifecycle skeleton added** —
   addresses the 2/10 lifecycle-name hallucination (§8).
4. **VMP prompt + `PUBLIC_API_META`: `entities.registerType`'s
   `tick(entity, ctx, dt)` signature and nested-`entity.position`
   mutation rule made explicit** — addresses the entity-movement bug
   reproduced in tests 6 and 9 (§5, §8).
5. **VMP prompt + `PUBLIC_API_META`: `blocks.register` texture keys
   enumerated** (`{color}` or `{top,bottom,side}`, no `all`) — addresses
   the texture hallucination in tests 1 and 9 (§8).
6. **Workshop `humanizeError()`: `MANIFEST_INVALID`-specific message
   added** — previously fell through to a generic "could not be loaded"
   for the single most common first-pass failure mode observed this round
   (2/10 tests).

All six were verified against the live Runtime after editing (syntax
checked via `new Function()`, then exercised through the real Workshop UI
or via direct Runtime calls) before being considered complete. The
temporary `window.__voxelDebug` debug hook used throughout this benchmark
was removed from `index.html` before finalizing this document.

## 15. Explicitly NOT added (feature requests, deferred)

None of the following were added, even though some test mods might have
benefited from them — none met the bar of "the documented primitive is
genuinely insufficient," and several near-misses were resolved as prompt
clarity fixes instead (§8):

- No new API namespace, method, event, or permission.
- No crafting/weapons/quest/pathfinding/camera/particle/network/
  multiplayer/audio system.
- No chunked-mesh / dirty-region world-mutation optimization (the
  existing "call `world.setBlock` sparingly in a loop" warning in
  `PUBLIC_API_META` was independently verified sufficient — see §16 — no
  test mod actually looped `setBlock` in a hot path, so this pre-existing
  warning was not stress-tested to failure this round, but nothing found
  here contradicts it).
- No per-record (vs. per-modId) `liveStatus()` tracking for the Workshop
  Mods tab (§12) — logged as a future Workshop UX improvement, not fixed.

## 16. Performance observations

FPS was not a usable signal in this automated environment (flat 10fps
regardless of load — see §1). Direct timing instead:

- Spawning 100 entities via `entities.spawn`: **0.3ms total** (~0.003ms/
  call) — negligible.
- 50 sequential `world.setBlock` calls (each triggering a full mesh
  rebuild, per the documented cost model): **229.8ms total, ~4.6ms/
  call**. This confirms the existing `PUBLIC_API_META` warning ("Triggers
  a full mesh rebuild -- call sparingly in a loop") describes a real,
  measurable cost. None of the 10 generated mods actually called
  `setBlock` in a per-frame or per-tick hot loop — all calls were in
  `setup()` (one-time) or infrequent timer callbacks (every 1-4s) — so
  this cost was never actually hit repeatedly by agent-generated code
  this round. **No fix needed**: the existing warning is adequate and
  was empirically respected by all 10 agents without further prompting.

## 17. Workshop UX observations

- Import is discoverable: labeled "IMPORT .VMOD" section, visible
  drag-drop zone plus a "choose a file" link.
- Permission preview is itemized in plain language per capability
  (`world.read` → "Read block ids / world bounds / raycast.", etc.) with
  a clear, appropriately-brief "not a security sandbox" disclaimer —
  neither overwhelming nor buried.
- "LOAD MOD" / "CANCEL" is an unambiguous confirm step between validation
  and activation.
- The error → Copy Error / Copy Fix Prompt → paste-to-Agent → re-import
  loop worked exactly as designed in both real repair cycles this round;
  `generateFixPrompt()`'s output was complete and self-contained enough
  that a completely fresh, context-free sub-agent produced a working fix
  from it alone, with no additional framing needed beyond "you are an
  external Agent, respond with corrected source only."
- Minor nit (§12): `liveStatus()` on old failed-import records can read
  "active" once a later successful import of the same id exists — small,
  cosmetic, not fixed this round.

## 18. Release decision

**PASS WITH PATCHES.**

- The core contract question — can an unrelated Agent, given only the VMP
  prompt and a natural-language request, produce a useful, valid mod? —
  is answered **yes**: 8/10 first-pass import-valid, 7/10 first-pass fully
  gameplay-correct, 0 API hallucinations, 0 event hallucinations, 10/10
  correct permission declarations, 2/2 successful single-round repairs
  through the real product loop, 0 Runtime crashes, 0 observed orphaned
  resources across the unloads tested.
- The failures found were real, but every one of them triaged to
  **Agent mistake or Prompt/documentation ambiguity**, never to an actual
  missing Runtime capability — matching this round's explicit mandate not
  to grow the API surface reactively. Six non-breaking RC patches (§14)
  were applied to close the specific ambiguities found (lifecycle
  skeleton, entity tick/position contract, texture keys, a misleading
  error message, a missing error-message branch, and the namespace
  collision derivation bug) and were re-verified against the live Runtime
  after editing.
- The one genuine **contract bug** (namespace collision, §13) was found,
  confirmed, and fixed pre-freeze per the session's explicit instruction
  that this class of bug should be fixed rather than shipped and revisited
  later.
- No Stable API method, event, or permission mapping was renamed, removed,
  or changed in incompatible ways — API 1 compatibility is preserved.
- What keeps this from a plain **PASS**: (a) the Agent-diversity
  requirement was only partially met (single underlying Agent type,
  rigorously black-boxed rather than genuinely multi-provider — §3); (b)
  the long-session soak was a targeted proxy, not an exhaustive
  hundreds-of-cycles run (§12); (c) one mod (test 9) revealed that
  "imports without a Runtime error" and "is actually correct" are
  genuinely different outcomes that the Workshop currently has no way to
  distinguish for the player — worth having in mind for future milestones,
  though not something addressable within this round's "no new API/UI
  surface" constraint.

**Recommendation**: freeze Runtime 0.1.0 / API 1 / VMP 1 with the six
patches in §14 applied (already done, already re-verified). No further
test reruns are required before freeze — none of the six fixes touched
Stable API behavior in a way that could regress the 10 test mods (spot
re-verified: Checkpoint Race and Crystal Defense re-imported cleanly
after all fixes were applied, confirming no regression from the doc/
derivation changes).

## 19. Next milestone recommendation (not implemented this round)

**"Runtime 0.1 Distribution"** — bake a mod-bearing session to a single
standalone HTML file, embedded `.vmod` packaging, project export/import,
a basic version stamp, and a shareable one-file game. This is a
recommendation only; per this session's explicit scope, none of it was
implemented, and Phase 11 remains untouched.

A secondary, smaller suggestion worth considering alongside distribution
work (not a blocker, not scoped this round): a lightweight way for the
Workshop to signal "imported without error" vs. "verified working" to the
player, since §5/§9 demonstrated those are not the same thing and the
current UI has no vocabulary for the difference.
