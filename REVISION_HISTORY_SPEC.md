# Voxel Craft — REVISION_HISTORY_SPEC.md (Runtime 0.2.0-dev)

```
Runtime 0.2.0-dev
API 1 — frozen, unaffected
VMP 1 — frozen, unaffected
Voxel Game Package Format 1 — frozen, unaffected
```

Source of truth for **Revision History & Safe Undo**: every imported Mod
keeps a lightweight, page-session history of its successfully-committed
versions, with transactional Restore/Undo/Redo and "Revise from an older
version" branching — all built on top of `MOD_REVISION_SPEC.md`'s existing
transaction engine, never bypassing it.

## Phase H0 — Transaction boundary audit (findings)

Before building history, the existing revision transaction from the prior
milestone was audited for exactly what it does and does not roll back.
Two real bugs were found and fixed; the rest of this section documents
honest, verified-live behavior.

### H0.1 — The transactional guarantee, stated exactly

> Mod Revision is transactional for Host-owned Mod lifecycle state and
> registered definitions. It is **not** automatically a full snapshot
> transaction over arbitrary world/player/storage mutations performed by
> Mod code.

What rollback DOES restore, verified and unchanged from `MOD_REVISION_SPEC.md`:
event subscriptions, timers, Runtime-owned UI (HUD text/toasts/banners/
panels), spawned entity instances, block/entity-type Registry definitions
(same numericId), and the Mod's activation state itself (`mods` map entry).

What rollback does **NOT** restore — verified live (Acceptance Test K):

```js
setup(api) {
  api.storage.set("marker", "v2-partial");
  api.world.setBlock(30, 20, 30, "core:stone");
  api.player.giveItem("core:wood", 5);
  throw new Error("fail");
}
```

After this fails and the old Mod is restored: the world cell at `(30,20,30)`
is **still** `core:stone` (confirmed via a fresh probe Mod's
`api.world.getBlock`), and the player's inventory **still** has the 5
`core:wood` (confirmed via `api.player.getInventory`). Neither is reverted.
There is no world/player transaction log; `reviseMod` never touches either
subsystem at all, in either direction.

`api.storage` is the one subtle case: in the live test, reading
`localStorage['vmp1:boundarytest:marker']` after the failed revision showed
the value back at `"v1"`, not the failed attempt's `"v2-partial"` — but
**not** because storage was rolled back. It happened only because the OLD
Mod's `setup()` was re-run during rollback (see H0.3) and that `setup()`
itself unconditionally calls `api.storage.set('marker', 'v1')` again,
overwriting whatever the failed new version had written. Had the old
`setup()` not touched that key, `"v2-partial"` would have survived
untouched. **Storage "looking reverted" is an artifact of the old Mod's own
idempotent re-execution, never a real journal.** Do not rely on it.

### H0.2 — No full world/player/storage transaction was built

