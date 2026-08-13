# Runtime API

Public API source of truth for Voxel Runtime. Mods must only use methods
documented here (`PUBLIC API`). Anything not listed — `gl`, WebGL buffers,
shader programs, the raw `world` `Uint8Array`, internal `yaw`/`pitch`
variables, the DOM — is `RUNTIME INTERNALS` and mods must never touch it.

Runtime: `0.1.0` · API: `1` · VMP: `1`

**Runtime 0.1 external-contract freeze candidate** (end of Phase 7,
reconfirmed end of Phase 9): every method below marked Stable or
Experimental is implemented, browser-verified, and safe for a Coding
Agent to target from this document alone — no undocumented behavior, no
numeric-id leakage, no cleanup promise the Runtime doesn't keep. See
`MIGRATION_NOTES.md` 007A/007B for what changed to make that true.

**As of Phase 8.5, this document's method tables are kept in sync against
`PUBLIC_API_META`/`PUBLIC_EVENT_META`** (plain data arrays inside
`index.html`, see `RUNTIME_ARCHITECTURE.md` § VMP/1 prompt generation) —
the same data Phase 9's `runtime.vmp.generatePrompt()` reads. That audit
(`?dev=1`) caught a real drift on its first run: `api.storage` was
documented as gated below but wasn't actually enforced in code. It is
now. If you ever find this document and `PUBLIC_API_META` disagreeing,
trust neither blindly — check `ModHost`'s `PERMISSION_MAP` in
`index.html`, which is the actual enforcement source.

