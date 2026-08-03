--- The client half: hold a key, see what you can do, choose one.
---
--- **NOTHING DECIDED HERE HAS ANY AUTHORITY.** Every filter run in this file
--- answers "should this be drawn". The server re-checks what it can before
--- anything happens, and a player who bypasses all of this gains the ability to
--- see a menu, not the ability to act on it.
---
--- Which is why the code is allowed to be optimistic: `canInteract` runs here,
--- labels are computed here, and none of it is a security decision.

if IsDuplicityVersion() then return end

local Runtime = {}

local registry = NxcTarget.Registry.new()
local activeOptions = nil
local targeting = false

--- Everything the client knows about its own situation.
---
--- Assembled once per resolution rather than per option, because a hundred
--- options asking the same six questions is a hundred native calls for one
--- answer.
local function localContext(hit)
    local zones = {}
    if GetResourceState('nxc_zones') == 'started' then
        local ok, active = pcall(function() return exports.nxc_zones:activeZones() end)
        if ok and type(active) == 'table' then
            for _, id in ipairs(active) do zones[id] = true end
        end
    end

    return {
        distance = hit.distance,
        entity = hit.entity,
        kind = hit.kind,
        model = hit.model,
        bone = hit.bone,
        zones = zones,
        -- Capabilities and items are DISPLAY inputs here. They come from
        -- whatever the client has been told, and the server never believes them.
        capabilities = Runtime.capabilities or {},
        items = Runtime.items or {},
    }
end

--- What the player could do to what they are looking at.
---
---@param hit table
---@return table
function Runtime.resolve(hit)
    local context = localContext(hit)

    local candidates = NxcTarget.Registry.candidates(registry, {
        model = hit.model,
        netId = hit.netId,
        entity = hit.entity,
        kind = hit.kind,
        zones = context.zones,
    })

    local out = {}
    for _, option in ipairs(candidates) do
        if NxcTarget.Filters.applies(option, context) then
            -- A label may be a function so it can reflect state — "Lock" or
            -- "Unlock" on one option. Computed here, where it is a display
            -- concern and nothing more.
            local label = option.label
            if type(label) == 'function' then
                local ok, computed = pcall(label, context)
                label = ok and computed or nil
            end
            if type(label) == 'string' and label ~= '' then
                out[#out + 1] = { key = option.key, label = label, icon = option.icon }
            end
        end
    end
    return out
end

--- Show the menu for what is under the crosshair.
local function present()
    local hit = NxcTarget.Raycast.aim()
    if not hit then
        activeOptions = nil
        return
    end

    local options = Runtime.resolve(hit)
    if #options == 0 then
        activeOptions = nil
        return
    end

    activeOptions = { hit = hit, options = options }

    -- Drawn by nxc_ui, which owns the single browser instance. A resource
    -- opening its own NUI is a second browser in the game client, which
    -- directive 19 forbids and which would fight this one for focus.
    if GetResourceState('nxc_ui') == 'started' then
        local items = {}
        for index, option in ipairs(options) do
            items[index] = { id = option.key, label = option.label, icon = option.icon }
        end
        pcall(function()
            exports.nxc_ui:show({
                type = 'contextMenu', surface = 'nxc_target',
                title = 'Interact', items = items,
            })
        end)
    end
end

--- The player chose something.
---
--- **THE CLIENT SENDS A KEY AND A NETWORK ID, AND NOTHING ELSE THAT MATTERS.**
--- No distance, no capability, no coordinate: the server resolves and measures
--- all of it. Sending them would only invite a future maintainer to read them.
---
---@param key string
function Runtime.select(key)
    local current = activeOptions
    activeOptions = nil

    if not current then return end

    -- The key must be one just offered. This is a sanity check against a stale
    -- menu rather than a security control — the server checks properly, and a
    -- modified client can send anything regardless.
    local offered = false
    for _, option in ipairs(current.options) do
        if option.key == key then offered = true break end
    end
    if not offered then return end

    local option = NxcTarget.Registry.get(registry, key)

    -- A purely client-side option never reaches the server.
    if option and (option.clientEvent or option.onSelect) and not option.serverEvent then
        if option.onSelect then pcall(option.onSelect, current.hit) end
        if option.clientEvent then pcall(TriggerEvent, option.clientEvent, current.hit) end
        return
    end

    TriggerServerEvent('nxc_target:server:select', {
        key = key,
        netId = current.hit.netId,
    })
end

--- Turn targeting on or off.
---
--- The raycast thread exists only while targeting is active. A trace every frame
--- for a player who is not interacting is the waste this resource is written to
--- avoid, in a smaller package.
function Runtime.setActive(active)
    active = active and true or false
    if active == targeting then return end
    targeting = active

    if not targeting then
        activeOptions = nil
        if GetResourceState('nxc_ui') == 'started' then
            pcall(function() exports.nxc_ui:close() end)
        end
        return
    end

    CreateThread(function()
        while targeting do
            local ok, err = pcall(present)
            if not ok then
                Nxc.Logger.error('target.present_failed', { reason = tostring(err) })
            end
            -- Not every frame. A target under a crosshair does not change
            -- meaningfully at 60Hz, and the menu redrawing that often is a
            -- flicker rather than a feature.
            Wait(150)
        end
    end)
end

---@return boolean
function Runtime.isActive() return targeting end

---@return table
function Runtime.registry() return registry end

--- Register a client-side option.
---
--- Display and client-side actions only. An option arriving here CANNOT carry a
--- server action: the server dispatches from its own registry, so a serverEvent
--- declared client-side would never be honoured, and accepting one silently
--- would let an author believe they had built a server-checked action.
---
---@param option table
---@param owner string
---@return NxcResult
function Runtime.register(option, owner)
    if option and option.serverEvent then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = { {
            field = 'serverEvent',
            reason = 'register an option with a server action on the SERVER. '
                  .. 'The server dispatches from its own registry, so this one '
                  .. 'would never run and you would think it was guarded',
        } } }))
    end
    return NxcTarget.Registry.add(registry, option, owner)
end

RegisterNetEvent('nxc_target:client:register', function(option)
    -- Owned by nxc_target on this side: the registering resource may not run on
    -- the client at all, and an option attributed to one that never stops here
    -- would never be cleaned up.
    --
    -- These arrive with serverEvent stripped, so they cannot be dispatched
    -- locally. Selecting one sends its key to the server, which is the point.
    NxcTarget.Registry.add(registry, option, NxcTarget.RESOURCE)
end)

RegisterNetEvent('nxc_target:client:snapshot', function(options)
    if type(options) ~= 'table' then return end
    for _, option in ipairs(options) do
        NxcTarget.Registry.add(registry, option, NxcTarget.RESOURCE)
    end
end)

RegisterNetEvent('nxc_target:client:removeOwner', function(owner)
    NxcTarget.Registry.removeOwner(registry, owner)
end)

AddEventHandler('onClientResourceStop', function(resource)
    local removed = NxcTarget.Registry.removeOwner(registry, resource)
    if removed > 0 then
        Nxc.Logger.info('target.owner_stopped', { stoppedResource = resource, removed = removed })
        activeOptions = nil
    end
end)

CreateThread(function()
    Wait(1500)
    TriggerServerEvent('nxc_target:server:requestSnapshot')
end)

exports('register', function(option)
    local owner = GetInvokingResource() or NxcTarget.RESOURCE
    return Nxc.plain(Runtime.register(option, owner))
end)

exports('remove', function(key) return NxcTarget.Registry.remove(registry, key) end)

exports('isActive', function() return Runtime.isActive() end)

NxcTarget.Runtime = Runtime
return Runtime