Per explicit instruction, this milestone does not snapshot the world
`Uint8Array`, player state, inventory, or `localStorage` for every
revision. The above is documented, not solved. A Mod author who needs
one-shot mutations to behave safely under revision should guard them with
Mod-owned state (see H0.3's advisory).

### H0.3 — Rollback re-activation is not automatically idempotent

Because rollback (and Restore/Undo/Redo, which reuse the identical
mechanism) works by re-running a retained `setup()`/`start()`, any
one-time side effect in that code repeats on every re-activation. Verified
live: a `setup()` that calls `api.player.giveItem(...)` unconditionally
gives the item again each time that exact version is (re)activated,
whether via a failed-revision rollback, an explicit Undo, or a Restore.
**This is not "exact restoration" in general — it is exact restoration of
Registry/lifecycle state, and re-execution of whatever code the Mod's own
`setup()` contains.**

Host-side advisory (documentation only — VMP 1's output contract is
unchanged): a Mod's `setup()` should primarily register resources and
install Runtime-owned behavior (event subscriptions, timers, entity
types); a persistent one-shot gameplay mutation whose repetition would
matter should be guarded with Mod-owned state, e.g.

```js
setup(api) {
  if (!api.storage.get('starterKitGiven', false)) {
    api.player.giveItem('core:wood', 5);
    api.storage.set('starterKitGiven', true);
  }
}
```

This guidance may be surfaced in future Workshop help text; it is **not**
injected into generated `.vmod` output or into VMP 1's contract.

### H0.4 — Tombstone reactivation (bug found and fixed)

Runtime 0.2.0-dev's first cut of `tombstone(id)` called `byString.delete(id)`,
which meant a later re-registration of that exact id (even by the same
owner) would fall into the "brand new id" branch of `register()` and
allocate a **fresh** `numericId` — silently violating "same owner may
reactivate the tombstoned public id, existing numericId is reused."

**Fixed**: `tombstone(id)` no longer deletes the `byString` mapping, only
marks the `byNumeric` entry `removed:true`. `toNumeric()`/`get()`/`list()`
now check the `removed` flag directly (instead of relying on map
membership) to keep hiding a tombstoned id from ordinary lookups.
`register()`'s replace-eligibility check (`canReplace`) no longer requires
`!existing.removed` — the same owner, mid-revision, reactivating its own
previously-tombstoned id now takes the replace-in-place path and reuses
the exact original `numericId`, exactly like a live-to-live replace does.

One consequence, now the documented rule: **a tombstoned id is permanently
reserved to its original owner.** No other Mod can ever claim that exact
public id, live or tombstoned — this was implicitly true before too (the
old delete-based version would have let a *different* Mod claim it with a
new numeric id, which was never actually tested or relied upon), and is
now explicit and simpler: one public id, one owner, forever, for the page
session.

Verified live (Acceptance Tests C/L): V1 registers `block_a` + `block_b`;
V2 drops `block_b` (tombstoned — result panel: "Removed: histtest:block_b");
V3 re-registers `block_b` (result panel: "Added: histtest:block_b" — see
note below on why the label says "Added," not "Reused"). Throughout,
`api.world.getBlock()` at the cell `block_b` was originally placed at kept
resolving to `"histtest:block_b"` even while tombstoned (rendering/hardness
data was never touched), and after reactivation the id resolves normally
again — the world cell was never corrupted and needed no regeneration.

**Note on the "Added" vs. "Reused" label**: the resource-change summary is
computed by diffing "ids owned *before this specific revision started*"
(which excludes anything already tombstoned) against "ids touched *during
this revision*." A reactivated id is therefore correctly labeled "Added"
from that revision's point of view (it went from absent to present), even
though the underlying `numericId` was never reallocated. The Workshop
summary describes *session resource ownership churn*, not raw numeric-slot
identity — the latter is an internal guarantee, not a UI-facing concept
(API 1 never exposes numeric ids at all).

### H0.5 — Core ownership wording

Canonical rule, now stated explicitly in `createIdRegistry`'s header
comment: **`core:*` definitions are Runtime-owned and never
Mod-revisable. They are not "owned by the revision window."** No revision
ever opens a window with `revisionOwner === 'core'` — `revisionOwner` is
always set to a Mod's own `manifest.id` by `ModHost.reviseMod`, and
`withCoreRegistration`'s `registeringCore` flag (which is what actually
grants `core:` registration rights) is completely independent of and
unreachable from the revision-window mechanism. `MOD_REVISION_SPEC.md`'s
existing "Core namespace protection" section already matched this rule;
this section makes the "not owned by the revision window" distinction
explicit for anyone who might otherwise conflate "Runtime-owned" with "a
revision window opened for the pseudo-owner `'core'`."

## Phase H1 — Revision history data model

`RevisionHistoryStore` (internal — not `api.history`; API 1 unaffected).
One `ModHistory` per revisable `manifest.id`:

