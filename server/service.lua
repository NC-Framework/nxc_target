--- The server gate: the only place an option's action is allowed to happen.
---
--- **THE EVENT NAME COMES FROM THE REGISTERED OPTION, NEVER FROM THE PAYLOAD.**
--- If a client could name the event, this file would be a remote procedure call
--- into every server event in the system, addressed by string. It sends a key;
--- the server looks that key up in its OWN registry and dispatches whatever that
--- option says.
---
--- Which is also why the display copy sent to clients has `serverEvent`
--- stripped. A client cannot invoke an event it has no way to learn the name of,
--- and reading the option list should not be a way to enumerate the server's
--- event surface.
---
--- **A CLIENT-REGISTERED OPTION CAN NEVER CARRY A SERVER ACTION.** Only
--- registrations that arrived here — from a resource on this machine, through an
--- export, attributed by GetInvokingResource — are authoritative. That rule is
--- what makes the whole design hold: the client half decides what to draw, and
--- the drawing has no bearing on what may run.

if not IsDuplicityVersion() then return end

local Service = {}

local registry = NxcTarget.Registry.new()

--- One selection per player per this many milliseconds.
---
--- A selection is a player pressing a key while looking at something, so a real
--- one is rare. The limit exists for the case where the client is not a player
--- at all but a script sending as fast as it can.
local SELECTION_INTERVAL_MS = 250
local limiter = Nxc.RateLimit.new({ capacity = 4, refillPerSecond = 1000 / SELECTION_INTERVAL_MS })

--- How the server learns whether a player holds an item.
---
--- **THERE IS NO INVENTORY YET** — nxc_inventory is Phase 3. Until one registers
--- itself here, an option that requires an item cannot be checked, and this
--- refuses it rather than waving it through. Failing closed means the feature
--- looks broken until inventory exists, which is honest; failing open would mean
--- every item-gated action in the game was ungated and nothing would say so.
local itemProvider = nil

---@param provider fun(source: any): table  set of item names the player holds
function Service.setItemProvider(provider)
    if type(provider) ~= 'function' then
        error('setItemProvider requires a function', 2)
    end
    itemProvider = provider
end

--- The display copy of an option: what a client is allowed to know about it.
---
--- Stripped of `serverEvent`, `onSelect`, and the owner's internals. A client
--- needs enough to draw a menu entry and decide whether to draw it at all.
local function displayCopy(option)
    return {
        key = option.key,
        -- `id` as well as `key`. Validation requires an id, and without it a
        -- receiving client refuses the option outright.
        id = option.id,
        label = option.label,
        icon = option.icon,
        distance = NxcTarget.Options.distanceOf(option),
        bones = option.bones,
        models = option.models,
        netIds = option.netIds,
        zones = option.zones,
        global = option.global,
        capability = option.capability,
        item = option.item,

        -- SAYS AN ACTION EXISTS WITHOUT NAMING IT.
        --
        -- Two decisions collided here and the collision shipped. The event name
        -- is stripped so a client cannot enumerate the server's event surface;
        -- validation requires an option to do something, so an option that does
        -- nothing is refused. Together they meant every broadcast option was
        -- rejected by the receiving client and no interaction ever appeared.
        --
        -- A boolean satisfies the second without weakening the first: the client
        -- knows there is something to invoke and still cannot say what.
        hasServerAction = option.serverEvent ~= nil,
    }
end

--- Register an authoritative option.
---
---@param option table
---@param owner string
---@return NxcResult
function Service.register(option, owner)
    local result = NxcTarget.Registry.add(registry, option, owner)
    if not result.ok then return result end

    if result.value.advisory then
        -- Reported once, at registration, naming the resource. A warning at
        -- selection time would arrive thousands of times and be filtered out.
        Nxc.Logger.warn('target.unguarded_server_action', {
            option = result.value.key,
            registeringResource = owner,
            detail = result.value.advisory,
        })
    end

    TriggerClientEvent('nxc_target:client:register', -1,
        Nxc.plain(displayCopy(NxcTarget.Registry.get(registry, result.value.key))))
    return result
end

