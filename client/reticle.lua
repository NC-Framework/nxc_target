--- The crosshair shown while targeting.
---
--- **IT IS A DIAGNOSTIC AS MUCH AS AN AFFORDANCE.** Without it, "I held the key
--- and nothing happened" has three indistinguishable causes: the key is not
--- bound, the ray hit nothing, or the ray hit something with no options. The
--- colour separates them.
---
---   dim         targeting is on, the ray hit nothing
---   white       hit something, no options apply to it
---   highlighted hit something with options — let go, or click
---
--- That distinction is why this file exists at all. The first report of the
--- interaction system not working was exactly "LAlt on a person doesn't seem to
--- do anything", and there was no way to see which of the three it was.
---
--- Drawn at frame rate in its own thread, separate from the resolve loop, which
--- deliberately runs at 150ms. Running the resolver at frame rate to feed a
--- crosshair would make the crosshair change the thing it is measuring.

if IsDuplicityVersion() then return end

local Reticle = {}

--- A dot, not a cross.
---
--- GTA's world is busy and a thin cross disappears against it. A filled dot with
--- a dark outline stays visible over sky, snow, and headlights, which is the
--- same reason every game that ships one does this.
local SIZE = 0.0022          -- width in screen space
local ASPECT = 16.0 / 9.0    -- height is scaled, or the dot is an ellipse

local STATES = {
    idle      = { r = 220, g = 220, b = 220, a = 90 },
    nothing   = { r = 240, g = 240, b = 240, a = 170 },
    available = { r = 0,   g = 220, b = 255, a = 230 },
}

--- What the crosshair is currently saying.
---
--- Set by the resolve loop rather than computed here: this file draws, and the
--- thing that already knows what is under the crosshair tells it what to say.
local state = 'idle'

---@param name string  'idle', 'nothing', or 'available'
function Reticle.set(name)
    if STATES[name] then state = name end
end

local function draw()
    local colour = STATES[state] or STATES.idle

    -- Outline first, then the dot on top. Two rects rather than a texture,
    -- because a texture is an asset to ship and this is four numbers.
    DrawRect(0.5, 0.5, SIZE * 1.9, SIZE * ASPECT * 1.9, 0, 0, 0, 140)
    DrawRect(0.5, 0.5, SIZE, SIZE * ASPECT, colour.r, colour.g, colour.b, colour.a)
end

CreateThread(function()
    while true do
        if NxcTarget.Runtime and NxcTarget.Runtime.isActive() then
            draw()
            Wait(0)
        else
            -- Not drawing costs nothing. A per-frame thread that spends most of
            -- the session doing nothing is the waste this resource avoids
            -- everywhere else.
            state = 'idle'
            Wait(200)
        end
    end
end)

NxcTarget.Reticle = Reticle
return Reticle