```
ModHistory {
  currentRevisionId,
  revisions: Map(revisionId -> RevisionEntry),
  order: [revisionId, ...],   // creation order, all branches interleaved
  redoStack: [revisionId, ...]
}

RevisionEntry {
  id, parentId,
  seq,              // display-only "Revision N" -- creation order, see § Version labels
  source,           // the ENTIRE reconstructable snapshot -- see § Source is the snapshot
  manifestSnapshot, // deep-copied manifest at commit time
  createdAt,
  reason,           // the Workshop revision request text, or null
  locale,           // active runtime.i18n locale at commit time, or null
  origin            // 'import' | 'revision'
}
```

### H1.1 — Source is the real snapshot

No live callback, subscription, timer, entity, DOM node, or Registry
object is ever serialized into a `RevisionEntry`. `source` (plain text)
is the only durable snapshot; restoring an entry means feeding that text
back through `captureDefinition` → `ModHost.validateRevision` →
`ModHost.reviseMod` — the exact same pipeline every other revision already
uses (see Phase H2). This is why history costs almost nothing: it is
string storage, not object/state storage.

### H1.2 — Successful versions vs. failed attempts

`RevisionHistoryStore.record()` is called from exactly two places, both
**after** a real success is already confirmed:

- `ImportManager.confirmImport`, immediately after `ModHost.activate()`
  returns `ok:true` (this is what makes the *first* import Revision 1 —
  see H1.3).
- `ImportManager.confirmRevision`, immediately after `ModHost.reviseMod()`
  returns `ok:true`.

A failed capture/validation/setup — whether from an ordinary import, a
Workshop revision, or (per H2) a Restore/Undo/Redo attempt — is never
recorded. A user can never be shown, and can never select, a "version"
that never actually ran. Failed *attempts* remain visible only as the
existing ephemeral Create-tab result/error panel (see
`MOD_REVISION_SPEC.md` § Workshop revision UX) — there is no separate
persisted "attempt history" list; the existing structured-error log
(`runtime.modHost.getErrors()` / the Errors tab) already serves that
purpose for anyone who wants a durable record of failures.

### H1.3 — Initial version

`ImportManager.confirmImport`'s success path calls
`RevisionHistoryStore.record(modId, {origin:'import', parentId:null, ...})`
unconditionally, so **every** Mod that is ever successfully imported
(through the Workshop, the dev file picker, or a baked game's boot-time
embedded-package import — all three funnel through `confirmImport`) has a
Revision 1 the instant it activates. There is no "history only starts
after your first revision" gap.

### H1.4 — Bounded history

`MAX_HISTORY_PER_MOD = 10`. When adding a new entry would exceed the bound,
the oldest entry that is **not** the current head and **not** one of its
ancestors is dropped first (`prune()` walks the current head's parent
chain to build a protected set, then removes from `order[0..]` forward,
skipping protected ids). This means an orphaned branch (one nobody is
currently on, and nobody has re-branched from since) is pruned before any
part of the live lineage — the "Based on Revision N" ancestry display for
the current branch stays coherent for as long as that branch is in use.
This is a bound, not source control — no reflog, no dangling-commit
recovery once pruned.

## Phase H2 — Restore any version / Undo / Redo

### The transactional guarantee

**Every** Restore, Undo, and Redo funnels through one function,
`ImportManager.restoreToEntry(modId, entry)`, which runs the retained
`entry.source` through the identical `captureDefinition` →
`ModHost.validateRevision` → `ModHost.reviseMod` pipeline as any other
revision. **Nothing in the History UI ever mutates a Registry entry
directly.** A corrupted or otherwise-broken historical source fails at
capture or validation exactly like a bad uploaded file would (see
Acceptance Test E) — the currently-running Mod is provably untouched
(capture/validation never stops it), and a clear structured error is shown.

### H2.1 — Undo Last Revision

