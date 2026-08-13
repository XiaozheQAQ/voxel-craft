# Voxel Craft — I18N_SPEC.md (Runtime 0.1.1)

```
Runtime 0.1.1
API 1 — frozen, unaffected
VMP 1 — frozen, unaffected
Voxel Game Package Format 1 — frozen, unaffected
```

This document is the source of truth for how localization works in the
Runtime. It does not duplicate the translation catalog itself — that lives
in `index.html` as `I18N_MESSAGES`, and that array is the source of truth
for actual strings.

## Supported locales

- `en-US` (default/fallback)
- `zh-CN` (Simplified Chinese)

Both are shipped in-file, inside `I18N_MESSAGES` in `index.html`. There is
no external locale file, no build step, no CDN — the whole Runtime,
including every translation, is still one `file://`-openable HTML document.

## Locale negotiation

Resolved once at boot, in this order, by `runtime.i18n`'s internal
`detect()`:

1. Explicit `?lang=en-US` / `?lang=zh-CN` query parameter.
2. Saved preference (`localStorage["voxel-runtime.locale"]`).
3. `navigator.languages` / `navigator.language`, first entry that maps to a
   supported locale.
4. `en-US`.

Negotiation is deliberately lightweight, not full BCP-47: only the language
subtag is inspected. `en`, `en-GB`, `en-AU`, etc. all fold to `en-US`.
`zh`, `zh-CN`, `zh-SG`, `zh-Hans`, `zh-Hans-CN`, `zh-TW`, `zh-HK`, etc. all
fold to `zh-CN` — Runtime 0.1.1 ships one Chinese locale, so there is no
Traditional-vs-Simplified distinction to preserve yet. An unrecognized
`?lang=` value (e.g. `?lang=xx-INVALID`) is silently ignored and negotiation
falls through to the next step — it never breaks boot.

## Fallback behavior

Looking up a key (`runtime.i18n.t(key, params?)`):

```
current locale's table
    ↓ (key missing)
en-US table
    ↓ (key missing from en-US too — should not happen in a released build)
"[missing: <key>]"
```

In `?dev=1` mode, a missing-key fallback also logs one `console.warn` per
unique `(locale, key)` pair the first time it's hit (no repeat spam).
Normal (non-dev) mode never logs for this — a released build should never
have a real gap, and if a mistake ships, players should still see readable
(English-fallback) text, not console noise.

## Translation key conventions

- Flat, hierarchical, stable keys: `common.*`, `menu.*`, `game.*`, `hud.*`,
  `workshop.*` (further split `workshop.create.*`, `workshop.mods.*`,
  `workshop.errors.*`, `workshop.export.*`), `permissions.*`, `errors.*`,
  `status.*`, `distribution.*`, `blocks.*`, `vmp.*`.
- The key is never the English source text itself (`t("common.close")`,
  not `t("Close")`) — this is what lets `en-US` wording change later
  without touching call sites, and is what the completeness audit (below)
  actually checks membership against.
- `en-US` and `zh-CN` must have identical key sets. Enforced by the dev-only
  completeness audit, not by any build-time check (there is no build step).

## Interpolation

Minimal named interpolation only — `{name}` placeholders, replaced from a
plain params object:

```js
t('errors.permissionDenied.withoutCall', {mod: 'demo.magic'})
```

No ICU MessageFormat, no plural rules, no gender rules. Not needed for this
Runtime's UI surface; if a future locale needs real pluralization, that is
a deliberate scope decision to make then, not something silently bolted on.

## Runtime UI scope (what gets localized)

Every first-party, player-facing string reachable from `index.html`'s own
DOM/JS: start/pause overlay, HUD (`pos`/`fps`/Esc hint), hotbar labels,
health/death screen, Vibe Workshop (all four tabs, permission preview,
import results, modals, toasts), permission descriptions, structured-error
explanations, status labels (Active/Failed/Unloaded/...), and the
Distribution/Export UI (Game title/Description/Author/Included Mods/Export
Project/Bake Standalone HTML/Import Project, and their feedback/validation
messages).

## Mod-content boundary (what does NOT get localized)

Runtime 0.1.1 localizes **first-party Runtime UI only**. It does not, and
architecturally cannot, machine-translate Mod-authored content:

- `api.ui.showBanner(text)`, `api.ui.setHudText(id, text)`,
  `api.ui.showToast(text)`, `api.ui.addPanel(id, {text})` — the `text` a
  Mod passes is author-controlled, verbatim, in whatever language the Mod
  author (or the Coding Agent that wrote the Mod) wrote it in.
