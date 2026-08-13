# Voxel Craft — Runtime Release Notes

```
Runtime 0.2.0-dev
API 1 — frozen
VMP 1 — frozen
Voxel Game Package Format 1 — frozen
Voxel Creation Workspace Format 1 — one additive field
Voxel Community Release Format 1 — one additive field
```

## Runtime 0.2.0-dev — Community Backend Foundation

Not yet declared stable — `RUNTIME_VERSION` remains `0.2.0-dev` for this
milestone; this is a checkpoint within the 0.2 development line, not a
0.2 release.

Community Releases can now be persisted to a real backend (Supabase) and
fetched back into the Runtime by anyone — while the Runtime itself still
never signs in, holds a session, or talks to the backend except through
explicit, anonymous, public reads.

- **New file: `community.html`** (the Community Portal) — a separate
  page that owns all Auth/identity: sign up, sign in, edit your public
  profile, upload and preview a `.vrelease` before publishing it, manage
  your published Releases (copy id, download, unpublish), and look up any
  public Release by id to see its metadata, direct parent, and direct
  remixes. It never executes Mod source — source is always shown as
  read-only text.
- **Runtime → Workshop → Export → "Open Community Release (remote)"**: a
  new field lets you fetch a public Release by its remote id directly
  from the backend — an anonymous, public read reusing the *exact same*
  preview/trust-notice/Open/Start Remix pipeline a local `.vrelease` file
  already used. No new Mod loader was added.
- **Security architecture**: the Runtime (`index.html`) never holds a
  Community Auth token — that lives only in `community.html`, which in a
  real deployment is meant to run on a separate origin from the Runtime.
  See `COMMUNITY_BACKEND_SPEC.md` for the full boundary and why it
  matters (Mods run as trusted, same-realm code — any token in that page
  would be reachable from Mod code).
- Server-side: Postgres RLS policies (verified with live two-account
  attack tests — cross-user unpublish/retitle/creator-forgery attempts
  all correctly blocked), an immutability trigger (a published Release's
  content can never be edited, only withdrawn), and a single atomic
  publish transaction that computes remix lineage (`generation`/parent)
  itself — a forged client-side `generation` value is silently ignored.
- Full English + Simplified Chinese support end-to-end, including a live
  zh-CN test pass of the entire sign-up → publish → fetch → remix →
  publish-child loop.
- See `COMMUNITY_BACKEND_SPEC.md` for the complete design, schema, RLS
  matrix, and acceptance-test results, and `COMMUNITY_BACKEND_SETUP.md`
  for deployment instructions.

## Runtime 0.2.0-dev — Creation Workspace & Provenance

A new authoring artifact, **`.vwork`** (Creation Workspace), lets you close
the browser and pick up your exact creative history later — every Mod
revision, every branch, every request you asked an Agent for — without
touching Package Format 1 or how a `.vgame`/baked game works.

- **Save Creation Workspace** / **Open Creation Workspace** (Workshop →
  Export tab): saves/restores the full revision history for every Mod in
  your session — not just the current playable state. Reopening a
  `.vwork` puts you right back where you left off: same Mods, same
  versions, same branches, Undo/Redo/Restore all working immediately.
- `.vwork` is a **separate format** (Workspace Format 1, its own version
  counter) from `.vgame` (Package Format 1, unchanged and frozen) —
  `.vgame`/baked standalone `.html` continue to contain only the current
  playable Mod sources, with zero authoring history, exactly as before.
  "Save Workspace" (creative history) and "Export Project"/"Bake" (the
  finished game) are deliberately distinct actions.
- **Fork Workspace** clones your current project's identity forward into a
  new one without touching the original; **Start Remix Workspace** lets
  someone who opened your `.vgame`/baked game begin their own creative
  history from what you shared, clearly labeled "Remix of ..." rather than
  claiming to know a lineage that plain Package Format 1 genuinely cannot
  carry.
- Full English + Simplified Chinese support, including a clear "unsaved
  changes" indicator and honest terminology throughout (Save Workspace vs.
  Export Project vs. Bake Standalone HTML are never blurred together).