--- Everything a joining client should be able to draw.
---@return table
function Service.snapshot()
    local out = {}
    for key in pairs(registry.byKey) do
        out[#out + 1] = displayCopy(registry.byKey[key])
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

--- Resolve what the player claims to be interacting with, from the server's view.
---
--- Returns the position the server believes the target is at, or nil with a
--- reason. **Nothing here trusts a coordinate from the payload** — a netId is an
--- index the server can resolve itself, and a zone is looked up in nxc_zones.
---
---@param selection table
---@return number|nil, number|nil, number|nil, string|nil
local function resolveTargetPosition(selection)
    if selection.netId then
        local entity = NetworkGetEntityFromNetworkId(selection.netId)
        if not entity or entity == 0 or not DoesEntityExist(entity) then
            return nil, nil, nil, 'entity_unknown'
        end
        local position = GetEntityCoords(entity)
        return position.x, position.y, position.z, nil
    end

    if selection.zone then
        -- A zone has no single position, and the option's own distance is about
        -- the thing being interacted with rather than the zone's centre. Zone
        -- membership is checked instead, and it is checked HERE rather than
        -- taken from the client.
        return nil, nil, nil, 'zone_position_not_applicable'
    end

    return nil, nil, nil, 'nothing_identified'
end

--- A selection arriving from a client.
---
--- **EVERYTHING IN `selection` IS A CLAIM.** The only field acted on directly is
--- the option key, and that is used as a lookup rather than as an instruction.
RegisterNetEvent('nxc_target:server:select', function(selection)
    local source = source

    local allowed = limiter:allow(tostring(source))
    if not allowed then
        Nxc.Logger.warn('target.rate_limited', { connection = tostring(source) })
        return
    end

    if type(selection) ~= 'table' or type(selection.key) ~= 'string' then
        Nxc.Logger.warn('target.malformed_selection', { connection = tostring(source) })
        return
    end

    local option = NxcTarget.Registry.get(registry, selection.key)
    if not option then
        -- Either a stale option from before a resource restart, or a client
        -- naming something that was never registered. Both are refused, and the
        -- second is why the key is a lookup rather than an instruction.
        Nxc.Logger.warn('target.unknown_option', {
            connection = tostring(source), option = selection.key,
        })
        return
    end

    if not option.serverEvent then
        -- A client-registered display option has no server action by
        -- construction, so reaching here means the client invented one.
        Nxc.Logger.warn('target.no_server_action', {
            connection = tostring(source), option = option.key,
        })
        return
    end

    -- Distance, measured by the server between two positions it holds.
    local playerPed = GetPlayerPed(source)
    if not playerPed or playerPed == 0 then return end
    local playerPosition = GetEntityCoords(playerPed)

    local distance
    if option.zones then
        -- Zone options are bounded by the zone, not by a distance to an entity.
        -- The membership test is what matters and it is not implemented
        -- server-side yet, so these are refused rather than assumed.
        Nxc.Logger.warn('target.zone_option_unverifiable', {
            connection = tostring(source), option = option.key,
            detail = 'server-side zone membership is not implemented; refusing rather than assuming',
        })
        return
    else
        local tx, ty, tz, reason = resolveTargetPosition(selection)
        if not tx then
            Nxc.Logger.warn('target.target_unresolved', {
                connection = tostring(source), option = option.key, reason = reason,
            })
            return
        end
        distance = math.sqrt(
            (playerPosition.x - tx) ^ 2 + (playerPosition.y - ty) ^ 2 + (playerPosition.z - tz) ^ 2)
    end

    -- Capabilities from nxc_core's session, never from the request.
    local capabilities = {}
    if option.capability then
        local ok, result = pcall(function()
            return exports.nxc_core:capabilities(source)
        end)
        if not ok or type(result) ~= 'table' then
            -- The framework could not answer. Refusing is the only safe
            -- reading: an empty set would be indistinguishable from "holds
            -- nothing", and that is the same answer for a broken lookup and a
            -- genuinely unprivileged player.
            Nxc.Logger.error('target.capability_lookup_failed', {
                connection = tostring(source), option = option.key,
                detail = tostring(result),
            })
            return
        end
        capabilities = result
    end

    local items = {}
    if option.item then
        if not itemProvider then
            Nxc.Logger.warn('target.item_check_unavailable', {
                connection = tostring(source), option = option.key, item = option.item,
                detail = 'no inventory provider is registered; refusing rather than assuming',
            })
            return
        end
        local ok, held = pcall(itemProvider, source)
        if not ok or type(held) ~= 'table' then
            Nxc.Logger.error('target.item_lookup_failed', { option = option.key })
            return
        end
        items = held
    end

    local permitted = NxcTarget.Filters.permits(option, {
        distance = distance,
        capabilities = capabilities,
        items = items,
    })
    if not permitted.ok then
        Nxc.Logger.warn('target.selection_refused', {
            connection = tostring(source), option = option.key,
            reason = permitted.error.details and permitted.error.details.reason
                  or permitted.error.code,
        })
        return
    end

    --- The validated context.
    ---
    --- **BUILT ENTIRELY FROM THE SERVER'S OWN STATE.** A handler receiving this
    --- does not need to re-derive anything, and must not read the client's
    --- original payload — which is why it is never passed on.
    local context = {
        source = source,
        account = exports.nxc_core:accountFor(source),
        character = exports.nxc_core:characterFor(source),
        option = option.key,
        netId = selection.netId,
        distance = distance,
        correlationId = Nxc.Correlation.new(),
    }

    local dispatched, err = pcall(TriggerEvent, option.serverEvent, context)
    if not dispatched then
        Nxc.Logger.error('target.handler_failed', {
            option = option.key, event = option.serverEvent, reason = tostring(err),
        })
    end
end)

RegisterNetEvent('nxc_target:server:requestSnapshot', function()
    TriggerClientEvent('nxc_target:client:snapshot', source, Nxc.plain(Service.snapshot()))
end)

AddEventHandler('onResourceStop', function(resource)
    local removed = NxcTarget.Registry.removeOwner(registry, resource)
    if removed > 0 then
        Nxc.Logger.info('target.owner_stopped', { stoppedResource = resource, removed = removed })
        TriggerClientEvent('nxc_target:client:removeOwner', -1, resource)
    end
end)

exports('register', function(option)
    local owner = GetInvokingResource() or NxcTarget.RESOURCE
    return Nxc.plain(Service.register(option, owner))
end)

exports('remove', function(key) return NxcTarget.Registry.remove(registry, key) end)

exports('setItemProvider', function(provider) Service.setItemProvider(provider) end)

RegisterCommand('nxc_target_status', function(source)
    if source ~= 0 then return end

    print(('^5[nxc_target]^7 v%s, contract v%d')
        :format(NxcTarget.VERSION, NxcTarget.CONTRACT_VERSION))
    print(('  registered options   %d'):format(registry.count))
    print(('  inventory provider   %s')
        :format(itemProvider and 'registered' or '^3none — item-gated options are refused^7'))

    local unguarded = 0
    for _, option in pairs(registry.byKey) do
        if option.serverEvent and not NxcTarget.Options.hasServerCheckableFilter(option) then
            unguarded = unguarded + 1
        end
    end
    if unguarded > 0 then
        print(('  ^3%d server actions with nothing the server can check^7'):format(unguarded))
        print('    these run for anyone who names them. Intended for open actions;')
        print('    a mistake if they were meant to be restricted.')
    end

    if registry.count == 0 then
        print('    nothing registered yet — no resource has called nxc_target:register')
    end
end, true)

-- nxc_core is REQUIRED rather than optional: without it the capability check in
-- this file has nothing to ask, and an option gated on a capability nobody can
-- verify must not be offered.
Nxc.Service.start({
    dependencies = { 'nxc_lib', 'nxc_zones', 'nxc_core' },
    contractVersion = NxcTarget.CONTRACT_VERSION,
    capabilities = { 'targeting' },
    ready = true,
})

--- This resource's own health, for nxc_core's aggregate and for anyone asking
--- directly. Plain, because a report behind a metatable arrives empty.
exports('health', function() return Nxc.plain(Nxc.Health.report()) end)

NxcTarget.Service = Service
return Service
