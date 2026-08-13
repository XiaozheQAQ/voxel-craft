# Workshop UX

Source of truth for **Vibe Workshop** UI behavior and lifecycle decisions —
the player-facing layer built in Phase 10. `RUNTIME_ARCHITECTURE.md` remains
the source of truth for the Runtime internals (`ModHost`, `runtime.mods`,
`runtime.vmp`, `EventBus`, etc.) the Workshop consumes; this file only
covers the UI's own behavior, state, and the product-language rules that
apply to anything shown to a player.

## What the Workshop is (and isn't)

The Workshop is a **pure consumer** of the existing Runtime pipeline. It
contains zero prompt-generation logic, zero validation logic, zero
permission-checking logic — every one of those is a direct call into
`runtime.vmp.generatePrompt`, `runtime.mods.beginImport/confirmImport`,
`ModHost.unload`, or `ModHost.getErrors()`. If the Workshop's behavior
and `RUNTIME_API.md`/`VMP_SPEC.md` ever disagree, the bug is in how the
Workshop is reading Runtime state, not a second implementation to
reconcile — there isn't one.

`WorkshopController` (`index.html`, `/* === Vibe Workshop === */` section,
placed after the Input wiring block, before Render loop) is a single
closure holding UI-only state: which tab is active, the in-progress
request text, the last generated prompt, a pending (validated-but-not-
activated) `ImportRecord`, the most recent result record, and which mod
(if any) is being revised. None of this state is Runtime state — closing
and reopening the Workshop does not lose it (it lives for the page
session), but none of it is queryable by `ModHost`/`ImportManager` either.

## Entry point and pointer-lock behavior

A "Vibe Workshop" button lives in the existing start/pause overlay
(`#overlay`, next to "Click to Play" / "New World") — the same panel
shown any time the pointer isn't locked, so it's always reachable without
occupying permanent gameplay screen space.

