--- nxc_target — the default interaction mechanism.
---
--- Essentially all ordinary gameplay goes through this resource: look at a
--- thing, see what you can do with it, choose one. Entity, model, bone,
--- network-entity, and zone targets, with filters, dynamic labels, and
--- availability callbacks.
---
--- **A VISIBLE OPTION IS NOT AN AUTHORISED ONE.** This is the single rule the
--- whole resource is shaped around, and RSK-17 exists because it is so easy to
--- forget.
---
--- Everything that decides what a player SEES runs on their own machine. The
--- raycast, the distance check, the `canInteract` callback, the item check — all
--- of it is client-side, all of it is a rendering decision, and all of it can be
--- bypassed by anyone who can reach the game's Lua state. A player can invoke an
--- option that was never drawn for them, on an entity they are nowhere near,
--- while holding none of the items it asked for.
---
--- So the client half answers "what should I draw" and the server half answers
--- "may this happen", and the second never trusts the first. They look like the
--- same check written twice. They are not: one is a menu and the other is a
--- gate.

NxcTarget = NxcTarget or {}

NxcTarget.RESOURCE = 'nxc_target'

NxcTarget.VERSION = (type(GetResourceMetadata) == 'function'
    and GetResourceMetadata(GetCurrentResourceName(), 'version', 0))
    or '0.0.0-test'

NxcTarget.CONTRACT_VERSION = 1

return NxcTarget
