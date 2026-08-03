--- Which options apply, and — separately — which are permitted.
---
--- **THESE ARE TWO DIFFERENT QUESTIONS AND THIS FILE ANSWERS THEM WITH TWO
--- DIFFERENT FUNCTIONS.** That is the entire point of the module, and merging
--- them into one convenient `check` would undo it.
---
---   `applies`  — should this be DRAWN? Runs on the client. Its answer is a
---                rendering decision and carries no authority whatsoever.
---
---   `permits`  — may this HAPPEN? Runs on the server. Its answer decides
---                whether an action occurs, and it never consults anything the
---                client supplied.
---
--- They overlap: both look at distance and capability. That duplication is the
--- design, not an oversight. The client checks so the menu is honest; the server
--- checks because the client's answer is a claim made by a machine the player
--- controls.
---
--- The asymmetry to keep in mind: `applies` returning true means nothing at all
--- about whether the action is allowed. `permits` returning false means it does
--- not happen, whatever the player saw.

local Filters = {}

--- How much further than the declared distance the server will tolerate.
---
--- Not generosity. The client decided using a position a few frames old, and the
--- server measures against a newer one; without slack, a player walking away
--- while choosing gets a refusal that reads like a bug.
---
--- Kept small, because it is added to every option's reach.
Filters.DISTANCE_TOLERANCE = 1.5

--- Should this option be drawn?
---
--- Everything here is display logic and every input is local. `canInteract` is
--- called, which is why this function may never be reused server-side: a
--- resource's `canInteract` is written expecting client globals, and its answer
--- comes from the player's own machine.
---
---@param option table
---@param context table  { distance, entityKind, model, bone, zones, item, capabilities }
---@return boolean, string|nil  shown, and why not when hidden
function Filters.applies(option, context)
    context = context or {}

    local distance = context.distance or 0
    if distance > NxcTarget.Options.distanceOf(option) then
        return false, 'distance'
    end

    if option.bones and context.bone then
        local matched = false
        for _, bone in ipairs(option.bones) do
            if bone == context.bone then matched = true break end
        end
        if not matched then return false, 'bone' end
    elseif option.bones and not context.bone then
        return false, 'bone'
    end

    if option.zones then
        local inside = context.zones or {}
        local matched = false
        for _, zone in ipairs(option.zones) do
            if inside[zone] then matched = true break end
        end
        if not matched then return false, 'zone' end
    end

    -- Capability and item are checked here TOO, so the menu does not offer
    -- something that will be refused a moment later. Offering an action and then
    -- rejecting it is worse than never offering it, because the player has no
    -- way to tell a permission problem from a broken feature.
    if option.capability then
        local held = context.capabilities or {}
        if not held[option.capability] then return false, 'capability' end
    end

    if option.item then
        local carried = context.items or {}
        if not carried[option.item] then return false, 'item' end
    end

    if option.canInteract then
        local ok, allowed = pcall(option.canInteract, context)
        if not ok then
            -- A callback that errors hides its option. The alternative is
            -- showing an option whose availability is unknown, and a broken
            -- filter should fail closed.
            return false, 'canInteract errored'
        end
        if not allowed then return false, 'canInteract' end
    end

    return true, nil
end

--- May this option actually run?
---
--- **EVERY ARGUMENT COMES FROM THE SERVER'S OWN STATE.** Nothing here is taken
--- from the payload that asked for the action. The caller resolves the entity
--- from a network id it verifies, measures distance between two positions it
--- holds, and reads capabilities from the session rather than from the request.
---
--- `canInteract` is NOT called. It cannot be: it is a client function, it is not
--- present in this Lua state, and if it were its answer would still have come
--- from the player.
---
---@param option table
---@param context table  { distance, capabilities, items }
---@return NxcResult
function Filters.permits(option, context)
    context = context or {}

    -- Distance first: it is the check that exists whether or not an option
    -- declared anything, and the one an attacker is most likely to be violating.
    local allowed = NxcTarget.Options.distanceOf(option)
    local distance = context.distance
    if type(distance) ~= 'number' then
        return Nxc.Result.err(Nxc.Errors.new(Nxc.Errors.CODES.FORBIDDEN,
            'You are not permitted to do that.',
            { details = { reason = 'distance_unknown' } }))
    end
    -- A small tolerance, because the client acted on a position that is a few
    -- frames older than the one the server holds, and a player walking away
    -- mid-selection is ordinary rather than hostile.
    if distance > allowed + Filters.DISTANCE_TOLERANCE then
        return Nxc.Result.err(Nxc.Errors.new(Nxc.Errors.CODES.FORBIDDEN,
            'You are not permitted to do that.',
            { details = { reason = 'too_far', distance = distance, allowed = allowed } }))
    end

    if option.capability then
        local held = context.capabilities or {}
        if not held[option.capability] then
            return Nxc.Result.err(Nxc.Errors.forbidden(option.capability))
        end
    end

    if option.item then
        local carried = context.items or {}
        if not carried[option.item] then
            return Nxc.Result.err(Nxc.Errors.new(Nxc.Errors.CODES.FORBIDDEN,
                'You are not permitted to do that.',
                { details = { reason = 'missing_item', item = option.item } }))
        end
    end

    return Nxc.Result.ok(true)
end

NxcTarget.Filters = Filters
return Filters
