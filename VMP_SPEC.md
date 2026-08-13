# VMP — Vibe Mod Protocol

Source of truth for the mod format and the Agent-facing prompt protocol.
Target audience is primarily a Coding Agent/LLM, not a human — favor
deterministic, structured, versioned text over prose.

Protocol version: **VMP/1** · matches Runtime `0.1.0` / API `1`.

## Mod format

A `.vmod` file is **plain JavaScript text** — no ZIP, no bundler, no build
step. It must contain exactly one top-level call:

```js
defineVoxelMod({
  manifest: {
    id: "author.mod-name",      // "namespace.slug", never "core.*"
    name: "Human Readable Name",
    version: "1.0.0",
    apiVersion: 1,
    description: "...",
    dependencies: {},           // { "other.mod": "^1.0.0" }
    conflicts: [],               // ["some.mod"]
    permissions: []              // e.g. ["world.write", "player.modify"]
  },

  setup(api) {
    // registration + event wiring goes here
  },

  start(api) {},   // optional
  stop(api) {},    // optional
  unload(api) {}   // optional
});
```

Lifecycle kept intentionally minimal: `setup` (register things, subscribe
to events) is required; `start`/`stop`/`unload` are optional hooks for mods
that need explicit begin/end semantics beyond event subscriptions. Runtime
tracks ownership of everything a mod creates through the scoped `api`
handle (subscriptions, timers, UI, entities) so `unload` auto-cleans even
if the mod author writes no cleanup code at all.

## Namespaces

All registrable resources use `namespace:id` (e.g. `core:stone`,
`magic:crystal`, `tower:turret`). The `core` namespace is reserved for the
Runtime's own built-in blocks/items/entities and cannot be registered into
by mods — attempting to do so throws `PROTECTED_NAMESPACE`. Runtime maps
string ids to internal numeric ids privately; **mods never see or depend
on numeric ids — this is enforced at the scoped api boundary, not just a
convention** (verified: `api.world.getBlock`/`setBlock`,
`api.player.getInventory`/`giveItem`/`takeItem`, and every `block.*`
event payload all speak string ids only; see
`RUNTIME_ARCHITECTURE.md` § The internal/public identity boundary).

**Registration is permanent for the page session.** There is no
`unregister`/hot-reload path in v0.1: a mod that registers
`example:crystal`, gets unloaded, and is loaded again will hit
`DUPLICATE_ID` on the second `blocks.register`/`items.register`/
`entities.registerType` call. This is a deliberate v0.1 limitation
(chosen over building real hot-reload, which would need to track which
mod owns which registry entry and decide what happens to existing world
cells/entities of that type) — see
`RUNTIME_ARCHITECTURE.md` § Definition registration vs. runtime instances.

## API version

Manifest declares `apiVersion: 1`. Runtime checks compatibility (exact
match or documented range) before calling `setup`; a mismatch produces a
structured error and the mod is not started — other mods are unaffected.

## Permissions / capabilities

Declared in `manifest.permissions`. This is a **declared-trust convention
in v0.x, not a real sandbox** — mods execute in the same JS realm as the
Runtime and could technically reach `window`/`document`/`gl` if they
ignored the Agent Contract below. Do not describe this as a security
boundary in any user-facing text.

Capability list: `world.read`, `world.write`, `player.read`,
`player.modify`, `entity.read`, `entity.spawn`, `entity.modify`, `ui`,
`storage`, `audio`, `input`, `network` (**default-closed**, not granted in
v0.1 regardless of declaration — no networking surface exists).

The scoped `api` object handed to a mod's `setup(api)` only exposes methods
whose required permission is declared; calling an undeclared-permission
method throws `PERMISSION_DENIED` with a structured error. As of Phase
8.5, enforcement is live for `world.*`, `player.*`, `entity.*`, `ui`,
`storage`, and `input` — `storage` was briefly a documented-but-unenforced
gap between Phase 7 and Phase 8.5's metadata drift audit, which caught
and fixed it (see `MIGRATION_NOTES.md` 008). **`audio` and `network` are
declarable but currently have no
live enforcement effect**: `api.audio.play/stop` throw `NOT_IMPLEMENTED`
regardless of whether `audio` is declared (there is no real audio
capability to gate yet), and there is no `api.network` surface at all.
Declare them anyway if your mod's *intent* needs them — it costs nothing
and documents intent for a human/future-agent reviewer, but don't expect
either to unlock functionality yet. `events`/`blocks`/`items`/`time`/
`effects` are intentionally ungated — none require a declared permission,
treated as core/inert capabilities (subscribing to an event, registering
a definition, scheduling a timer, or flashing the screen aren't
data-access or persistence operations).

