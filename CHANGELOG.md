# Changelog

Entries are added only for genuinely user-visible or contract-relevant changes.

## 0.1.3 - 2026-08-03

### Fixed

- **The raycast never hit anything.** `StartShapeTestLosProbe` is asynchronous:
  it starts a probe whose result is ready on a later frame. `GetShapeTestResult`
  returns a status first — 0 not started, 1 pending, 2 ready — and reading the
  hit without checking it gets the pending answer, which is always "nothing".

  So holding the interact key found nothing anywhere, and the crosshair added to
  diagnose the previous defect reported exactly that.

  Now uses the synchronous probe, and checks the status rather than discarding
  it. A pending result is indistinguishable from an honest miss.

### Added

- `/nxc_target_debug` — what this client actually sees: whether targeting is
  active, how many options arrived, what the ray is hitting, which options could
  apply, and **for each one that does not appear, the filter that rejected it**.

  Two diagnoses of "holding the key does nothing" were made by reading code.
  Both were real defects; neither was visible from the server, and every round
  trip cost a deployment. A candidate rejected for distance and one rejected for
  a capability look identical from outside.

## 0.1.2 - 2026-08-03

### Fixed

- **No server-registered option ever reached a client.** Two correct decisions
  collided and the collision shipped: the event name is stripped from the copy
  broadcast to clients so a client cannot enumerate the server event surface, and
  validation requires an option to do something. Together, every broadcast option
  was refused by the receiving client and no interaction ever appeared in game.

  The copy now carries `hasServerAction` — the client knows there is something to
  invoke and still cannot say what — and `id`, which validation also requires.

- **A broadcast option kept the wrong key.** The client recomputed it from its own
  resource name, so an option the server filed as `nxc_devtools:inspect` became
  `nxc_target:inspect` on the client, and selecting it sent back a key the server
  had never heard of. An existing key now wins.

  Same defect nxc_interact had between its registry and its sessions, in a second
  place, found the same way: by following what a real payload does rather than
  testing each side alone.

### Added

- A crosshair while targeting, which is a diagnostic as much as an affordance.
  "I held the key and nothing happened" has three indistinguishable causes — the
  key is not bound, the ray hit nothing, the ray hit something with no options —
  and the colour separates them.

## Unreleased

Initial implementation of the target system.

### Added

- Option schema for entity, network-entity, model, bone, zone, and global
  targets, with distance, capability, item, and callback filters.

- **A server gate that never trusts the client.** The event name comes from the
  registered option, never from the payload; distance is measured by the server
  between two positions it holds; capabilities come from nxc_core's session.

  The display copy broadcast to clients has the event name stripped, so a client
  cannot invoke an event it has no way to learn, and reading the option list does
  not enumerate the server's event surface.

- Options namespaced by owner, so no resource can register into another's
  namespace or invoke its options by guessing an id.

- A single raycast from the camera, cast only while targeting is held. No entity
  enumeration anywhere. The world is in the trace flags, so a wall between the
  player and a target blocks it.

- A keybind through `RegisterKeyMapping`, so the binding appears in the game's
  own settings screen, can be changed, and works on a controller.

- Cleanup on resource stop, on both sides.

- 50 tests, 14 of them driving the gate the way an attacker would. Verified by
  planting two real vulnerabilities — trusting the payload's event name, and
  trusting its distance — each of which fails exactly the test written for it.

### Known limitations

- **Item-gated options are refused entirely.** nxc_inventory is Phase 3, and
  until a provider registers there is nothing to check an item against. Failing
  closed makes the feature look broken; failing open would leave every item-gated
  action in the game ungated with nothing saying so.

- **Zone-attached options are refused server-side** for the same reason:
  server-side zone membership is not implemented, so it is not assumed.

- **Capability grants are never populated**, so every capability-gated option is
  refused. That is nxc_core's gap and is recorded there.

- An option guarded only by `canInteract` is guarded by the player. That is not a
  defect to be fixed here — it is why `capability` and `item` exist, and why
  registration warns when a server action declares neither.

- Nothing here has run on a server.

Initial development. No release has been made.