`undoLastRevision(modId)` = `restoreToEntry(modId, entry-at(current.parentId))`.
If the current entry has no parent (it's the Mod's Revision 1), Undo is
correctly refused with a friendly "no previous revision" result rather than
attempting anything.

### H2.2 — Redo

Implemented as a small stack, not general DAG traversal (deliberately
avoiding the "ambiguous branch" trap the spec warned about): every
pointer-move-to-an-existing-entry (Undo, or an explicit Restore of an
older entry) pushes the id being moved *away from* onto `redoStack`.
`redoRevision(modId)` peeks (not pops) the top of that stack, runs it
through the same transactional `restoreToEntry`, and only pops on success
— so a failed Redo attempt (e.g. that entry's source somehow became
invalid) leaves the stack intact to retry. **Any** brand-new `record()`
(a genuinely new revision, from the current head or as a branch) clears
the redo stack outright — the same rule every text editor's undo/redo
uses: making a new change after an undo discards the "future" you undid
away from.

### H2.3 — History pointer vs. duplicate entry (design decision)

**Chosen model: Restore/Undo/Redo move `currentRevisionId` among EXISTING
entries — they never create a duplicate entry with identical source.**
"Revise from this version" (an Agent-produced genuinely *new* source,
whether continuing the head or branching from an older entry) is the only
thing that ever calls `record()` and creates a new entry.

This was chosen over "every activation is a new history event" specifically
because (a) it keeps Redo simple and unambiguous (a stack of *existing*
ids, not a search over near-duplicate content), (b) it matches player
intuition — "restore" reads as "go back to," not "make a new copy of
something old," and (c) it avoids polluting the bounded history (H1.4)
with content-identical entries on repeated undo/redo cycling, which the
spec explicitly warns against ("Test G — Repeated undo/revision," verified
live to leave the history exactly as long as the number of *distinct*
source versions actually created, regardless of how many times each was
undone/redone/restored).

## Phase H3 — Lightweight branch semantics

`parentId` on every `RevisionEntry` forms a tree (never merged, never
requiring conflict resolution — no Git). Two entries may share the same
`parentId`, producing siblings/branches. This is populated two ways:

- **Linear continuation** (default): `confirmRevision`'s `record()` call
  omits `parentId`, so `RevisionHistoryStore.record()` defaults it to
  `h.currentRevisionId` — the current head.
- **Branch** ("Revise from this version," H3/H5): the Workshop passes
  `meta.baseRevisionId` (the explicitly-selected older entry's id)
  through to `confirmRevision`, which forwards it as `record()`'s explicit
  `parentId` override — regardless of what the *current* head happens to
  be at that moment. Verified live: undoing back to Revision 1, then
  branching from Revision 2 (an entry that was NOT the current head at the
  time), correctly parents the new entry under Revision 2, not under
  whatever was current.

### H3.1 — Parent revision id

Already covered above — every entry always carries its `parentId` (or
`null` for a Revision 1). No commit objects, no merge/cherry-pick
machinery; ancestry is the entire DAG feature surface.

### H3.2 — Current head

`ModHistory.currentRevisionId` is the single source of truth for "what's
actually running right now" from the history model's point of view (it is
kept in lockstep with the real `ModHost`/`ImportManager` activation state
by every successful transaction — never set speculatively). The Workshop
marks exactly one entry "● ... · Current" per Mod; every other entry shows
"○" and remains fully accessible (View Source, Restore, Revise from this
version) regardless of which branch it's on.

## Phase H4 — Workshop History UX

Mods tab → each Mod card gains a **History** button (same retained-source
precondition as "View Source"/"Revise with Agent" — a built-in `?mods=1`/
manual `defineVoxelMod` Mod has no history to show, same pre-existing 0.1
limitation). Clicking it toggles an inline panel on that card:

