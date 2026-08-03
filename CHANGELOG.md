# Changelog

Entries are added only for genuinely user-visible or contract-relevant changes.

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