## Mod lifecycle states

`discovered -> validated -> loaded -> enabled -> disabled -> unloaded`, or
`failed` at any validation/setup/start step. A failure at any stage never
crashes the Runtime or other mods — it's caught, logged as a structured
error, and that mod stays in `failed`. **`.vmod` import (Phase 8) maps
onto this as**: `discovered` = source acquired (file read), `validated`
= manifest/apiVersion/dependencies/conflicts checked and passed but
`setup()` has not run yet, `loaded`/`enabled` = `setup()`/`start()` ran
successfully, `unloaded` = `ModHost.unload()` was called. There is no
`disabled` state reachable in v0.1 — see § `.vmod` Import below for why
a reversible toggle is not offered.

## `.vmod` Import

A `.vmod` file is imported through a strict pipeline, not by simply
executing it as if it were a trusted `<script>`:

```
source text
  -> capture (collect the defineVoxelMod(...) call WITHOUT running setup/start)
  -> validate (manifest, apiVersion, dependencies, conflicts)
  -> activate (build the scoped api, run setup()/start())
```

**Capture** executes the source with a *local* `defineVoxelMod`
collector that shadows the real registration function — inside the
executed source, `defineVoxelMod({...})` resolves to the collector, not
to Runtime activation. This is what makes "validated before activated" a
real guarantee: a captured definition's `setup()` cannot run until the
Runtime has explicitly decided to activate it. Capture fails with
`VMOD_SYNTAX_ERROR` (the source doesn't parse), `VMOD_EXECUTION_ERROR`
(the source throws before ever calling `defineVoxelMod`),
`VMOD_NO_DEFINITION` (0 calls captured), or `VMOD_MULTIPLE_DEFINITIONS`
(more than 1 — neither activates).

**Capture is a lifecycle mechanism, not a sandbox.** The source still
executes in the Runtime's real JS realm during capture, exactly as it
would during activation — every statement other than the
`defineVoxelMod` call itself runs normally, with normal access to
`window`/`document`/`fetch` if the source chooses to ignore the Agent
Contract. Do not describe `.vmod` import as sandboxed, isolated, or
security-reviewed in any UI copy, prompt text, or documentation. Runtime
0.1's trust model for imported mods is identical to its trust model for
any other mod: same-realm, declared-trust permissions, Agent Contract as
convention.

**Re-importing a mod whose earlier instance registered persistent
definitions** (`blocks.register`/`items.register`/`entities.registerType`
— see § Namespaces) fails during activation with
`DUPLICATE_DEFINITION_ON_REIMPORT`, a human-readable error explaining
that the Runtime session must be reloaded (definitions are never undone
by `unload()` — this is the same limitation § Namespaces already
describes, surfaced with better wording at the import boundary instead
of a bare `DUPLICATE_ID`).

**No reversible enable/disable toggle exists**, and none should be built
without first extending v0.1's definition-permanence semantics — a
toggle that silently fails to truly re-enable a definition-owning mod
would be a worse experience than an honest "unload for this session,
reload the page to re-import" label.

## VMP Prompt structure

`runtime.vmp.generatePrompt(userRequest)` builds a prompt for any Coding
Agent, in these sections, in order:

```
[VMP SYSTEM CONTRACT]
[VMP RUNTIME CAPABILITIES]
[VMP API SPEC]
[VMP EVENTS]
[INSTALLED MODS]
[USER REQUEST]
[OUTPUT CONTRACT]
```

1. **System Contract** — Runtime/API/VMP versions, the hard rules (no
   DOM/WebGL/window/document, no raw timers/localStorage, string ids
   only, exactly one `defineVoxelMod` call), the same-realm trust-model
   statement, the manifest-id → resource-namespace derivation rule with a
   worked example (see § Namespace derivation below), a copy-pasteable
   `defineVoxelMod({...setup(api){...}})` lifecycle skeleton, the
   `entities.registerType({tick})` three-argument signature and
   nested-`entity.position` mutation rule, and the exact `blocks.register`
   texture key set. The last four (skeleton, tick signature, position
   nesting, texture keys) were added as RC fixes after the agent benchmark
   found each one independently guessed wrong by multiple unrelated
   agents when only described in prose — see `RC_AGENT_BENCHMARK.md`.
2. **Runtime Capabilities** — every permission with a one-line
   description, generated from `CAPABILITY_META`; `audio`/`network` are
   explicitly marked as declarable-but-not-yet-enforced rather than
   silently included as if fully live.
3. **API Spec** — every `Stable`/`Experimental` method, generated from
   `PUBLIC_API_META` (namespace/method/signature/permission/description),
   never hand-duplicated prose. A compact name-only `UNAVAILABLE /
   PLANNED` list follows so an Agent knows what NOT to call without
   those entries being presented as usable.
4. **Events** — every `Stable`/`Experimental` event, generated from
   `PUBLIC_EVENT_META` (name/payload/cancelable/description). Added as
   its own section (not folded into API Spec) because exact payload
   shapes are easy to get wrong from prose alone and Agents need them
   verbatim.
5. **Installed Mods** — generated from live `ModHost` state
   (id/version/name only — never full source; a future "Revise this
   mod" feature may attach one mod's source selectively, not built here).
6. **User Request** — the player's natural-language description,
   inserted verbatim, never rewritten or reinterpreted by the Runtime.
7. **Output Contract** — plain JS source only, no markdown fence, no
   surrounding prose, exactly one `defineVoxelMod({...})` call, no
   imports, `apiVersion` must match, permissions must be exactly what's
   used, all resource ids namespaced, never a numeric id.

The Runtime is deliberately **agent-neutral** — this prompt template does
not assume or bind to any specific LLM provider.

### Namespace derivation

`manifest.id` uses dots/hyphens (`"author.mod-name"`); registrable
resource ids must be `namespace:id` with only `[a-z0-9_]` in the
namespace (`BlockRegistry`'s validation regex). The deterministic rule:
lowercase `manifest.id`, replace every run of non-alphanumeric
characters with a single `_`, then append `_` + a short deterministic
hash of the *original* (uncollapsed) `manifest.id`. Example: `manifest.id`
`"alice.magic-tools"` → resource namespace `"alice_magic_tools_tco85p"` →
resource id `"alice_magic_tools_tco85p:thing"`. The generated prompt
computes its worked example through this exact rule
(`deriveResourceNamespace()` in `index.html`), not a separately-typed
string, so the stated rule and the applied rule cannot drift from each
other.

**RC fix (Runtime 0.1 RC agent benchmark)**: the hash suffix was added
after the agent benchmark found that the earlier collapse-only rule was
lossy — `"alice.magic-tools"`, `"alice.magic_tools"`, `"alice.magic tools"`,
and `"alice.MAGIC-TOOLS"` are four different, individually valid manifest
ids that all collapsed to the identical namespace `"alice_magic_tools"`,
reproducibly causing a `DUPLICATE_ID` crash in a second, unrelated mod's
`setup()`. See `MIGRATION_NOTES.md` § RC and `RC_AGENT_BENCHMARK.md` for
the full repro and fix rationale.

## Agent Contract (hard rules for any Coding Agent generating a `.vmod`)

- Never reference `window`, `document`, `gl`, or any DOM/WebGL global —
  only `api.*`.
- Never call raw `setTimeout`/`setInterval`/`localStorage` — use
  `api.time`/`api.storage`.
- All registered ids (`blocks.register`, `items.register`,
  `entities.registerType`) must be namespaced `yourModId:thing`, never bare
  or `core:`.
- Declare every permission you actually use in `manifest.permissions`; do
  not request permissions you don't need.
- Do not assume Minecraft-specific concepts ("mobs", "crafting table",
  "redstone") unless the user request explicitly asks for that kind of
  mechanic — the API describes generic capabilities (world/player/
  entities/events/ui), not a fixed game genre.
- Do not hand-roll cleanup logic — resources created via `api.events.on`/
  `once`, `api.input.on`, `api.time.after`/`every`, `api.ui.setHudText`/
  `addPanel`, `api.entities.spawn` are all auto-cleaned by the host on
  unload (verified end-to-end, see `TEST_MATRIX.md` § Ownership
  destruction test). **Exception: `api.storage` is never cleaned on
  unload** — storage persists across your mod's own unload/reload cycle
  by design; use `api.storage.remove` yourself if you actually want to
  delete something.
- Avoid unbounded allocation or infinite loops inside `game.tick` handlers.
- Exactly one `defineVoxelMod` call per file; no top-level side effects
  outside it.

## Error Model

Never a bare `Uncaught TypeError`. Structured, machine-readable:

```json
{
  "protocol": "VMP/1",
  "mod": "example.magic",
  "phase": "validation",
  "errors": [
    {
      "code": "API_NOT_FOUND",
      "call": "api.world.explode",
      "suggestions": ["api.effects.explosion"]
    }
  ]
}
```

`phase` is one of `validate`, `setup`, `start`, `stop`, `unload` (ModHost
lifecycle boundaries), `runtime` (permission denials), `event` (a thrown
event listener — isolated per-listener, does not stop other listeners or
propagate to the code that called `emit`), `timer` (a thrown `api.time`
callback — isolated per-timer), `tick` (a thrown entity `tick` — isolated
per-entity), or `storage` (a read/write failure). Every one of these is
caught at its boundary and does not propagate — the Runtime, other mods,
and (for event/timer/tick) other listeners/timers/entities all keep
running. A human-readable rendering of the same error is also shown to
the player, via the Vibe Workshop's Errors tab / import-failure panel
(Phase 10, see `WORKSHOP_UX.md`), which additionally unwraps the root
cause of permission errors that arrive re-wrapped as `SETUP_EXCEPTION`/
`TIMER_EXCEPTION`/etc.

**"Copy Fix Prompt" is implemented** (Phase 10, `runtime.vmp.
generateFixPrompt(record, options)`): a `[VMP REPAIR TASK]` prompt
bundling `{current mod source (if retained), the structured runtime
error, relevant Runtime API/event metadata}` back into a prompt for the
Agent to repair, using the exact same metadata `generatePrompt` uses —
not a second template. Available in the Workshop wherever a failed
import's source was retained.

## Acceptance tests (Runtime 0.1 must support all five from docs alone)

An Agent given only `RUNTIME_API.md` + this file (no Runtime source) must
be able to produce:

- **A — Super Jump**: raises jump height. Tests `events` + `player`.
- **B — Lightning Grass**: stepping on grass has a chance to damage/flash.
  Tests `world` read + player events + `effects` + `player.damage`.
- **C — New Block**: registers a `crystal` block. Tests `blocks.register`
  + texture + inventory + placement.
- **D — Simple Enemy**: spawns a cube that chases the player. Tests
  `entities` + tick + player position + damage.
- **E — Non-Minecraft minigame**: 60-second "step on glowing target
  blocks for score." Tests `time`, `ui`, world mutation, score/game-state
  — the critical test that the API isn't secretly Minecraft-shaped.

**Status: all five passing as of Phase 7** (`dev.superjump`,
`dev.crystalblock`, `dev.chaser`, `dev.lightninggrass`, `dev.targetgame`
in `index.html`, all dev-gated behind `?mods=1`, none affecting default
boot). Each was reviewed against the same bar a real Coding Agent's
output would face: uses only documented public API, no internal numeric
ids, no DOM/WebGL/window/document, no undocumented behavior. Full
per-test API/permission/result table in `TEST_MATRIX.md`.

**Phase 9 added a sixth, stronger check**: a brand-new mod
(`demo.healthwatch` — periodic health banner + one-shot low-health
screen flash) was authored using *only* the text of a generated VMP
prompt, then imported through the real Phase 8 pipeline. The first draft
mis-declared permissions and was correctly rejected with a structured,
actionable error; the fix (declaring `ui`) was then imported successfully
and verified live. This is closer to the real target experience than
A-E alone: it tests the prompt, not just the API, and it tests the
error-recovery loop a real Agent/player pair will actually go through.
See `TEST_MATRIX.md` § Phase 9 verification.