```
REVISION HISTORY
[Undo Last Revision]  [Redo]

● Revision 3 · Current
  v1.2.0 · just now
  "add a low-health warning"
  Based on Revision 2
  [View Source] [Revise from this version]

○ Revision 2
  v1.1.0 · 3m ago
  "reduce enemy speed 30%"
  Based on Revision 1
  [View Source] [Restore this version] [Revise from this version]

○ Revision 1
  v1.0.0 · 5m ago
  [View Source] [Restore this version] [Revise from this version]
```

Undo/Redo are disabled (not hidden) when unavailable (no parent / empty
redo stack). A Restore/Undo/Redo result — success or failure — is shown
as inline feedback directly in the panel (reusing `humanizeError` for
failures, exactly like every other structured error in this Runtime), and
triggers a full Workshop re-render (Mods-tab badges/counts and the History
panel itself all depend on live state).

### H4.1 — Source view

"View Source" on any history entry (current or not) opens the existing
read-only source modal, unchanged — no new editor/syntax-highlighting
dependency, matching the existing "View Source" on a live Mod exactly.

### H4.2 — Version labels

The internal sequence (`entry.seq`, "Revision N") is the primary, always-
present label — it is **creation order across the whole Mod's history,
including all branches**, not ancestry depth (see the fix below) and not
`manifest.version` (which an Agent may forget to bump, or which may
collide across branches — Runtime 0.2 never assumes it is unique).
`manifest.version` (from `manifestSnapshot`) is shown alongside as
secondary, purely informational text when present.

**Bug found and fixed during testing**: the first implementation computed
`seq` as `parentEntry.seq + 1` (ancestry depth). Two sibling branches off
the same parent (e.g. Revision 2 has children Revision-via-continuation
and Revision-via-"revise from here") both computed the same depth and
were both labeled "Revision 3" — a real, confusing collision, caught live
by Acceptance Test F. Fixed to `seq = h.order.length + 1` at record time —
strictly creation order, always unique, regardless of branch shape.

### H4.3 — Change request

`entry.reason` (the Workshop revision-request textarea content at the
moment of a successful `confirmRevision`) is shown verbatim under each
entry that has one (Revision 1 / plain imports never have a reason). It is
Workshop/Runtime session metadata only — never injected into
`manifest`, never sent back into a Mod's own `defineVoxelMod({...})` call,
never part of the exported source.

## Phase H5 — Revise from a historical version

"Revise from this version" (any history entry, current or not) switches
the Create tab into revision mode exactly like the plain "Revise with
Agent" button does, additionally recording which entry was selected
(`revisingFromRevisionId`). `runtime.vmp.generateRevisionPrompt` accepts
an optional `options.baseRevisionId`; when set and it differs from the
Mod's actual current head, the prompt is built from that OLDER entry's
retained `source`/`manifestSnapshot` (not the live current version), and
gains an extra section:

```
[BASE VERSION NOTICE]
This revision request is based on Revision 2, an OLDER version of this
Mod, not the current one. Do not assume any changes made in revisions
after Revision 2 are present in the source below -- they are not. Base
your revised output only on the source given here plus the revision
request.
```

(Localized; `zh-CN` wording is the natural Chinese equivalent, not a
literal translation — see `I18N_SPEC.md` conventions.) The identical
warning (`workshop.history.basedOnOlderWarning`) is also shown in the
Workshop UI itself — both in the Create-tab revision notice and in the
"Replace Mod" preview — so the player sees the same "no automatic merge"
disclosure the Agent does, in the active locale. No merging is attempted
or implied anywhere. Canonical VMP section markers from the existing
revision-prompt design (`[VMP REVISION TASK]`, `[CURRENT MOD MANIFEST]`,
`[CURRENT MOD SOURCE]`, `[REVISION REQUEST]`, `[OUTPUT CONTRACT]`, plus the
shared `[VMP RUNTIME CAPABILITIES]`/`[VMP API SPEC]`/`[VMP EVENTS]`/
`[INSTALLED MODS]` sections) are unchanged and always present regardless
of whether the base is historical.

