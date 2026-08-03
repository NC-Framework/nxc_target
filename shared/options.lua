--- What a target option is, and what makes one valid.
---
--- An option is a thing a player can do to something they are looking at. It
--- says what it applies to, what has to be true for it to appear, and what
--- happens when it is chosen.
---
--- **THE THREE FIELDS THAT DECIDE AUTHORITY ARE SEPARATED FROM THE REST ON
--- PURPOSE.** `capability`, `item`, and `distance` are re-checked by the server
--- before anything runs. `canInteract` is not, and cannot be — it is a function
--- living in a client's Lua state, so its answer is whatever that client says it
--- is. Options declaring only `canInteract` are display filters wearing the
--- clothes of a permission check, which is exactly how RSK-17 materialises.
---
--- The validator says so out loud: an option with a server action and no
--- server-checkable filter is accepted and REPORTED, because refusing it would
--- be wrong (plenty of actions are genuinely open to everyone) and staying quiet
--- about it would be worse.

local Options = {}

--- What an option can be attached to.
Options.TARGET = {
    ENTITY  = 'entity',   -- a specific handle, client-side only
    NET_ID  = 'netId',    -- a networked entity, meaningful to the server
    MODEL   = 'model',    -- every entity of a model
    ZONE    = 'zone',     -- an nxc_zones zone
    GLOBAL  = 'global',   -- every ped, vehicle, object, or player
}

Options.GLOBAL_KIND = {
    PLAYER  = 'player',
    PED     = 'ped',
    VEHICLE = 'vehicle',
    OBJECT  = 'object',
}

--- The furthest an option may ever be interacted from.
---
--- A ceiling rather than a default. The default is short because interaction is
--- meant to be up close; the ceiling exists because an option with a hundred
--- metre reach is not a target, it is a remote control, and the server has to
--- re-check distance against SOMETHING.
Options.DEFAULT_DISTANCE = 2.5
Options.MAX_DISTANCE = 15.0

local function problem(field, reason)
    return { field = field, reason = reason }
end

--- Does this option have anything the SERVER can check?
---
--- `canInteract` deliberately does not count. It runs on the player's machine.
---
---@param option table
---@return boolean
function Options.hasServerCheckableFilter(option)
    return option.capability ~= nil or option.item ~= nil
end

--- Validate an option.
---
---@param option table
---@return NxcResult
function Options.validate(option)
    if type(option) ~= 'table' then
        return Nxc.Result.err(Nxc.Errors.validationFailed(
            { fields = { problem('option', 'must be a table') } }))
    end

    local problems = {}

    if type(option.id) ~= 'string' or option.id == '' then
        problems[#problems + 1] = problem('id', 'is required')
    end

    -- A label may be a string or a function computing one. A function is how a
    -- label reflects state — "Lock" or "Unlock" on the same option — and it is
    -- a display concern, so it is allowed to be client-side.
    local labelType = type(option.label)
    if labelType ~= 'string' and labelType ~= 'function' then
        problems[#problems + 1] = problem('label', 'must be a string or a function')
    elseif labelType == 'string' and option.label == '' then
        problems[#problems + 1] = problem('label', 'a player has to be able to read it')
    end

    if option.distance ~= nil then
        if type(option.distance) ~= 'number' or option.distance ~= option.distance then
            problems[#problems + 1] = problem('distance', 'must be a number')
        elseif option.distance <= 0 then
            problems[#problems + 1] = problem('distance', 'must be greater than zero')
        elseif option.distance > Options.MAX_DISTANCE then
            problems[#problems + 1] = problem('distance',
                ('at most %.1f; further than that is a remote control rather than a target')
                    :format(Options.MAX_DISTANCE))
        end
    end

    -- What it attaches to. Exactly one attachment style, because an option that
    -- is both "every vehicle" and "this one entity" has no meaningful answer for
    -- which distance or which filters apply.
    local attachments = 0
    for _, field in ipairs({ 'entities', 'netIds', 'models', 'zones' }) do
        if option[field] ~= nil then
            attachments = attachments + 1
            if type(option[field]) ~= 'table' or #option[field] == 0 then
                problems[#problems + 1] = problem(field, 'must be a non-empty list')
            end
        end
    end
    if option.global ~= nil then
        attachments = attachments + 1
        local known = false
        for _, kind in pairs(Options.GLOBAL_KIND) do
            if kind == option.global then known = true break end
        end
        if not known then
            problems[#problems + 1] = problem('global',
                ('unknown global kind: %s'):format(tostring(option.global)))
        end
    end

    if attachments == 0 then
        problems[#problems + 1] = problem('option',
            'must attach to entities, netIds, models, zones, or a global kind')
    elseif attachments > 1 then
        problems[#problems + 1] = problem('option',
            'attaches to more than one kind of thing; register one option per kind')
    end

    if option.bones ~= nil then
        if type(option.bones) ~= 'table' or #option.bones == 0 then
            problems[#problems + 1] = problem('bones', 'must be a non-empty list')
        elseif option.models == nil and option.entities == nil and option.netIds == nil then
            -- A bone belongs to a model. Attaching one to "every vehicle in the
            -- world" is meaningless, and it silently never matches.
            problems[#problems + 1] = problem('bones',
                'bones need an entity or model to belong to')
        end
    end

    -- What happens when it is chosen.
    local actions = 0
    for _, field in ipairs({ 'serverEvent', 'clientEvent', 'onSelect' }) do
        if option[field] ~= nil then
            actions = actions + 1
            local expected = field == 'onSelect' and 'function' or 'string'
            if type(option[field]) ~= expected then
                problems[#problems + 1] = problem(field, 'must be a ' .. expected)
            end
        end
    end
    if actions == 0 then
        problems[#problems + 1] = problem('option', 'must do something when selected')
    end

    if option.canInteract ~= nil and type(option.canInteract) ~= 'function' then
        problems[#problems + 1] = problem('canInteract', 'must be a function')
    end
    if option.capability ~= nil and type(option.capability) ~= 'string' then
        problems[#problems + 1] = problem('capability', 'must be a capability name')
    end
    if option.item ~= nil and type(option.item) ~= 'string' then
        problems[#problems + 1] = problem('item', 'must be an item name')
    end

    if #problems > 0 then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = problems }))
    end

    -- Accepted, with a note when nothing about it can be checked server-side.
    --
    -- NOT a refusal. Plenty of actions are genuinely open to anyone standing in
    -- front of the thing — opening an unlocked door, reading a notice board —
    -- and demanding a capability for those would push authors to invent
    -- meaningless ones, which is worse than none.
    local advisory = nil
    if option.serverEvent and not Options.hasServerCheckableFilter(option) then
        advisory = 'this option runs a server event and declares no capability or item, '
                .. 'so the server cannot check anything about it except distance. '
                .. 'If that is intended it is fine; if it is guarded only by canInteract, '
                .. 'it is guarded by the player'
    end

    return Nxc.Result.ok({ option = option, advisory = advisory })
end

--- The distance an option actually uses.
---
---@param option table
---@return number
function Options.distanceOf(option)
    local distance = option.distance or Options.DEFAULT_DISTANCE
    if distance > Options.MAX_DISTANCE then return Options.MAX_DISTANCE end
    return distance
end

NxcTarget.Options = Options
return Options