**`.vmod` import (Phase 8), VMP prompt generation (Phase 9), and the Vibe
Workshop UI (Phase 10) are Runtime-level infrastructure, not part of this
api surface** — `runtime.mods`/`runtime.vmp` are deliberately not
`api.mods`/`api.vmp`; a mod has no legitimate reason to import other mods
or generate prompts about itself. `runtime.mods` gained `beginImport`/
`confirmImport` in Phase 10 (capture+validate, then a separate activate
step — what the Workshop's permission-preview screen calls) alongside the
original auto-activating `importSource`/`importFile`. `runtime.vmp`
gained `generateFixPrompt(record, options)` in Phase 10 (a `[VMP REPAIR
TASK]` prompt for a failed import, built from the same metadata
`generatePrompt` uses). See `RUNTIME_ARCHITECTURE.md` and `WORKSHOP_UX.md`
for their design.

Status legend: **Stable** (implemented, verified, safe to build on —
signature unlikely to change before 1.0) · **Experimental** (implemented
and verified, but shape may still change before 1.0) · **Planned** (does
not exist — calling it throws structured `NOT_IMPLEMENTED`, or the method
is simply absent from the scoped `api` object; never fakes behavior) ·
**Internal** (listed only to explicitly mark it off-limits to mods).

All permission-gated methods throw structured `PERMISSION_DENIED` (see §
Errors) if the mod's `manifest.permissions` doesn't declare the required
capability — this happens *inside* the method call, not at registration
time, so a mod can still register even if `setup()` would later fail on
a specific call.

---

## api.game

| Method | Signature | Permission | Status |
|---|---|---|---|
| `game.getVersion()` | `() -> {runtime, api, vmp}` (all strings/numbers) | none | Stable |
| `game.getState()` | `() -> 'running'\|'dead'` | none | Stable |
| `game.pause()` / `game.resume()` | — | — | **Planned** (not implemented — no pause state exists) |
| `game.registerMinigame(def)` | — | — | **Planned, and will likely stay that way** — deliberately not built; see `MIGRATION_NOTES.md` 007B Part B8. Minigames (Test E) are built from `time`/`ui`/`world`/`events` primitives, not a genre-specific API. |

## api.events

| Method | Signature | Permission | Status |
|---|---|---|---|
| `events.on(name, fn)` | `(string, fn(payload)) -> unsubscribe` | none | Stable |
| `events.once(name, fn)` | `(string, fn(payload)) -> unsubscribe` | none | Stable |
| `events.off(unsubscribe)` | `(unsubscribe) -> void` | none | Stable |
| `events.emit(name, payload)` | — | — | **Planned** — not implemented; mods cannot emit custom events yet |

**Error isolation**: a listener that throws is caught, reported as a
structured `EVENT_HANDLER_EXCEPTION` (attributed to your mod), and does
NOT stop other listeners on the same event or propagate anywhere. For
cancelable `.before` events, a throwing listener is treated as
non-cancelling (the operation still proceeds unless a different listener
calls `.cancel()`).

**Core events actually emitted today**:

| Event | Payload | Cancelable | Fires from |
|---|---|---|---|
| `game.tick` | `{dt}` (reused object — copy fields you need, don't hold the reference) | no | `loop()`, every frame, unconditionally |
| `player.jump` | `{}` | no | `updatePhysics()`, on jump input while grounded |
| `player.damage` | `{amount, health}` | no | `applyDamage()` |
| `player.death` | `{}` | no | `die()` |
| `player.respawn` | `{}` | no | `die()`'s respawn timeout |
| `player.step` | `{x, y, z, block}` (`block` is a string id) | no | `updatePhysics()`, once per ground-cell change (not per frame) |
| `block.break.before` | `{x, y, z, block}` (string id) | **yes** | `updateMining()`, before a mined block is removed |
| `block.break` | `{x, y, z, block}` (string id) | no | `updateMining()`, after removal |
| `block.place.before` | `{x, y, z, block}` (string id) | **yes** | `tryPlace()`, before a block is placed |
| `block.place` | `{x, y, z, block}` (string id) | no | `tryPlace()`, after placement |
| `entity.spawn` | `{id, type}` | no | `entities.spawn()` |
| `entity.death` | `{id}` | no | `entities.remove()` |

**Documented but NOT yet emitted** (Planned — listed here so a mod author
knows not to rely on them): `runtime.ready`, `player.spawn`,
`player.move`, `block.interact`, `item.use`, `entity.damage`,
`entity.interact`, `world.generate`.

## api.world

Numeric internally, **string ids at this boundary** — see
`RUNTIME_ARCHITECTURE.md` § The internal/public identity boundary.

| Method | Signature | Permission | Status |
|---|---|---|---|
| `world.getBlock(x,y,z)` | `(int,int,int) -> stringId` | `world.read` | Stable |
| `world.setBlock(x,y,z,stringId)` | `(int,int,int,string) -> void`, throws `UNKNOWN_BLOCK_ID` if `stringId` isn't registered | `world.write` | Stable |
| `world.isSolid(x,y,z)` | `(int,int,int) -> bool` | `world.read` | Stable |
| `world.getHeight(x,z)` | `(int,int) -> number` (surface height; the walkable block is at `y = getHeight(x,z)-1`) | `world.read` | Stable |
| `world.getBounds()` | `() -> {w,d,h}` | `world.read` | Stable |
| `world.regenerate(seed?)` | `(number?) -> void` — regenerates the whole world + moves the player to the new spawn | `world.write` | Experimental |
| `world.raycast(origin,dir,maxDist)` | `([x,y,z],[x,y,z],number) -> {hit:[x,y,z], place:[x,y,z]}\|null` | `world.read` | Stable |

**Known limitation**: `world.setBlock` triggers a full world remesh every
call (no dirty-chunk tracking). Call it sparingly in a tight loop —
`dev.targetgame`'s target-relocation (a couple of calls per player action,
not per frame) is a reasonable usage pattern.

```js
// place a previously-registered custom block 3 cells in front of spawn
const p = api.player.getPosition();
api.world.setBlock(Math.floor(p.x)+3, Math.floor(p.y), Math.floor(p.z), 'example:crystal');
```

## api.player

| Method | Signature | Permission | Status |
|---|---|---|---|
| `player.getPosition()` | `() -> {x,y,z}` | `player.read` | Stable |
| `player.setPosition(x,y,z)` | `(number,number,number) -> void` | `player.modify` | Stable |
| `player.getVelocity()` | `() -> {x:0, y, z:0}` — x/z are always 0; physics derives horizontal movement from input each frame, there is no persistent x/z velocity to read | `player.read` | Experimental |
| `player.setVelocityY(v)` | `(number) -> void` | `player.modify` | Stable |
| `player.getLookDirection()` | `() -> {yaw, pitch}` (radians) | `player.read` | Stable |
| `player.setLook(yaw,pitch)` | `(number,number) -> void` | `player.modify` | Stable |
| `player.isGrounded()` | `() -> bool` | `player.read` | Stable |
| `player.getHealth()` / `getMaxHealth()` | `() -> number` | `player.read` | Stable |
| `player.damage(amount, source?)` | `(number, any?) -> void` — `source` is accepted but currently unused internally | `player.modify` | Stable |
| `player.heal(amount)` | `(number) -> void`, clamped to max health | `player.modify` | Stable |
| `player.respawn()` | `() -> void` — resets position to spawn and velocity; does NOT reset health (use `heal` separately if desired) | `player.modify` | Experimental |
| `player.getInventory()` | `() -> {stringId: count}` | `player.read` | Stable |
| `player.giveItem(stringId, count)` | `(string, number) -> void`, throws `UNKNOWN_BLOCK_ID` for an unregistered id | `player.modify` | Stable |
| `player.takeItem(stringId, count)` | `(string, number) -> void`, clamps at 0, throws `UNKNOWN_BLOCK_ID` for an unregistered id | `player.modify` | Stable |

```js
api.events.on('player.jump', () => {
  const v = api.player.getVelocity();
  api.player.setVelocityY(v.y + 8); // Super Jump
});
```

## api.blocks

| Method | Signature | Permission | Status |
|---|---|---|---|
| `blocks.register(def)` | `({id, name?, hardness?, textures?, solid?}) -> stringId` | none | Stable |
| `blocks.get(stringId)` | `(string) -> {id,name,solid,hardness,tiles,numericId}\|undefined` | none | Stable |
| `blocks.list()` | `() -> stringId[]` | none | Stable |

`def.id` must be `namespace:id` and not under the `core:` namespace
(throws `PROTECTED_NAMESPACE`/`INVALID_NAMESPACE`/`DUPLICATE_ID` as
appropriate). `def.textures` accepts hex color strings only —
`{color:'#9d6bff'}` for one color on every face, or
`{top,bottom,side}` for per-face colors — procedurally painted with the
same solid+speckle style core blocks use (no image assets, no
build step). `def.hardness` defaults to `0.5` seconds to mine if omitted.
`def.solid` is stored but **not honored by physics** (see
`RUNTIME_ARCHITECTURE.md` § Known Limitations) — a `solid:false` block
still blocks movement today.

**Registration is permanent for the page session** — there is no
`unregister`. Registering the same id twice (including after your own
mod was unloaded and reloaded) throws `DUPLICATE_ID`. See
`RUNTIME_ARCHITECTURE.md` § Definition registration vs. runtime instances.

```js
api.blocks.register({ id:'example:crystal', name:'Crystal', hardness:0.9, textures:{color:'#9d6bff'} });
```

## api.items

| Method | Signature | Permission | Status |
|---|---|---|---|
| `items.register(def)` | same shape as `blocks.register` | none | Stable — **alias of `blocks.register`**, no separate item identity in v0.1 |
| `items.get(stringId)` | same as `blocks.get` | none | Stable — alias |

## api.entities

Lightweight data-driven store, not a full ECS — see
`RUNTIME_ARCHITECTURE.md` § Module graph.

| Method | Signature | Permission | Status |
|---|---|---|---|
| `entities.registerType(def)` | `({id, model?, defaults?, tick?}) -> stringId` | none | Stable |
| `entities.spawn(typeId, opts)` | `(string, {x?,y?,z?}) -> entityId` (string, e.g. `'e7'`), throws `UNKNOWN_ENTITY_TYPE` if `typeId` isn't registered | `entity.spawn` | Stable |
| `entities.get(entityId)` | `(string) -> entity\|undefined` — returns a **copy**, mutating it does nothing | `entity.read` | Stable |
| `entities.query(filter?)` | `(fn(entity)->bool | undefined) -> entity[]` — copies | `entity.read` | Stable |
| `entities.remove(entityId)` | `(string) -> bool` (whether it existed) | `entity.modify` | Stable |
| `entities.setState(entityId, patch)` | `(string, object) -> bool` — shallow-merges into `entity.state` | `entity.modify` | Stable |

`def.model`: `{type:'box', size:[w,h,d], color:'#hex'}` — one mesh per
*type*, shared by every instance (box geometry only in v0.1). `def.tick`:
`(entity, ctx, dt) -> void`, called every `game.tick` for every live
instance of that type. Inside `tick`, `entity` is the **live** object
(you may mutate `entity.position/velocity/rotation/health/tags/state`
directly — this is the one place outside `setState`/`spawn` where entity
state mutation is allowed, because it's the Runtime calling your
function, not you calling the Runtime). `ctx.player`/`ctx.world` are the
same facades your `setup(api)` received. An entity object shape:
`{id, type, position:{x,y,z}, velocity:{x,y,z}, rotation, health, tags:[], state:{}}`.
Exceptions thrown inside `tick` are caught per-entity, reported
(attributed to the mod that called `registerType`), and do not stop
other entities from ticking.

**Definitions are permanent for the page session**, same as blocks — see
`RUNTIME_ARCHITECTURE.md` § Definition registration vs. runtime instances.
Spawned *instances* ARE cleaned up automatically when your mod unloads.

```js
api.entities.registerType({
  id: 'example:chaser',
  model: { type:'box', size:[0.8,0.8,0.8], color:'#e6483f' },
  defaults: { health: 6, state: {hitCooldown: 0} },
  tick(entity, ctx, dt){
    const p = ctx.player.getPosition();
    // ...move entity.position toward p, mutate entity.state.hitCooldown, call ctx.player.damage(...)
  }
});
api.entities.spawn('example:chaser', {x:10, y:20, z:10});
```

## api.ui

Text-only — no HTML is ever accepted, so there is no injection surface
and no framework to learn. Duplicate ids **update the existing element in
place** (not an error).

| Method | Signature | Permission | Status |
|---|---|---|---|
| `ui.setHudText(id, text)` | `(string, string) -> id` — creates or updates one HUD line | `ui` | Stable |
| `ui.removeHudText(id)` | `(string) -> void` | `ui` | Stable |
| `ui.showToast(text, opts?)` | `(string, {ms?:number}?) -> void` — ephemeral, self-dismissing, default 2000ms | `ui` | Stable |
| `ui.showBanner(text, ms?)` | `(string, number?) -> void` — large centered ephemeral text, default 2500ms | `ui` | Stable |
| `ui.addPanel(id, opts)` | `(string, {text?:string, title?:string, x?:number, y?:number}) -> id` | `ui` | Stable |
| `ui.removePanel(id)` | `(string) -> void` | `ui` | Stable |

All HUD text/panels your mod creates are automatically removed when your
mod unloads. Toasts/banners are self-cleaning (internal timer) and are
not individually tracked.

```js
api.ui.setHudText('myMod:score', 'Score: ' + score);
api.ui.showToast('+1!', {ms:600});
```

## api.effects

| Method | Signature | Permission | Status |
|---|---|---|---|
| `effects.flashScreen(colorHex, ms?)` | `(string, number?) -> void`, default 250ms | none | Stable |
| `effects.shake(amount, ms)` | — | — | **Planned** — not implemented, absent from the scoped api |
| `effects.particleBurst(x,y,z,opts)` | — | — | **Planned** — no particle system exists |
| `effects.explosion(...)` | — | — | **Planned** — not implemented |

Uses its own screen-covering element, independent of the built-in damage
hit-flash — a mod's flash and the base game's own red damage flash never
fight over shared state.

## api.audio

| Method | Signature | Permission | Status |
|---|---|---|---|
| `audio.play(id, opts?)` | present on the scoped api, **throws structured `NOT_IMPLEMENTED`** when called | none | **Planned** |
| `audio.stop(id)` | same | none | **Planned** |

The game has zero audio pipeline. These are intentionally NOT silent
no-ops — calling either throws `{code:'NOT_IMPLEMENTED', status:'Planned'}`
so a Coding Agent gets an explicit signal instead of writing code that
looks like it works but produces no sound.

## api.storage

| Method | Signature | Permission | Status |
|---|---|---|---|
| `storage.get(key, defaultValue?)` | `(string, any?) -> any` — JSON-deserialized | `storage` | Stable |
| `storage.set(key, value)` | `(string, any) -> bool` — JSON-serialized; `false` on failure | `storage` | Stable |
| `storage.remove(key)` | `(string) -> bool` | `storage` | Stable |

Namespaced `vmp1:<your-manifest-id>:<key>` over `localStorage` — Mod A
cannot read Mod B's keys through this API. Values must be
JSON-serializable. Read/write failures (quota exceeded, storage
disabled, non-serializable value) are caught, reported as structured
errors, and return a safe fallback (`defaultValue` for `get`, `false`
for `set`/`remove`) — never thrown into your code, never crash the
Runtime. **`ModHost.unload` does NOT delete your storage** — unloading a
mod means its subscriptions/timers/UI/entities are cleaned up, not that
its saved data disappears; reload the same mod id later and your data is
still there. Known caveat: some browsers scope/share `localStorage`
oddly under `file://` rather than strictly per-origin; the namespace
prefix prevents cross-mod collisions regardless, but full cross-page
isolation under `file://` isn't guaranteed by any browser.

## api.time

Runtime-owned scheduler — do not use raw `setTimeout`/`setInterval`.

| Method | Signature | Permission | Status |
|---|---|---|---|
| `time.after(ms, fn)` | `(number, fn) -> handle` — fires once | none | Stable |
| `time.every(ms, fn)` | `(number, fn) -> handle` — fires repeatedly | none | Stable |
| `time.cancel(handle)` | `(handle) -> void` — cancelling twice, or an already-fired `after` handle, is a harmless no-op | none | Stable |

**Clock semantics (read this before building a timer-based minigame)**:
`api.time` only advances while the game is in active play — pointer
locked and the player alive. It pauses while the pointer-lock menu is
open or the player is on the death screen, and resumes exactly where it
left off. This is deliberate: a countdown built on `api.time` cannot
silently drain while the player has stepped away from gameplay. All
timers your mod creates are canceled automatically when your mod unloads.
Exceptions inside a timer callback are caught, reported (attributed to
your mod), and do not stop the scheduler or any other timer.

```js
let timeLeft = 60;
api.time.every(1000, () => {
  timeLeft--;
  api.ui.setHudText('myMod:time', 'Time: ' + timeLeft + 's');
});
```

## api.input

| Method | Signature | Permission | Status |
|---|---|---|---|
| `input.isKeyDown(code)` | `(string) -> bool` — `code` is a `KeyboardEvent.code` value, e.g. `'KeyW'`, `'Space'` | `input` | Stable |
| `input.on(type, fn)` | `('keydown'\|'keyup', fn({code})) -> unsubscribe` | `input` | Stable |

The payload passed to your `input.on` listener is always exactly
`{code}` — a plain object, never the raw browser `KeyboardEvent`.
Subscriptions are cleaned up automatically on mod unload.

---

## Errors

All API errors are structured (see `VMP_SPEC.md` § Error Model) — never a
bare `Uncaught TypeError`, and never silently swallowed. Two shapes exist:

**Thrown, synchronously, from the call that caused it** (registry
mistakes, permission denial, bad ids) — an `Error` with `{code, id/message,
...extra}` attached:

```js
try {
  api.world.setBlock(x,y,z, 'not:registered');
} catch(e) {
  e.code; // 'UNKNOWN_BLOCK_ID'
}
```

Codes you may see thrown directly: `DUPLICATE_ID`, `INVALID_NAMESPACE`,
`PROTECTED_NAMESPACE`, `INVALID_DEF`, `UNKNOWN_BLOCK_ID`,
`UNKNOWN_ENTITY_TYPE`, `PERMISSION_DENIED`, `NOT_IMPLEMENTED`,
`INVALID_INPUT_EVENT`.

**Reported, not thrown** (failures inside a callback boundary the
Runtime itself invokes — `setup`/`start`/`stop`/`unload`, event
listeners, timer callbacks, entity `tick`) — logged via the shared
structured error log (`ModHost.getErrors()`), console-logged, and never
allowed to crash the Runtime or affect other mods:

```json
{
  "protocol": "VMP/1",
  "mod": "example.magic",
  "phase": "setup",
  "errors": [{ "code": "SETUP_EXCEPTION", "message": "..." }]
}
```

Phases you may see: `validate`, `setup`, `start`, `stop`, `unload`,
`runtime` (permission denials), `event` (listener exceptions), `timer`
(timer callback exceptions), `tick` (entity tick exceptions), `storage`
(read/write failures).