- The `?mods=1` dev acceptance Mods (Super Jump, Crystal Block, Chaser,
  Lightning Grass, Target Game) are themselves examples of Mod-authored
  content and are deliberately left in their original English — translating
  them would misrepresent what a real Mod author sees Runtime 0.1 do with
  their strings.
- A Workshop session in `zh-CN` does add one Runtime-generated instruction
  line to the generated VMP/1 prompt (see § VMP localization behavior)
  steering a Coding Agent toward Chinese player-facing text for the Mod it
  writes — but that is guidance to the Agent, not translation of existing
  Mod content, and the Agent/Mod author can still override it per the
  user's actual request.

| | Localized |
|---|---|
| First-party Runtime UI | Yes |
| Third-party Mod content (`api.ui.*` text) | No — author-controlled |

## Error localization rules

Structured error **codes** (`PERMISSION_DENIED`, `VMOD_SYNTAX_ERROR`,
`API_VERSION_MISMATCH`, `DUPLICATE_MOD`, `SETUP_EXCEPTION`,
`PACKAGE_DEPENDENCY_MISSING`, etc.) are stable VMP/1 protocol identifiers.
They are never translated, never renamed, and always appear verbatim in
"Technical details" / "Copy Error" / "Copy Fix Prompt" output.

Only the human-readable **explanation** is locale-dependent, and it is
never hand-scattered English sentences inline in a dozen `try`/`catch`
blocks. The flow is:

```
error code
    ↓
i18n message key (e.g. errors.permissionDenied.*, errors.manifestInvalid, ...)
    ↓
localized renderer (humanizeError() in index.html)
```

`humanizeError()` is the single place that maps a code to a key; every
Workshop surface that shows an error (Create tab result, Mods tab card,
Errors tab) calls through it rather than re-implementing wording.

## Technical identifiers never translated

None of the following are ever affected by locale, in any UI, in any
generated prompt:

- `manifest.permissions` values (`world.read`, `world.write`, `player.read`,
  `player.modify`, `entity.read`, `entity.spawn`, `entity.modify`, `ui`,
  `storage`, `input`, `audio`, `network`) — only their *description* text
  is localized (`permissions.*` keys), the id itself is always shown too.
- Structured error codes (see above).
- Resource ids (`core:grass`, `core:dirt`, ..., and any Mod-registered
  `namespace:id`). Display *labels* for the six core blocks are localized
  via `blocks.core.*` (e.g. `core:grass` → "Grass" / "草方块"), but the
  underlying id, world data, registry lookup, and VMP output identity are
  completely unaffected — there is no `BlockDefinition` (API 1) change.
- `api.*` method and event names, `manifest` field names, `defineVoxelMod`,
  VMP/1 section markers (`[VMP SYSTEM CONTRACT]`, `[USER REQUEST]`, etc.),
  the VMP/API/Runtime/Package-Format version numbers, and `.vmod`/`.vgame`
  structural keys.
- Internal status enum *values* used by other Runtime code (e.g. a Mod
  card's `liveStatus` of `'active'`/`'failed'`/`'unloaded'`, used as a CSS
  class) — only the *displayed* status label is localized (`status.*`).

## VMP localization behavior

VMP 1 is frozen; Runtime 0.1.1 does not invent VMP 2 and does not change
`generatePrompt()`'s output *contract*. The system-contract prose (rules,
lifecycle skeleton, namespace-derivation walkthrough, API/event/capability
listings) is intentionally kept in English in both locales — it is
instructions read by a Coding Agent, not by the player, and keeping it in
one language avoids any risk of a Chinese paraphrase silently drifting from
what `PUBLIC_API_META`/`PERMISSION_MAP` actually enforce (the same drift
`auditApiMetadata()` already exists to prevent). Canonical section markers
(`[VMP SYSTEM CONTRACT]`, `[VMP RUNTIME CAPABILITIES]`, `[VMP API SPEC]`,
`[VMP EVENTS]`, `[INSTALLED MODS]`, `[USER REQUEST]`, `[OUTPUT CONTRACT]`)
are always in English and always in this order, in every locale.

What *is* locale-dependent, generated fresh from the active Workshop locale
(never hand-duplicated): one additive, non-breaking instruction line inside
the system contract —

- `en-US`: "Player-facing text created by this Mod should use English
  unless the user's request says otherwise."
- `zh-CN`: "除非用户请求另有说明，否则该模组产生的玩家可见文本应使用简体中文。"

`[USER REQUEST]` always carries the player's own words verbatim, in
whatever language they typed them in, regardless of Workshop UI locale.
"Copy Fix Prompt" (`generateFixPrompt()`) follows the same principle: the
same language-instruction line is added, but source code, error codes, API
identifiers, and stack traces inside `[CURRENT MOD SOURCE]`/`[RUNTIME
ERROR]` are preserved byte-for-byte.

