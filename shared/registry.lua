--- The option registry: what is registered, indexed by what it attaches to.
---
--- **OPTION IDS ARE NAMESPACED BY OWNER.** Two resources both registering
--- `open` must not collide, and more importantly a resource must not be able to
--- overwrite or invoke another's option by guessing its id. The stored key is
--- `owner:id`, and that is also what crosses the wire when a player selects
--- something — so the server can tell which resource an incoming selection is
--- addressed to without believing the payload about it.
---
--- Indexed by attachment because the client resolves options on every raycast
--- hit. Walking every registered option per frame to find the two that apply to
--- a door is the version of this resource that gets removed from servers.

local Registry = {}

---@return table
function Registry.new()
    return {
        byKey = {},
        byOwner = {},
        byModel = {},
        byNetId = {},
        byEntity = {},
        byZone = {},
        byGlobal = {},
        count = 0,
    }
end

--- The wire identity of an option.
---
--- Owner and id together. A selection naming `nxc_doors:open` can only ever
--- reach an option nxc_doors registered, whatever the sender intended.
---
---@param owner string
---@param id string
---@return string
function Registry.key(owner, id) return owner .. ':' .. id end

local function indexFor(registry, option)
    if option.global then return registry.byGlobal, { option.global } end
    if option.models then return registry.byModel, option.models end
    if option.netIds then return registry.byNetId, option.netIds end
    if option.entities then return registry.byEntity, option.entities end
    if option.zones then return registry.byZone, option.zones end
    return nil, nil
end

--- Register an option.
---
---@param registry table
---@param option table
---@param owner string
---@return NxcResult
function Registry.add(registry, option, owner)
    if type(owner) ~= 'string' or owner == '' then
        return Nxc.Result.err(Nxc.Errors.validationFailed({ fields = {
            { field = 'owner', reason = 'an option must belong to a resource' },
        } }))
    end

    local valid = NxcTarget.Options.validate(option)
    if not valid.ok then return valid end

    local stored = {}
    for key, value in pairs(option) do stored[key] = value end
    stored.owner = owner
    stored.key = Registry.key(owner, option.id)

    if registry.byKey[stored.key] then
        Registry.remove(registry, stored.key)
    end

    registry.byKey[stored.key] = stored
    registry.byOwner[owner] = registry.byOwner[owner] or {}
    registry.byOwner[owner][stored.key] = true

    local index, keys = indexFor(registry, stored)
    if index then
        for _, value in ipairs(keys) do
            index[value] = index[value] or {}
            index[value][stored.key] = true
        end
    end

    registry.count = registry.count + 1
    return Nxc.Result.ok({ key = stored.key, advisory = valid.value.advisory })
end

---@param registry table
---@param key string
---@return boolean
function Registry.remove(registry, key)
    local option = registry.byKey[key]
    if not option then return false end

    registry.byKey[key] = nil

    local owned = registry.byOwner[option.owner]
    if owned then
        owned[key] = nil
        if next(owned) == nil then registry.byOwner[option.owner] = nil end
    end

    local index, keys = indexFor(registry, option)
    if index then
        for _, value in ipairs(keys) do
            local bucket = index[value]
            if bucket then
                bucket[key] = nil
                if next(bucket) == nil then index[value] = nil end
            end
        end
    end

    registry.count = registry.count - 1
    return true
end

--- Remove everything a resource registered.
---
--- Same reasoning as nxc_zones: a resource that crashed or reloaded never runs
--- its own cleanup. Options that outlive their owner offer players actions that
--- dispatch to a resource which is not there, and the failure is silent.
---
---@param registry table
---@param owner string
---@return number
function Registry.removeOwner(registry, owner)
    local owned = registry.byOwner[owner]
    if not owned then return 0 end

    local keys = {}
    for key in pairs(owned) do keys[#keys + 1] = key end

    local removed = 0
    for _, key in ipairs(keys) do
        if Registry.remove(registry, key) then removed = removed + 1 end
    end
    return removed
end

---@param registry table
---@param key string
---@return table|nil
function Registry.get(registry, key) return registry.byKey[key] end

--- Every option that could possibly apply to what the player is looking at.
---
--- Candidates, not answers: the caller still runs the filters. This narrows the
--- set from "everything registered" to "everything attached to this model, this
--- entity, this zone, or every entity of this kind", which is the difference
--- between a table lookup and a full scan on each frame.
---
--- Deduplicated by key, because an option attached to a model the player is also
--- inside a zone for must appear once.
---
---@param registry table
---@param query table  { model, netId, entity, kind, zones }
---@return table
function Registry.candidates(registry, query)
    query = query or {}
    local seen = {}
    local out = {}

    local function collect(bucket)
        if not bucket then return end
        for key in pairs(bucket) do
            if not seen[key] then
                local option = registry.byKey[key]
                if option then
                    seen[key] = true
                    out[#out + 1] = option
                end
            end
        end
    end

    if query.model then collect(registry.byModel[query.model]) end
    if query.netId then collect(registry.byNetId[query.netId]) end
    if query.entity then collect(registry.byEntity[query.entity]) end
    if query.kind then collect(registry.byGlobal[query.kind]) end
    if query.zones then
        for zone in pairs(query.zones) do collect(registry.byZone[zone]) end
    end

    -- Stable order, so the same situation always presents the same menu. An
    -- option that moves between second and third place depending on hash order
    -- makes muscle memory impossible.
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

NxcTarget.Registry = Registry
return Registry