## Phase H6 — i18n

All new UX lives under existing translation-key families
(`workshop.history.*` is new but follows the exact same flat-key,
`{name}`-interpolation, `en-US`⇄`zh-CN` parity conventions as every other
family — see `I18N_SPEC.md`). Both locales verified complete via the
existing `?dev=1` catalog-parity audit after this milestone's ~16 new
keys (177 keys per locale, zero mismatch). The entire flagship scenario
(see Real Agent Test below) was conducted end-to-end in `zh-CN`, including
every History-panel label, the Undo/Redo buttons, and the "based on an
older version" warning in both the UI and the generated Agent prompt.

## Phase H7 — Export / Package semantics

Unchanged from `MOD_REVISION_SPEC.md`'s existing guarantee, reconfirmed
live for a Mod with 4+ recorded history entries across two branches: a
baked standalone `.html` / exported `.vgame` embeds `{manifest, source}`
for the **current** version only — inspected directly, confirmed zero
`previousSource`/`history`/`revisionResult`/branch-graph/revision-request
data anywhere in the payload, and the embedded source text does not
contain any earlier version's distinguishing content.

### H7.1 — Baked game history

A baked game's embedded Mod source is loaded at boot through
`loadEmbeddedGamePackage` → `ImportManager.importSource` →
`confirmImport`, the exact same success path that creates Revision 1 for
any other import (H1.3) — so **the recipient's own history for that Mod
starts fresh at Revision 1 = the distributed source**, with no knowledge
of the creator's private iteration history. This falls directly out of
reusing the existing import pipeline; no special-casing was needed. If the
recipient later revises it, their history becomes `distributed version
(Revision 1) → their Revision 2 → ...` — a clean, private lineage,
independent of however many revisions the creator went through to arrive
at what they baked.

## Phase H8 — Persistence