Opening the Workshop calls `document.exitPointerLock()` if the pointer is
currently locked. This is not a new pause mechanism — it's the exact same
state transition pressing Esc already causes, so the existing
`pointerlockchange` handler (which shows `#overlay` and clears
`mouseDown`) runs unchanged. **Consequence, not a new rule**: since
`timeScheduler` (Phase 7's `api.time`) only advances while
`locked && !isDead`, opening the Workshop pauses every mod's timers via
a mechanism that already existed before Phase 10 — there was no need to
add a second pause model, and none was added. Closing the Workshop does
not re-lock the pointer automatically; the player clicks "Click to Play"
like any other menu dismissal.

## Permission preview (Option A implemented)

Per the Phase 10 brief, permission preview-before-activation was
**implemented**, not deferred — it required zero `ModHost` rework because
`validate()`/`activate()` were already split apart in Phase 8.
`ImportManager` gained two new primitives that expose that existing split
to the UI:

- `runtime.mods.beginImport(source, metadata)` — capture + validate only.
  Returns an `ImportRecord` with `status:'validated'` (ready to preview)
  or `status:'failed'` (capture/validation error, nothing to preview).
- `runtime.mods.confirmImport(recordId)` — activates a `'validated'`
  record. Returns the same record, now `status:'active'` or
  `status:'failed'`.

`importSource`/`importFile` (Phase 8's originals, still used by the dev
file-picker control and Phase 8's own test suite) are now thin wrappers:
`beginImport` immediately followed by `confirmImport` if validation
passed — unchanged auto-activating behavior, zero risk to anything
already verified.

The Workshop's Create tab always uses the two-step path: a chosen/dropped
file goes through `beginImport`; if `status === 'validated'`, a
permission-preview card renders (`manifest.name` + every declared
permission with its one-line description, sourced from `CAPABILITY_META`)
with **Cancel** (discards the pending record, nothing was ever activated
— verified: `ModHost.isActive(id)` is `false` for a cancelled pending
import) and **Load Mod** (`confirmImport`). If `beginImport` itself
failed (bad syntax, zero/multiple definitions, bad manifest, wrong
`apiVersion`, missing dependency), the error panel renders immediately
with no preview step, since there's nothing valid to preview.

## Mod management semantics

**"Unload for this session" is the only mutating operation Workshop
offers on an active mod.** It calls `ModHost.unload(modId)` after a
confirmation dialog (styled consistently with the rest of the Workshop,
not `window.confirm()`) that states plainly, in the same words `unload`
actually guarantees:

> Its active events, timers, UI and spawned entities will be removed.
> Persistent mod storage is kept.
> Some registered definitions (blocks/entity types) remain reserved
> until the Runtime is reloaded.

**There is no enable/disable toggle**, and this is a deliberate product
decision, not a missing feature. Runtime 0.1 (Phase 6.5, Part A5)
permanently reserves any block/item/entity-type id a mod registers —
`unload()` never undoes a registration. A toggle implies "off now, on
again later, safely" — for a mod that registered persistent definitions,
re-activating it after unload does not safely re-run `setup()` (it hits
`DUPLICATE_DEFINITION_ON_REIMPORT`, verified in RC audit testing). Building
a toggle would mean lying to the player about what "disable" and
"re-enable" actually do. The honest operation is `Unload for this
session`, and re-importing the same source later either works (if the
mod registered no persistent definitions) or fails with a clear,
actionable error explaining that a page reload is needed — it never
silently corrupts state or pretends to succeed.

**Mods tab status derivation** (`ImportManager.liveStatus(record)`):
`'active'` if `ModHost.isActive(record.id)`, else `'failed'` if the
record's own import never succeeded, else `'unloaded'` (it was active at
some point, isn't now). This is computed fresh on every render — the
Workshop does not cache or duplicate `ModHost`'s live/not-live state.
Built-in mods (loaded via `?mods=1` or a manual `<script>`, with no
`ImportRecord` at all) are listed too, sourced straight from
`ModHost.listDetailed()`, shown with filename `(built-in)` and no
"View Source" button (there is no retained source to show).

## Error UX

Every failure (`beginImport`, `confirmImport`, or a later runtime error
surfaced via `ModHost.getErrors()`) renders through one shared
`renderErrorPanel`/`humanizeError` pair — human-readable sentence first,
a collapsed `<details>` "Technical details" block (the raw structured
`{mod, phase, errors}` JSON) second, per the brief's explicit ordering.

**Root-cause unwrapping**: a `PERMISSION_DENIED` thrown inside `setup()`
(or a timer/entity-tick callback) arrives at the error log re-wrapped as
`SETUP_EXCEPTION`/`TIMER_EXCEPTION`/etc. — the outer code says "something
threw," but the actual reason is embedded in the exception's message text
(`"[Registry] PERMISSION_DENIED: api.ui.showBanner"`). `humanizeError`
extracts this via `extractPermissionRootCause()` and looks up which
permission that specific call needs from `PUBLIC_API_META`, so the
displayed sentence is concrete: *"workshop.brokentest tried to use
api.ui.showBanner, which needs permission "ui", not declared in its
manifest."* — not a bare error code. Verified live during Phase 10
testing (§ `TEST_MATRIX.md`).

**Copy Error** copies the structured `{mod, errors}` JSON.
**Copy Fix Prompt** (present only when the failed record retained
`source` — i.e. it went through `captureDefinition` at all) calls
`runtime.vmp.generateFixPrompt(record, {userRequest})`, a `[VMP REPAIR
TASK]` prompt built from the same retained source + the same
`PUBLIC_API_META`/`PUBLIC_EVENT_META`/`CAPABILITY_META` `generatePrompt`
uses — not a second template. This existed cleanly enough in the
Phase 8/9 architecture that it was implemented rather than deferred (the
brief's Part 17 allowed either).

## Revision workflow

"Revise with Agent" (shown on every *active* mod card, built-in or
imported) does exactly three things: switches to the Create tab, sets a
`revisingModId` flag (rendered as a notice banner with the mod id and the
persistent-definition warning), and clears any previously generated
prompt so the player writes a fresh "what should change" description.
It does **not** attach the mod's source to the next generated prompt,
pre-fill the textarea from a remembered original request (Workshop does
not currently associate a request with a specific `ImportRecord` — see
Post-0.1 below), hot-reload anything, or silently touch `ModHost` state.
The next "Generate Agent Prompt" click produces a normal prompt whose
`[INSTALLED MODS]` section reflects live `ModHost` state exactly like any
other generation — since the mod being revised is still active, it
appears there like any installed mod, giving the Agent real context
without the Workshop inventing any.

## Product language

User-facing text says `Vibe Workshop`, `Mod`, `Prompt`, `Permissions`,
`Load`, `Play`, `Unload`, `Error`. It never says `ModHost`,
`PUBLIC_API_META`, `EventBus`, `captureDefinition`, `Uint8Array`, or
`numeric id` — those stay inside the collapsed "Technical details" JSON
dump, where a curious/technical player or a copy-pasted bug report can
still find them, but the primary reading path never requires understanding
them. The product is described as "Voxel Runtime" / "Agent-programmable
game runtime" / "Create gameplay with your Coding Agent" — never
"Minecraft mod loader" or similar.

## Trust-model wording (verbatim, appears twice)

> Runtime 0.1 mods run in the same page as the game. Only import .vmod
> files you trust.

and, next to the permission list specifically:

> Permissions describe intended Runtime API access. They are not a
> security sandbox.

Audited (`MIGRATION_NOTES.md`, RC audit): no user-facing string anywhere
in `index.html` claims mods are sandboxed, secure, or isolated.

## Post-0.1 (explicitly deferred, not built)

- **Copy Fix Prompt was built**; a "Revise with Agent" flow that
  auto-attaches the mod's retained source to the regenerated prompt was
  **not** — Revise only regenerates a prompt with fresh `[INSTALLED
  MODS]` context, it does not bundle source. A future version could merge
  these two (effectively "Revise" becomes "generate a repair-style prompt
  for this specific mod, pre-filled with what changed"), but that wasn't
  built here to keep the two actions' behavior easy to reason about
  independently.
- **Associating a remembered user request with a specific `ImportRecord`**
  across a page session (so re-opening Workshop later and clicking
  "Revise" on an old import shows what was originally asked for) — not
  built. Today, `requestText` is a single shared field for the whole
  Create tab, not per-mod.
- **Drag/drop was built** (not deferred) — it reuses the identical
  `beginImport` call the file-picker path uses, no separate validation.
- **Bake to standalone HTML, community publishing, LLM provider
  integration, a real sandbox, full hot-reload, multiplayer/cloud
  storage** — all explicitly out of scope for Runtime 0.1, per the
  Phase 10 brief. Not started, not designed here.

## Distribution milestone — Export tab (built after the above)

A 4th tab, `EXPORT`, added alongside Create/Mods/Errors. Title/
description/author fields, an "Include Vibe Workshop in exported game"
checkbox (default on), a checkbox list of eligible Mods (default: all
selected), a proactive dependency-issue warning shown before either
button is clicked (not just as a failure after), and two buttons —
"Export Project (.vgame)" and "Bake Standalone HTML" — each downloading
via a `Blob` + temporary `<a download>` click, with a size readout
(`formatBytes`) in the success message. An "Import Project (.vgame)"
section below it reuses the same drop-zone/file-picker visual pattern as
`.vmod` import for consistency, with its own preview-then-confirm step
(title/description/mod list) before committing, mirroring the
permission-preview pattern from `.vmod` import — except here the
"Cancel"/"Load Project" choice previews package contents rather than
permissions, since embedded/project Mods don't get a second permission
prompt (see `DISTRIBUTION_SPEC.md` § 12).

**Not built**: no drag-reorder for Mod inclusion order (order is
whatever `topoSortGamePackageMods` produces — deterministic, not
manually adjustable); no partial/hot project-switch UI (a dirty session
is simply told to reload, per `DISTRIBUTION_SPEC.md` § 10) — chosen
deliberately over building reset infrastructure just for this.

## Release Hardening pass

The raw dev `.vmod` file-picker input (predates Vibe Workshop, kept
around for quick manual testing) was found shipping ungated on every
default boot — visible to real players even though the Export/Create
tabs fully supersede it. Moved behind `?dev=1`. No other Workshop UX
changes this round; the Export tab UI built during Distribution was
re-verified working end-to-end (genuine `file://` bake-and-reopen, not
just Blob-level) rather than redesigned.

## Runtime 0.2.0-dev — Revision UX

"Revise with Agent" (Mods tab) now drives a real transaction. It switches
the Create tab into revision mode: "Generate Agent Prompt" builds a
revision-specific prompt (current manifest + source + the change request,
hard-locking `manifest.id`); dropping a `.vmod` no longer goes straight to
the ordinary permission-preview-then-load path, it shows a **Replace Mod**
preview instead — Mod name, `oldVersion → newVersion`, and the full
permission list with `+`/`−` markers for anything added/removed relative
to the currently-active version, plus a "New permissions requested" notice
when applicable. Only `[Cancel]` / `[Replace Mod]` proceeds; Cancel leaves
the old Mod running untouched and stays in revision mode. A successful
replace shows a real (post-commit, never speculative) Reused/Added/Removed
resource summary; a failed one shows a distinct banner for what happened to
the *old* Mod (never touched / restored / restore also failed) above the
existing generic error panel — reusing "Copy Error"/"Copy Fix Prompt"
unchanged. A revision is always folded into the target Mod's one existing
Mods-tab row; it never becomes a second row, successful or not. Full
design: `MOD_REVISION_SPEC.md`.

## Runtime 0.2.0-dev — Revision History UX

Each Mod card (with retained source) gains a **History** button, toggling
an inline panel: every recorded revision, newest first, labeled by
creation-order sequence ("Revision N," never ancestry depth — two branches
off the same parent must not collide) with its manifest version, relative
time, the original revision request text if any, and "Based on Revision N"
ancestry. The current entry is marked "● ... · Current"; every other entry
offers **View Source** (read-only, same modal as a live Mod's), **Restore
this version**, and **Revise from this version**. Panel-level **Undo Last
Revision**/**Redo** buttons are disabled (not hidden) when unavailable.
"Revise from this version" on an entry that is not the current head
carries a "based on an older version, later changes will not automatically
be included" notice through both the Create-tab notice/Replace-Mod preview
*and* the generated Agent prompt itself (`[BASE VERSION NOTICE]`). Every
Restore/Undo/Redo runs through the same transactional engine as an
ordinary revision — no direct Registry mutation from this UI. Full design:
`REVISION_HISTORY_SPEC.md`.

## Runtime 0.2.0-dev — Creation Workspace UX

Export tab gains a **Creation Workspace (.vwork)** section, clearly
separated from — and explicitly explained relative to — Export Project
(.vgame)/Bake Standalone HTML directly above it: "Preserves your creative
history — all Mod revisions, branches, and requests. For the current
playable game alone, use Export Project (.vgame) or Bake Standalone HTML
below." **Save Creation Workspace** builds and downloads a `.vwork`;
**Open Creation Workspace** offers the same drop-zone → preview →
`[Cancel]`/`[Load Project]` pattern as `.vgame` import. When a Workspace
identity exists, a compact info card shows its title, Original/Remix
provenance ("Original Creation" / `Remix of "<title>"`), an "Unsaved
changes" indicator when dirty, and a **Fork Workspace** button. When the
session was opened from a plain `.vgame`/baked game with no Workspace
lineage, a **Start Remix Workspace** button appears instead, establishing
one. Terminology is deliberately explicit throughout (spec § 34 — Save
Workspace / Export Project / Bake Standalone HTML are three distinct
verbs for three distinct things, never blurred). Full design:
`WORKSPACE_SPEC.md`.

## Runtime 0.2.0-dev — Community Foundation (Publish/Open Release) UX

Export tab gains a **Publish Snapshot** section: Tags/Language/Release
note inputs, a live preview (title, author, description, current Mods,
language, tags, parent/remix attribution, release note, and always —
never buried — "Revision history: Not included."), then
`[Publish Snapshot]` downloads a `.vrelease`. **Open Release** mirrors the
existing `.vgame`/`.vwork` drop-zone → preview → `[Cancel]`/`[Open
Release]` pattern; once open, a **Start Remix** button begins a brand-new
Creation Workspace with correct release provenance. Opening a Release
never auto-imports it as a private Workspace. Terminology stays strict:
Mod Branch / Workspace Fork / Release Remix are three different actions
with three different buttons, never blurred into a single "fork." Full
design: `COMMUNITY_RELEASE_SPEC.md`.

## Runtime 0.2 — Community Backend Foundation UX

Directly below the existing local Open Release drop-zone, a new **"Open
Community Release (remote)"** card: a single text field for a remote
Release id plus a `[Fetch]` button. Fetch performs one anonymous,
public read (`runtime.community.getRelease`) and — on success — feeds
the fetched Release into the **exact same** preview card /
`[Cancel]`/`[Open Release]` confirmation / trust-notice / Start Remix
flow the local drop-zone already uses (`communityPendingImport`). There
is no separate "remote release" preview UI, and no auto-execution —
fetching only ever populates a preview; opening it is still a distinct,
explicit click. On failure (not found, withdrawn, network error,
backend not configured), the existing Export-tab feedback line shows a
localized message via the same structured-error-code → i18n-key
convention every other error surface in this Runtime uses. This is the
Runtime's *only* new UI surface this milestone — everything else
(Auth, publish, manage releases) lives in the separate `community.html`
Portal, never in the Workshop. Full design:
`COMMUNITY_BACKEND_SPEC.md`.

## Runtime 0.2 — Community Discovery handoff UX

The "Open Community Release (remote)" field above now has a second entry
point: opening `index.html` itself with `?communityRelease=<uuid>` in
the URL. This is how `community.html`'s Explore/Release-detail
"Open in Runtime"/"Remix" buttons hand a Release off to the Runtime. On
load, the Workshop auto-opens to the Export tab and the id field is
pre-filled and auto-fetched — the player sees the exact same preview
card / trust notice / `[Cancel]`/`[Open Release]` confirmation as a
manual fetch, with zero Mods active until they explicitly click "Open
Release." No new Community Portal UI was added to the Workshop itself —
the Portal (browsing, search, filters, Release/profile pages) is a
separate application entirely; this Runtime only ever receives a bare
Release id. Full design: `COMMUNITY_DISCOVERY_SPEC.md`.
