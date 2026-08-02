# Platform — nxc_target

**Target:** FiveM for GTA V Enhanced, Enhanced Cfx Server runtime.

Required by Master Design Document v0.4 section 38.3 and
[`PLATFORM_STANDARDS.md`](https://github.com/NC-Framework/nxc-core-governance/blob/main/standards/PLATFORM_STANDARDS.md).
All eight items are answered. **`None` is written where it applies** — an empty section is a claim that
someone looked and found nothing, and an absent section is not.

`nxc_target` provides target-first interaction: what a player is looking at, and what they may do with it.

---

### 1. Enhanced natives and platform APIs used

**None — this resource has no code yet.**

That is a statement about the present, not a claim about the design. Raycasting, entity resolution, model and bone lookup, and on-screen markers are all native surface. This resource will have the largest native footprint of the foundation set, which is exactly why the adapter boundary matters here most.

### 2. Deprecated or compatibility-only natives used

**None.**

### 3. Game assets, archetypes, metadata, or data files required

**None currently.**

### 4. Voice, networking, state bag, entity, and routing bucket assumptions

**Entities:** targeting resolves entities client-side and validates server-side. A client-supplied target is a claim, never a fact — the same rule sessions already follow.

Routing buckets, when needed, are **requested from `nxc_core`**, never chosen. Two resources picking the
same number is the accidental-instance failure the design names as an existing production problem.

### 5. Known Enhanced platform limitations

**None known, and none have been looked for.** Nothing has been tested on Enhanced, because the
development server runs Legacy artifacts (blocker B-10).

### 6. Minimum supported Cfx Server build

**Not pinned.** No build has been named — OD-020, blocker B-11. The manifest declares `UNPINNED`, which
fails `check-manifests.mjs` deliberately rather than passing with a plausible-looking number.

### 7. Asset conversion or validation requirements

**None.**

### 8. Optional Legacy compatibility layer

**None**, and none is planned. Legacy support is not a launch requirement (ADR-0016).
