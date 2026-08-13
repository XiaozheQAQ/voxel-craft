# DISTRIBUTION_SPEC.md — Runtime 0.1 Distribution

Source of truth for the "Runtime 0.1 Distribution" milestone: turning a
Workshop session full of Mods into a shareable, standalone `.html` game,
plus an editable `.vgame` project format. This milestone does not touch
API 1 or VMP 1, which are frozen (see `RC_AGENT_BENCHMARK.md` and
`MIGRATION_NOTES.md` § RC). Nothing here is exposed through `api.*` —
Mods cannot bake or export the Runtime; this is Workshop/Runtime
infrastructure only.

## 1. Concepts and terms

```
.vmod   — one gameplay/content Mod (source text of a defineVoxelMod call)
.vgame  — one configured, editable Project: metadata + zero or more Mods
.html   — a baked, standalone, directly-playable Game (Runtime + Project, one file)
```

A `.vgame` project and a baked `.html` game share the exact same payload
shape — a **Game Package** — they differ only in *how* that payload is
delivered (a plain JSON file vs. base64-embedded inside a Runtime HTML
shell).

## 2. Game Package format

```js
{
  format: "voxel-game",
  formatVersion: 1,            // GAME_PACKAGE_FORMAT_VERSION — independent of Runtime/API/VMP versions
  runtimeVersion: "0.1.0",
  apiVersion: 1,
  vmpVersion: 1,
  createdAt: "2026-08-12T12:34:56.000Z",
  meta: { title: "Crystal Defense", description: "...", author: "" },
  mods: [
    { manifest: {...}, source: "defineVoxelMod(...)" },
    ...
  ],
  settings: { includeWorkshop: true, includeDebugTools: false, startImmediately: false }
}
```

- `mods[].source` is the **only** source of truth for a Mod inside a
  package — never a serialized function, closure, entity, or timer. This
  mirrors an `ImportRecord`'s retained source exactly. Loading a package
  (embedded at boot, or via `.vgame` import) always re-enters the
  ordinary `ImportManager.importSource()` path — capture → validate →
  activate — never a second special loader.
- `mods` order is deterministic: it comes out of a small topological
  sort by `manifest.dependencies` (same shape `ModHost.validate()`
  already checks — an object whose keys are required mod ids), with
  ties preserved in original array order. Not a package-manager
  resolver. A cycle throws `DEPENDENCY_CYCLE`.
- `settings` is deliberately small: `includeWorkshop`,
  `includeDebugTools` (reserved, currently always `false` from Bake —
  no debug-tool surface exists to include yet), `startImmediately`
  (reserved — recorded but not currently acted on, since auto-clicking
  "Play" would require pointer lock, which browsers only grant on a
  real user gesture; documented as a known limitation, not silently
  faked). Gameplay rules belong in Mods, never in package settings.
- `GAME_PACKAGE_FORMAT_VERSION = 1`, tracked independently of
  `RUNTIME_VERSION`/`API_VERSION`/`VMP_VERSION`. A package records all
  four so compatibility can be checked precisely instead of guessed.

## 3. Bake architecture — the "clean template" problem

The hardest design problem in this milestone: the whole Runtime is one
`index.html`. Baking a new standalone file needs a **clean** copy of
that shell to splice a payload into — but the live, running document has
already been mutated by the time a player clicks "Bake" (HUD text,
hearts, hotbar, `#workshopOverlay`'s entire DOM tree, open modals, death
screen classes, and so on are all created or written by this same script
after boot).

**Solution actually implemented**: capture
`document.documentElement.outerHTML` as the literal **first statement**
in the script, before any other line of code has touched the DOM:

```js
(function(){
"use strict";
let __pristineDocumentHTML = null;
try { __pristineDocumentHTML = document.documentElement.outerHTML; } catch(e){ __pristineDocumentHTML = null; }
```