- See `WORKSPACE_SPEC.md` for the complete format, restore semantics, and
  acceptance-test results.

## Runtime 0.2.0-dev — Revision History & Safe Undo

Every imported Mod now keeps a page-session **revision history**, starting
the instant it's first imported (Revision 1) — not only after its first
revision. No API 1/VMP 1/Package Format 1 change.

- **Undo Last Revision** and **Redo** transactionally swap between
  versions of a Mod — no page reload, no leftover listeners/timers/UI from
  whichever version isn't currently active.
- **Restore this version** works for *any* recorded revision, not just the
  immediately-previous one — routed through the exact same transactional
  engine as an ordinary revision, never a direct shortcut.
- **Revise from this version**: pick an older revision as the base for a
  brand-new Agent request, producing a **branch** — e.g. try two different
  directions from the same starting point without losing either. The
  Workshop and the generated Agent prompt both clearly disclose when a
  revision is based on an older version, so nothing pretends to merge
  changes that were never combined.
- Each Mod's History panel (Workshop → Mods tab) shows every retained
  revision — version, the original request text, and ancestry ("Based on
  Revision 2") — bounded to a reasonable page-session limit, not unlimited
  source control.
- `.vgame` exports and baked standalone `.html` still include only the
  *current* version of each Mod — revision history never leaks into
  Package Format 1 output.
- Full English + Simplified Chinese support, including a real Agent
  round-trip (revise → undo → branch from an older version) conducted
  entirely in Chinese.
- See `REVISION_HISTORY_SPEC.md` for the complete design, ancestry model,
  and acceptance-test results.

## Runtime 0.2.0-dev — Transactional Mod Revision

A Host-side infrastructure release: **replace an already-loaded Mod with a
revised version during the same session, without a page reload, with
automatic rollback if the replacement fails.** No API 1 change, no VMP 1
change, no Package Format 1 change — a `.vmod` written under Runtime 0.1
still imports unchanged, and nothing here is exposed as `api.*`.

- **Vibe Workshop → Mods tab → "Revise with Agent"** now drives a real
  transaction instead of a plain re-import: generates a revision-specific
  Agent prompt (current manifest + source + the change request, with a
  hard "keep manifest.id unchanged" requirement), then previews the
  replacement (version old → new, permission delta with new permissions
  highlighted) before anything is touched. Cancel leaves the old Mod
  completely untouched.
- The old, working Mod **always survives** a broken revision: a syntax
  error, an invalid manifest, or a `setup()` that throws is rejected before
  the old Mod is stopped, or (if it already had to be stopped to attempt
  the swap) the old Mod is automatically restored from its retained
  definition — its event subscriptions, timers, and UI come back exactly
  as they were.
- Blocks/entity types registered by the Mod being revised are replaced
  **in place** — a block already placed in the world keeps its internal
  numeric id and its existing world cells across the revision, so no world
  regeneration is ever needed to reload a Mod. A resource the new version
  no longer registers is tombstoned (hidden from future lookup/placement)
  rather than corrupting the world cells that still reference it.
- Repeated revisions of the same Mod (V1→V2→V3→...) leak nothing: no
  duplicate listeners, timers, UI, or Mods-tab rows accumulate.
- Exported `.vgame` projects and baked standalone `.html` games include
  only each Mod's *current* version — revision history never leaks into
  Package Format 1 output.
- Full English + Simplified Chinese support for every new Workshop surface
  this introduces.
- See `MOD_REVISION_SPEC.md` for the complete design, transaction
  lifecycle, and acceptance-test results.

## Runtime 0.1.1 — Internationalization & Simplified Chinese

A localization/product-quality release. No Mod API compatibility change, no
package compatibility change — a `.vmod`/`.vgame`/standalone `.html` made
under 0.1.0 still works unchanged under 0.1.1, and vice versa.

- All first-party Runtime UI (start/pause menu, HUD, hotbar, death screen,
  Vibe Workshop and all four tabs, permission preview, error explanations,
  Distribution/Export UI) is now internationalized, with complete **English
  (`en-US`)** and **Simplified Chinese (`zh-CN`)** translations shipped
  in-file — no build step, no external i18n library, no CDN, still
  `file://`-openable as a single HTML file.
- A language switcher (English / 简体中文) lives in the start/pause menu.
  Switching is immediate — no reload — and is remembered for next time
  (`localStorage`, key `voxel-runtime.locale`).
- Locale is chosen, in order: explicit `?lang=en-US`/`?lang=zh-CN` → saved
  preference → browser language → `en-US` default.
- A baked standalone game carries the same i18n system and language
  switcher as the Runtime it was baked from — a receiver can play in either
  language regardless of what language the creator baked it in.
- Protocol identifiers are never translated and never change meaning:
  `manifest.permissions` values (`world.read`, `ui`, `storage`, ...),
  structured error codes (`PERMISSION_DENIED`, `VMOD_SYNTAX_ERROR`, ...),
  resource ids (`core:grass`, ...), API method/event names, and VMP/1's
  section markers (`[VMP SYSTEM CONTRACT]`, `[USER REQUEST]`, ...) are
  identical byte-for-byte in every locale. Only human-facing display text
  is localized.
- See `I18N_SPEC.md` for the full locale/negotiation/fallback contract and
  translation-key conventions.

## What this is

A single-file, dependency-free voxel game (`index.html` — no Node, no npm,
no build step, no server, no account, no network) that doubles as an
**agent-programmable game runtime**. Anyone can describe a gameplay idea in
plain language, hand a generated prompt to any AI coding assistant, get back
a small JavaScript file (a "Mod"), drop it into the game, and play — all
without installing anything or touching the Runtime's own source.

Double-click `index.html`. That's the whole install.

## Main capabilities

- A survival voxel sandbox (mining, placing, procedural terrain, health,
  hotbar, day-to-day play) as the base game.
- A Mod API (`api.world`, `api.player`, `api.blocks`, `api.items`,
  `api.entities`, `api.events`, `api.time`, `api.ui`, `api.effects`,
  `api.storage`, `api.input`) that lets a Mod add new blocks, entities,
  timers, HUD elements, and event-driven behavior — enough to build
  everything from a simple ability (double jump) to a full minigame
  (a scored, timed, non-Minecraft-shaped challenge), without ever touching
  the DOM, WebGL, or Runtime internals directly.
- **Vibe Workshop** — an in-game panel (`VIBE WORKSHOP` button) with four
  tabs: **Create** (describe what you want, generate an Agent prompt,
  import the `.vmod` it produces), **Mods** (see what's active, unload,
  view source), **Export** (package your session into a shareable game),
  **Errors** (every failure a Mod hit, with a plain-language explanation
  and a one-click "Copy Fix Prompt" for handing back to an Agent).

## The four file types

- **`.vmod`** — one Mod. Plain JavaScript, one `defineVoxelMod({...})`
  call. The unit an AI Agent generates for you.
- **`.vgame`** — one editable Project. Plain JSON: a title/description/
  author, an ordered list of Mods (their full source, not compiled), and a
  few small settings. Meant to come back into Vibe Workshop later.
- **`.html`** — one finished, standalone Game. Your chosen Mods baked
  directly into a full copy of the Runtime. Send this single file to
  anyone; they double-click it and play — no Workshop, no setup, no
  dependency on the file it came from.
- **`.vwork`** — one Creation Workspace. Plain JSON, same as `.vgame`, but
  preserving your creative *history* instead of just the current playable
  state — every Mod revision, branch, and Agent request. Not a save game;
  a save for the creative process itself. See `WORKSPACE_SPEC.md`.

```
idea → Vibe Workshop → Agent prompt → .vmod → import → play
                                                   ↓
                                      Export tab → .vgame (editable)
                                                 → .html (standalone, shareable)
```

A received standalone `.html` (with Workshop included, the default) is
itself remixable: open it, add another Mod through its own Workshop, and
bake a new standalone file that contains everything — the original Mods
plus the new one. Share → remix → re-share.

## API 1 / VMP 1

**API 1** is the frozen contract every Mod is written against —
`api.world`/`api.player`/`api.blocks`/`api.entities`/`api.events`/
`api.time`/`api.ui`/`api.effects`/`api.storage`/`api.input`, plus a small
permission system (`manifest.permissions`) gating which of those a given
Mod can call. Full reference: `RUNTIME_API.md`.

**VMP 1** (Vibe Mod Protocol) is the prompt format Vibe Workshop generates
for an AI Agent — system rules, the full API surface, event payloads, a
literal code skeleton, and the player's request, all assembled from the
same metadata the Runtime itself enforces, so the prompt can never drift
from what actually works. Full reference: `VMP_SPEC.md`.

Both are frozen: no Stable method is renamed or has its behavior changed,
no VMP output-contract shape changes, without a version bump and an
explicit compatibility decision. This is what makes a `.vmod` written today
still work in `index.html` tomorrow.

## Trust model

**Mods execute as trusted, same-page JavaScript. There is no sandbox.**
`manifest.permissions` is a declarative gate — it controls which `api.*`
methods a Mod's code can successfully call, and the Workshop shows a
permission preview before you load an unfamiliar Mod — but it is not
isolation. A Mod you import (or receive embedded in someone else's
exported game) runs with the same access to the page as the Runtime
itself. Only import `.vmod`/`.vgame`/`.html` files from people you trust,
the same as you would any other executable.

## Known limitations

- **No sandbox** (see Trust model above) — the single biggest thing to
  understand before importing someone else's Mod or game.
- **Definitions aren't rolled back on unload.** Unloading a Mod removes its
  timers/UI/entities/event subscriptions, but a block or entity *type* it
  registered stays reserved for the rest of the page session.
- **Full mesh rebuild per block placed/broken.** Fine for normal play;
  a Mod that mutates the world in a tight loop will visibly stutter.
- **No package signing.** A `.vgame` or exported `.html` carries no
  cryptographic verification — trust is based on who sent it to you, not
  a badge in the file.
- **No network, multiplayer, or audio API.** Out of scope for 0.1.
- **`startImmediately`** (a `.vgame`/package setting) is recorded but
  intentionally not acted on — Runtime 0.1 never auto-starts gameplay,
  since that would require Pointer Lock without a real click, which
  browsers refuse to grant.
- **`file://` storage** (`api.storage`) is scoped by the browser's own
  `file://` origin rules, not the Runtime — two different exported games
  opened locally may or may not share storage, depending on your browser.

## Where to go next

- `RUNTIME_API.md` — the full `api.*` reference.
- `VMP_SPEC.md` — the exact prompt format Vibe Workshop generates.
- `MOD_REVISION_SPEC.md` — transactional Mod revision: ownership,
  Registry replacement, rollback, and the Workshop revision UX.
- `REVISION_HISTORY_SPEC.md` — the revision DAG, Undo/Redo/Restore, and
  branching ("Revise from this version").
- `WORKSPACE_SPEC.md` — `.vwork` Creation Workspace format, identity,
  provenance, and fork/remix semantics.
- `COMMUNITY_RELEASE_SPEC.md` — the local `.vrelease` format and publish/
  open/remix UX.
- `COMMUNITY_BACKEND_SPEC.md` / `COMMUNITY_BACKEND_SETUP.md` — the
  Supabase-backed Community backend: schema, RLS, the Community Portal,
  the Runtime's anonymous remote client, and deployment instructions.
- `I18N_SPEC.md` — locale negotiation, fallback, translation-key
  conventions, and the Runtime-UI/Mod-content localization boundary.
- `DISTRIBUTION_SPEC.md` — how `.vgame`/standalone `.html` packaging works.
- `RUNTIME_ARCHITECTURE.md` / `MIGRATION_NOTES.md` — internal design and
  full phase-by-phase history, for anyone extending the Runtime itself.
- `RELEASE_FIXTURES/` — example Mods, a demo project, a golden standalone
  game, and error-case fixtures, for reference or regression testing.