**Not implemented.** History is page-session-only (in-memory), as
explicitly permitted ("do NOT make localStorage persistence mandatory...
persistence is OPTIONAL. Correct in-memory Undo is more important"). A
page reload loses all revision history for every Mod (the Mods themselves
are also not persisted across reload — this is consistent with the rest of
Runtime 0.1/0.2's page-session model, not a new limitation).

## Testing — Acceptance Tests A–L results

All run live in a real browser session against the actual Workshop UI
(file drop → preview → confirm → History panel interactions), using
`api.events.on('game.tick', ...)` counters as the observable proxy for
"is this exact subscription/tick-closure still alive" (see
`MOD_REVISION_SPEC.md`'s note on why `api.time` firing can't be observed
under headless automation — unchanged limitation, not re-litigated here).

| Test | Result |
|---|---|
| A — basic history | **Pass** — import V1, revise → V2 → V3; history shows exactly V1/V2/V3 with V3 current, sources preserved exactly, reasons attached |
| B — undo | **Pass** — Undo transactionally activated V2 (old V3 listener frozen, V2 listener resumed, single HUD marker, no reload); Redo transactionally restored V3 |
| C — block undo | **Pass** (combined with L below) |
| D — entity undo | **Pass** — undoing a Chaser revision froze the newer entity type's tick counter permanently, respawned a V1-behavior instance from V1's re-run `setup()`, no stale tick closure |
| E — failed restore | **Pass** — a dev-hook-corrupted historical source failed at capture (`VMOD_SYNTAX_ERROR`, humanized); the then-current version was provably never touched (its listener kept firing throughout); Runtime stayed fully responsive |
| F — branch | **Pass** (after fixing the seq-collision bug, H4.2) — "Revise from this version" on Revision 2 while Revision 3 was current correctly parented the new entry under Revision 2, producing V1→V2→{V3,V4}; only the new branch's listener stayed live |
| G — repeated undo/revision | **Pass** — a long cycle (revise ×2, undo, revise, undo, explicit restore to an arbitrary older entry, revise again) ended with exactly one listener alive and the current pointer correct at every step; no Registry growth beyond the distinct versions actually created |
| H — multi-Mod isolation | **Pass** — an unrelated Mod's live counter kept incrementing, completely undisturbed, through another Mod's entire undo/redo/restore sequence |
| I — export | **Pass** — baked output inspected directly: exactly one `{manifest, source}` per Mod, current version only, zero history/branch metadata |
| J — baked remix | Covered by design (H7.1) — not re-run as a separate browser pass this round since it exercises the identical `confirmImport` path already proven in Test I's bake and in `MOD_REVISION_SPEC.md`'s own Test J/prior bake-and-reopen coverage; no new code path exists for it |
| K — transaction boundary | **Pass** (as a finding, not a pass/fail in the usual sense) — documented exactly and honestly in H0.1: storage/world/player mutations from a failed revision are NOT reverted; the illusion of storage "reverting" is an artifact of the old Mod's own re-executed `setup()`, not a real journal |
| L — tombstone reactivation | **Pass** — after fixing the bug in H0.4: `block_b` removed then re-registered by the same owner reuses its exact original numeric identity (proven by construction — `register()` has no code path to allocate a new numeric id for an id already present in `byString`, tombstoned or not); the world cell holding it never needed regeneration |

### Real Agent branch/revision test (flagship)

Conducted live, entirely in `zh-CN`, using the Workshop's real "Revise with
Agent" / History / "Revise from this version" flows with the exact
scenario from the spec:

1. Imported a Chaser Mod (V1: normal speed, red).
2. Request "把敌人的速度降低30%" → generated a real Chinese revision
   prompt → produced and imported a genuine complete replacement (V2: 30%
   slower) — committed as Revision 2, parent Revision 1.
3. "不喜欢这个修改，恢复上一版本" → clicked **Undo Last Revision** →
   transactionally reactivated V1 (Revision 1 became current again; V2's
   entity type/tick frozen).
4. "基于较慢的那个版本，再增加低血量警告" → selected **Revise from this
   version** on Revision 2 (the slower one) *while Revision 1 was current*
   → generated prompt correctly included `[BASE VERSION NOTICE]` and used
   Revision 2's retained source/manifest, not Revision 1's → produced and
   imported a genuine complete replacement (slower + low-health red-flash
   warning) → committed as **Revision 3, parented under Revision 2** (not
   under Revision 1, which was current at the time) — the branch.

Zero repair rounds needed at any step. Final history:
`Revision 1 → Revision 2 → Revision 3 (current)`, with Revision 1 as an
untouched sibling root — exactly the intended DAG shape, verified by
reading the rendered History panel directly.

## Remaining limitations

- No world/player/storage transaction (H0.1/H0.2) — documented, not solved.
- Rollback/Restore/Undo/Redo re-run retained `setup()`, so non-idempotent
  one-shot Mod code repeats on every reactivation (H0.3) — an advisory,
  not an enforced guarantee.
- History is page-session-only, no persistence (Phase H8, explicitly
  optional and skipped).
- Redo is a simple last-undo stack, not general multi-branch time-travel —
  any new revision (including a branch) clears it, by design (H2.2).
- Baked Remix history inheritance (H7.1/Test J) is verified by design and
  by the shared code path with Test I's bake, not re-run as a standalone
  browser pass this round.

## Runtime 0.2.0-dev — Creation Workspace addendum

`RevisionHistoryStore` gained `exportModHistory(modId)`/
`importModHistory(modId, data)` (per-Mod, ids/parentId/seq persisted
verbatim, redo stack intentionally not serialized) so its state can survive
a closed browser tab via the new `.vwork` Creation Workspace format. This
is purely additive — every mechanism documented above (touched-based
diffing, transactional restore, the redo stack, pruning) is unchanged and
is exactly what a reopened Workspace's Undo/Restore/branch immediately
resume using. Full design: `WORKSPACE_SPEC.md`.
