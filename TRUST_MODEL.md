# Voxel Craft — TRUST_MODEL.md (Runtime 0.2 — Community Trust Gate MVP)

```
Runtime 0.2.0-dev
API 1 / VMP 1 / Package 1 / Workspace 1 / Release 1 — all frozen
```

This is not a sandbox. It is the minimum gate needed to deploy Community
publicly without letting a stranger's JavaScript run in this Runtime's
real page.

## The two trust tiers

**Trust Tier 1 — local**: any Mod source the player explicitly selected
from their own filesystem (`.vmod`, `.vrelease`, `.vwork`, `.vgame`
drop-zones, Create-tab imports). Trusted, same-realm execution, exactly
as before this milestone — **unchanged**. The player chose the file;
they assume the risk, the same as running any other local executable.
The existing trust-warning copy for local arbitrary JS stays as-is.

**Trust Tier 2 — community-remote**: any Release object that entered the
Runtime via `runtime.community.getRelease()` (an anonymous fetch from
the Community backend). This Runtime has no relationship with, and no
way to vet, whoever published it. **Its Mod source is never executed.**
Browsing, searching, inspecting metadata/manifests, viewing lineage, and
downloading the `.vrelease` file all still work — only execution is
blocked.

**Future — Trust Tier 3 (not built here)**: a real sandbox (iframe/
Worker RPC or similar), which would allow community-remote code to run
under actual isolation. Explicitly out of scope this milestone.

## Where the gate lives

Two internal constants, never exposed as `api.*`, never a new
permission, never an API/format version bump:

```js
const TRUST_LOCAL = 'local';
const TRUST_COMMUNITY_REMOTE = 'community-remote';
```

`communityGetRelease(remoteId)` tags the fetched Release object with
`__trustTier = TRUST_COMMUNITY_REMOTE` (plus `__snapshotText` for exact-
bytes download). A locally-parsed Release/`.vmod`/`.vwork`/`.vgame`
never gets this field, so it's implicitly Tier 1.

The gate itself is one function, called at the very top — before
anything else runs — of every function that would otherwise reach Mod
execution:

```js
function assertLocalTrust(rel){
  if(rel && rel.__trustTier === TRUST_COMMUNITY_REMOTE){
    throw regError('RELEASE_REMOTE_EXECUTION_BLOCKED', ...);
  }
}
```

Called first-line in `openRelease(rel)` (which is the only path that
calls `ImportManager.importSource()` → `captureDefinition()` → `new
Function(...)` for a Release) and in `startRemixFromRelease(rel)`
(defense-in-depth — it depends on Mods already being active via
`openRelease()`, so it's unreachable for a remote Release either way,
but gated explicitly for a clear error instead of a confusing downstream
one). This centralizes the gate at the two real entry points instead of
scattering UI-only checks that a different code path could bypass.

**Verified reachability**: `new Function` appears in exactly one place
in this Runtime (`captureDefinition`, `index.html`), reached only via
`ImportManager.importSource`/`beginImport`, reached only via
`openRelease()` for a Release object — now gated. No other path
(Explore, search, Release detail, manifest inspection, lineage, download)
touches `captureDefinition`, `new Function`, or `eval` at all — those
are pure metadata/JSON operations from the start.

## What changed for the player

Opening a Release fetched from the Community backend
(`?communityRelease=<uuid>` handoff, or the Workshop's manual remote-id
fetch) now shows a metadata-only preview — title, author, description,
tags, mod count/manifests, provenance — plus:

> "Community code execution is not available yet. To protect your
> browser and local data, this Beta does not run JavaScript Mods from
> the Community directly. You can still view this release's information
> or download the .vrelease file."

with **Download** and **Back** buttons. There is no "Open"/"Start Remix"
affordance for a remote Release this milestone — Remix would require the
Mods to already be active, which they never are for a remote Release
now. The copy deliberately never says "safe," "sandboxed," "verified,"
or "isolated" — none of those are true yet; this is a quarantine, not a
sandbox.

## No developer override

The spec allowed a trivial `?dev=1` unsafe-override as optional, skip-if-
costly. Skipped in this timebox — the gate is unconditional for every
player, including with `?dev=1` set (which only exposes unrelated
diagnostic panels elsewhere in this Runtime, never a Mod-execution
bypass).

## Verified test

Published a real Community Release whose Mod's `setup()` attempted:
`localStorage.setItem`, `document.body.innerHTML = ...`,
`window.location = ...`, `fetch(...)` to an external host, an infinite
`while(true){}` loop, and `throw new Error(...)`. Opened it via the real
`?communityRelease=` handoff against the live backend. Result: zero
`localStorage` keys written, `document.body` unchanged (no "PWNED"
string ever appeared), `location.href` unchanged, Runtime remained fully
responsive (no hang — proof by construction: the gate throws before
`ImportManager.importSource` is ever called, so the `while(true)` inside
`setup()` is provably never reached, not merely "didn't happen to run
long"), Mods count stayed at 0 throughout.