This sidesteps the "must sanitize live DOM state" problem entirely
instead of solving it: since nothing has run yet, `#hearts`/`#hotbar`
are still their authored empty `<div>`s, `#workshopOverlay` doesn't
exist yet (it's created later, by `WorkshopController`), and
`#posText`/`#fpsText` still hold their static placeholder text. There is
no DOM sanitization step anywhere in Bake, because the sanitization
problem never arises.

This same mechanism also solves "avoid nested duplication on re-bake"
(re-baking an already-baked standalone game) for free: whatever document
was actually loaded — whether that's the plain Runtime or a previously
baked game — is captured fresh, pre-mutation, at *this* boot. Its
`#voxel-game-package` container holds exactly one payload slot to
overwrite, never an accumulating stack of them. Verified directly (not
just reasoned about) — see § 9.

Bake itself is a string splice, not a DOM operation:

```js
function bakeStandaloneHTML(pkg){
  const marker = /(<script type="application\/x-voxel-game" id="voxel-game-package">)([\s\S]*?)(<\/script>)/;
  const payload = utf8ToBase64(JSON.stringify(pkg));
  const html = '<!DOCTYPE html>\n' + __pristineDocumentHTML.replace(marker, (m, open, _old, close) => open + payload + close);
  return new Blob([html], {type:'text/html'});
}
```

## 4. Embedded Mod container and escaping

The static shell has one inert, non-executing container, present (empty)
in the plain Runtime:

```html
<script type="application/x-voxel-game" id="voxel-game-package"></script>
```

`type="application/x-voxel-game"` is not a recognized script MIME type,
so the browser never parses its contents as JS regardless of what's
inside — this is what makes it a safe **data** container, not a code
container.

**Escaping strategy**: the entire JSON payload (Mod source, titles,
descriptions — everything) is base64-encoded before being placed inside
that container. Base64's alphabet is `[A-Za-z0-9+/=]`, which cannot spell
a closing script tag, an HTML comment delimiter, a quote, a backtick, or
any other HTML/JS-significant sequence — so there is no per-character
escaping logic to get right, and nothing to get wrong. `JSON.stringify()`
alone was deliberately **not** used as the encoding (per the milestone's
explicit instruction) — it does not protect against a Mod's source
containing a literal `</script>` sequence, which would prematurely
terminate the container in the browser's HTML tokenizer regardless of
that sequence being "inside a JS string" from JSON's point of view. Base64
sidesteps that class of bug entirely instead of pattern-matching it.

UTF-8 correctness (emoji, non-Latin text) is handled by encoding through
`TextEncoder`/`TextDecoder` rather than the naive `btoa`/`atob` (which
only handle Latin-1):

```js
function utf8ToBase64(str){
  const bytes = new TextEncoder().encode(str);
  let binary = '';
  for(let i=0;i<bytes.length;i+=0x8000) binary += String.fromCharCode.apply(null, bytes.subarray(i, i+0x8000));
  return btoa(binary);
}
```

**A cautionary note for future editors of this file**: while writing this
milestone's own explanatory comments, a literal `</script>` sequence
pasted into a *JS comment* (not a string) broke the page at load —
the HTML tokenizer that finds the end of the real `<script>` element
runs before JS parsing even begins, so it does not care that the
sequence is "just a comment." Never paste a literal closing-script-tag
sequence anywhere in this file, even in prose explaining why not to.
**This exact mistake recurred once during Release Hardening**, in a
*different* comment written specifically to warn about it — proof this
is an easy trap to fall back into, not a one-time slip. Caught the same
way both times: the browser console shows a `SyntaxError` referencing
the wrong line/token, because the HTML tokenizer silently truncated the
script element and everything after the accidental `</script>` became
inert page text. If a syntax error appears with no correspondingly
obvious JS mistake, grep the file for a stray closing-script-tag
sequence before assuming the bug is anywhere else.

**Identifying comment (Release Hardening addition)**: baked HTML gets a
short, human-readable HTML comment near the top (title, Runtime/API/VMP/
Package-Format versions) so an opened file is identifiable at a glance
in a text editor. Because the title is untrusted (§ above already proved
titles can contain arbitrary HTML-significant text), and an HTML comment
terminates at the **first** `--`, not just `-->`, every value
interpolated into that comment is passed through a small
`commentSafe()` helper that replaces `--` runs with a lookalike Unicode
hyphen before insertion — verified live with a title containing both
`-->` and an embedded `<script>alert(1)</script>`: zero script tags
resulted from parsing the comment, `alert(1)` never appeared unescaped
in the parsed body.

## 5. Export rules — which Mods are included

Only Mods that are **both**: (a) currently `active` per `ModHost`, and
(b) have retained `source` text in their `ImportRecord`, are eligible.
Concretely, from Workshop's Export tab:

```js
function eligibleExportMods(){
  return runtime.mods.listImports().filter(r => runtime.modHost.isActive(r.id) && typeof r.source === 'string');
}
```

This means, by construction:
- `?mods=1` dev acceptance Mods are **never** eligible — they're
  registered directly via `defineVoxelMod()`, never through
  `ImportManager`, so they never produce an `ImportRecord` at all.
  Verified live: with `?mods=1`, `runtime.mods.listImports().length`
  is `0` even though 5 Mods are active.
- Failed imports are never eligible (not active).
- Unloaded Mods are never eligible (not active).
- A ghost definition left behind by an unloaded-then-forgotten Mod
  (Runtime 0.1's known "definitions aren't rolled back on unload"
  limitation) can never leak into a package, because Bake reads from
  `ImportManager`'s *declarative* retained records, never from live
  `BlockRegistry`/`EntityTypeRegistry` state. A Mod that isn't
  explicitly selected contributes nothing to the package, full stop,
  regardless of what it left behind in the Registry.

## 6. Dependency handling

At Bake time, `buildGamePackage()` fails fast (throws
`PACKAGE_DEPENDENCY_MISSING`) if any selected Mod declares a dependency
not also selected — the Export tab additionally shows this issue
proactively in the UI, before the button is even clicked, so the author
sees it while still choosing Mods rather than after a failed export.

At load time (embedded package boot, or `.vgame` import), Mods are
activated in the order produced by `topoSortGamePackageMods()` — small,
deterministic, ties preserve package order, no external resolver.

## 7. Two export formats

**`.vgame`** (Project export) — the Game Package JSON, plain and
readable, written with `JSON.stringify(pkg, null, 2)`. No base64, no
escaping concerns — it's its own file, not embedded inside another
document. Meant to come back into a Workshop session.

**`.html`** (Bake Standalone HTML) — the pristine document snapshot
with the package spliced into the inert container (§ 3-4). Directly
playable via `file://`, no install, no server, no build step.

Both share `buildGamePackage()` to construct the payload; only the final
encoding step differs.

## 8. Boot sequence for an embedded package

```
Runtime boot (world/UI/render loop — unchanged from Runtime 0.1)
↓
requestAnimationFrame(loop) starts
↓
loadEmbeddedGamePackage()
  ├─ read #voxel-game-package (empty → return, ordinary Runtime boot)
  ├─ base64-decode + JSON.parse + validate format/formatVersion/apiVersion/mod shape
  │    └─ any failure here: VmpErrorLog.report(...), return — Runtime still boots normally
  ├─ set document.title from meta.title, set runtime.distribution.currentPackage
  ├─ topological sort by dependencies (cycle → logged, falls back to package order)
  ├─ for each Mod: ImportManager.importSource(source, {filename}) — same path a real
  │    .vmod upload takes. One Mod's failure is isolated to its own ImportRecord and
  │    logged; it does not stop the remaining Mods or blank the page (§ 12).
  └─ if settings.includeWorkshop === false: hide the Workshop entry point
```

Placed after world generation/spawn/hotbar/hearts setup (same timing a
`?mods=1` dev Mod gets), so a Mod's `setup()` can safely call
`api.world.getBounds()` / `api.player.getPosition()` etc.

No permission-preview confirmation step is shown for embedded Mods —
they were already selected and trusted by the package's own creator
(§ 13); the permission-preview UI exists for *newly* imported Mods, not
Mods a game's own author already chose to ship.

## 9. Verified: no nested duplication on re-bake

Directly tested, not just reasoned about (Acceptance Test C, § below):
opened a baked 2-Mod game, imported a 3rd Mod through its own Workshop,
then re-baked. The result was parsed with a real `DOMParser` (not naive
substring counting, which is misled by the fact that the bake code's own
regex-literal source text contains the fragment `id="voxel-game-package"`
too) and confirmed to have exactly **one** `#voxel-game-package`
container, **two** `<script>` elements total, and a payload that decodes
to exactly the 3 intended Mods — not a wrapped copy of the previous
2-Mod payload, not a doubled script count.

## 10. `.vgame` project import

Runtime 0.1 chooses correctness over convenience (per the milestone's
explicit instruction): `.vgame` import is only supported into a session
with **no currently-active imported Mods**. A dirty session is rejected
with `PACKAGE_SESSION_NOT_CLEAN` and a message telling the player to
reload the Runtime first, rather than attempting a partial or silently
wrong in-place project switch. No project hot-reload/reset
infrastructure was built.

## 11. Error handling / survivability

Every package-related failure mode produces a structured, logged error
(`VmpErrorLog` entries with codes like `PACKAGE_FORMAT_INVALID`,
`PACKAGE_FORMAT_VERSION_MISMATCH`, `PACKAGE_API_VERSION_MISMATCH`,
`PACKAGE_MODS_INVALID`, `PACKAGE_MOD_SHAPE_INVALID`,
`PACKAGE_PARSE_ERROR`, `PACKAGE_DEPENDENCY_MISSING`,
`PACKAGE_DEPENDENCY_CYCLE`/`DEPENDENCY_CYCLE`,
`PACKAGE_MOD_NOT_ELIGIBLE`, `PACKAGE_SESSION_NOT_CLEAN`,
`BAKE_NO_TEMPLATE`, `BAKE_NO_CONTAINER`) instead of an uncaught
exception. A corrupted embedded package (invalid base64, invalid JSON,
wrong shape) never blanks the page — the Runtime boots fully and
normally, logs the error, and simply has zero Mods active. A single bad
Mod inside an otherwise-valid package is isolated to its own
`ImportRecord`/error entry and does not stop sibling Mods from loading.
Both are directly verified, not assumed — see § below.

## 12. Trust model (unchanged, restated for Distribution)

Embedded Mods run in the same JS realm as the Runtime, exactly like any
other Mod — packaging does not add or remove any sandboxing (there is
none, by design, documented since Phase 5). A baked standalone file is
effectively an application containing whatever Mods its creator chose to
embed. No repeated permission dialog is shown per boot for already-
embedded Mods; the permission-preview UI remains available on demand
(View Source / the Mods tab) for a receiver who wants to inspect what
they're running.

## 13. Filename sanitization

A separate, smaller function from `deriveResourceNamespace` (which
exists to avoid resource-id collisions and therefore appends a
disambiguating hash — see `MIGRATION_NOTES.md` § RC). A filename has no
collision-avoidance requirement, so `sanitizeFilename()` just lowercases,
collapses non-alphanumeric runs to `-`, and trims — `"Crystal Defense"` →
`"crystal-defense.html"` / `"crystal-defense.vgame"`.

## 14. Known limitations

- **Same-realm trust model.** Restated from above: Mods (embedded or
  not) are not sandboxed. This was true before Distribution and remains
  true after.
- **Definition hot-reload / ghost definitions.** Unloading a Mod does
  not roll back its registered blocks/entity types (pre-existing Runtime
  0.1 limitation). Distribution does not fix this, but does guarantee
  (§ 5) that it can never silently leak into an exported package.
- **Full mesh rebuild per `world.setBlock`.** Unchanged; a baked game
  inherits the same performance characteristics as the Runtime it was
  baked from.
- **No package signing / integrity verification.** Not implemented, not
  claimed. A `.vgame` or baked `.html` is exactly as trustworthy as the
  person who sent it to you — no cryptographic signature, no "verified"
  badge. Explicitly out of scope per the milestone instructions.
- **No network/community features.** No marketplace, no server, no
  accounts, no cloud sync, no remote Mod repository. Out of scope per
  the milestone's explicit stop condition.
- **`file://` storage caveat.** `api.storage` (per-Mod `localStorage`)
  is scoped per-origin by the browser; two different baked `.html` files
  opened via `file://` on the same machine may or may not share storage
  depending on the browser's `file://` origin policy. Not a Distribution
  regression — this is inherited from Runtime 0.1's existing
  `api.storage`, unrelated to packaging.
- **`startImmediately` setting: formally Reserved — ignored by Runtime
  0.1** (resolved during Release Hardening). Auto-starting gameplay
  would require acquiring pointer lock without a user gesture, which
  browsers do not grant, or inventing a new packaged-game UI screen,
  which is new gameplay/UI surface out of scope for a hardening pass.
  The key is still written by `buildGamePackage` (so a hand-authored or
  future package can set it without a format-version bump) and is never
  read by `loadEmbeddedGamePackage` — both facts are stated explicitly
  in code comments at both sites, not left silent.
- **Testing-methodology note** (not a product limitation): real file
  downloads in the automated test environment used for this milestone's
  acceptance tests were observed to be deleted from disk immediately
  after completing (very likely local security/AV software flagging a
  large base64-embedded HTML file heuristically). Acceptance tests
  therefore verified the baked output by parsing it with a real
  `DOMParser` for structural correctness, then loading it via a
  same-session `blob:` URL (a fresh document/script re-execution, just
  not literally through a `file://` double-click). The Bake code path
  itself does not know or care how its `Blob` reaches the user; the
  `<a download>` mechanism (§ Export UI) is standard browser API, and a
  manual sanity check (an early single-mod bake) *did* momentarily
  reach the real filesystem as `super-jump-test-a.html` before removal,
  confirming the download path itself functions correctly.
