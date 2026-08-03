--- Holding the key, and choosing from the menu.
---
--- **A KEYBIND, NOT A HARDCODED CONTROL.** `RegisterKeyMapping` puts the binding
--- in the game's own settings screen, so a player can change it, see it
--- alongside every other binding, and use a controller. Reading a raw control
--- index instead would work and would be invisible and unchangeable, which
--- RSK-12 is about: interaction that cannot be discovered is interaction that
--- does not exist.

if IsDuplicityVersion() then return end

local Input = {}

--- The default binding.
---
--- LALT is the convention players arriving from other servers already have in
--- their hands. Discoverability beats originality for the one control that
--- reveals every other interaction in the game.
local DEFAULT_KEY = 'LMENU'

RegisterCommand('+nxcTarget', function()
    NxcTarget.Runtime.setActive(true)
end, false)

RegisterCommand('-nxcTarget', function()
    NxcTarget.Runtime.setActive(false)
end, false)

RegisterKeyMapping('+nxcTarget', 'Interact with what you are looking at',
    'keyboard', DEFAULT_KEY)

--- The menu answering.
---
--- Arrives through nxc_ui's callback, which validated the shape on both sides
--- before it got here. What it carries is an option key, and the key is checked
--- against what was actually offered before anything is sent.
--- Registered unconditionally.
---
--- It was guarded on nxc_ui's resource state at load, which is a failure mode
--- rather than a saving: registering a handler costs nothing, and the guard
--- meant that if nxc_ui happened not to be started at the instant this file
--- loaded, clicking a menu item would silently do nothing forever.
AddEventHandler('nxc_ui:client:selected', function(surface, response)
    if surface ~= 'nxc_target' then return end
    -- The response carries the action and the chosen item. nxc_ui validated its
    -- shape on both sides before it reached here.
    NxcTarget.Runtime.select(response and response.itemId)
end)

--- Release targeting when the player loses control of it.
---
--- Death, and any other state where holding a key should stop meaning what it
--- meant. Without this, dying mid-target leaves the menu open over the respawn
--- screen and the raycast thread running against a corpse.
CreateThread(function()
    while true do
        if NxcTarget.Runtime.isActive() and IsPedFatallyInjured(PlayerPedId()) then
            NxcTarget.Runtime.setActive(false)
        end
        -- Only while targeting is on. Polling a dead-check every frame for a
        -- player standing still is exactly the cost this resource avoids
        -- everywhere else.
        Wait(NxcTarget.Runtime.isActive() and 250 or 1000)
    end
end)

NxcTarget.Input = Input
return Input