## Standalone Bake behavior

A baked standalone `.html` is produced by splicing a Game Package into a
pristine, pre-mutation snapshot of the *entire* document (see
`DISTRIBUTION_SPEC.md` § Bake architecture) — which means the baked file
contains the exact same `runtime.i18n` implementation, the exact same
`I18N_MESSAGES` catalog, and the exact same language switcher as the
Runtime it was baked from. Nothing about the creator's *current* language
selection is baked in as permanent visible text or as a forced locale — the
receiver's copy runs the same negotiation (`?lang=` → saved preference →
`navigator.language` → `en-US`) fresh, starting from *their* browser/saved
state, and can freely switch languages if Workshop is included in the
package (the default).

## Testing requirements

- Dev-only translation completeness audit (`?dev=1`): `runtime.i18n`
  compares every `en-US` key against `zh-CN` (and vice versa) at boot and
  `console.warn`s any mismatch; logs nothing if the catalogs are in sync.
  Mirrors the existing `auditApiMetadata()` metadata-drift audit in spirit
  and never runs (or has any cost) outside `?dev=1`.
- Manual acceptance path per locale: start/pause menu → HUD → Workshop
  (Create → generate prompt → import `.vmod` → permission preview → load →
  Mods/Errors tabs → Export tab → Bake) with no first-party English text
  visible in a `zh-CN` session, and no regression in an `en-US` session.
- Live-switch test: toggle English ↔ 简体中文 with Workshop open on each
  tab and verify every visible label updates with no reload, no duplicated
  DOM, and no mixed-language leftovers.
- Fresh-boot tests: simulated `zh-CN` browser locale with no saved
  preference boots directly into Chinese; simulated `en-US` boots into
  English unchanged from the Golden 0.1.0 baseline.
- `?lang=` override test, including an unsupported value
  (`?lang=xx-INVALID`), which must fall through the negotiation chain
  rather than error.
- Persistence test: explicit language selection survives a reload via
  `localStorage["voxel-runtime.locale"]`; a `file://` environment where
  `localStorage` throws must degrade to "selection still applies live, just
  not remembered next launch," never to a boot failure.
- Bake test: bake in each locale, reopen the standalone file fresh, confirm
  it negotiates its own locale independently and its language switcher
  still works.

## Runtime 0.2.0-dev addendum

Transactional Mod Revision's Workshop UX (Replace Mod preview, permission
delta, resource-change summary, revision-specific error banners) added
~20 new keys, all under the existing `workshop.create.*`/
`workshop.errors.*`/`errors.*` families — no new top-level family was
needed. Catalog parity (`en-US` ⇄ `zh-CN`) was reverified via the same
`?dev=1` completeness audit described above. See `MOD_REVISION_SPEC.md`
§ i18n for the live bilingual test transcript, including a full Agent
revision round-trip conducted entirely in `zh-CN`.

## Runtime 0.2.0-dev addendum — Revision History

One new top-level family, `workshop.history.*` (~16 keys: History panel
heading/labels, Undo/Redo buttons, "Revision N"/"Based on Revision N"/
"Current," relative-time strings, Restore/"Revise from this version"
buttons, and the "based on an older version" warning used both in the
Workshop UI and inside the generated Agent revision prompt). Catalog
parity reverified: 177 keys per locale, zero mismatch. The full flagship
scenario (import → revise → dislike → undo → "revise from an older
version" → branch) was conducted live, end-to-end, entirely in `zh-CN`,
including every History-panel label and the branch-warning notice in both
the UI and the Agent prompt text. See `REVISION_HISTORY_SPEC.md` § Phase
H6 for the transcript.

## Runtime 0.2.0-dev addendum — Creation Workspace

One new family, `workspace.*` (14 keys: Save/Open labels, the save-vs-export
explanatory hint, Original/Remix provenance strings, dirty indicator,
trust notice, drop zone, and error strings), plus two additions to
`workshop.history.*` (`forkButton`, `startRemixButton`). Catalog parity
reverified: 191 keys per locale, zero mismatch. See `WORKSPACE_SPEC.md`
§ i18n.

## Runtime 0.2.0-dev addendum — Community Foundation

One new family, `community.*` (18 keys: Publish/Open Release labels,
tags/language/release-note fields, Original/Remix provenance strings,
trust notice, drop zone, and error strings), reusing several existing
`distribution.*`/`workshop.export.*` keys where the underlying human
explanation is effectively identical rather than maintaining near-
duplicate wording. Catalog parity reverified: 208 keys per locale, zero
mismatch. See `COMMUNITY_RELEASE_SPEC.md` § i18n.
