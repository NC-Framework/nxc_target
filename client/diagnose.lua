--- `/nxc_target_debug` — what this client actually sees.
---
--- **THIS EXISTS BECAUSE TWO GUESSES WERE WRONG.** "Holding the key does
--- nothing" was diagnosed twice from reading code — first as a validation
--- collision that stopped options reaching the client, then as an asynchronous
--- raycast returning a pending result. Both were real. Neither was findable from
--- the server, and the second was only found by reading the same file again.
---
--- Every question that took a round trip is answered here in one line:
---
---   is the keybind firing            targeting: yes/no
---   did any option arrive            registry: n
---   is the ray hitting anything      hit: entity, kind, model, distance
---   do any options apply to it       candidates: n, and which
---   if none apply, which filter      the reason each one was rejected
---
--- The last is the one worth having. A candidate rejected for distance and a
--- candidate rejected for a capability look identical from outside.

if IsDuplicityVersion() then return end

local function report(text)
    TriggerEvent('chat:addMessage', { args = { text } })
    print(('[nxc_target] %s'):format(text))
end

RegisterCommand('nxc_target_debug', function()
    local registry = NxcTarget.Runtime.registry()

    report(('^5[nxc_target]^7 v%s'):format(NxcTarget.VERSION))
    report(('  targeting active   %s'):format(tostring(NxcTarget.Runtime.isActive())))
    report(('  options known      %d'):format(registry.count))

    if registry.count == 0 then
        -- The commonest cause, and the one with the least to go on. Nothing
        -- arrived, so nothing can possibly appear.
        report('  ^3nothing has registered with this client^7')
        report('    the server broadcasts on registration and answers a snapshot')
        report('    request at startup. Check nxc_target_status on the console.')
        return
    end

    -- What is under the crosshair right now, whether or not the key is held.
    local hit = NxcTarget.Raycast.aim()
    if not hit then
        report('  ^3the ray hit nothing^7 — point at something solid and run this again')
        return
    end

    report(('  looking at         %s (model %s) at %.2fm')
        :format(hit.kind, tostring(hit.model), hit.distance))
    report(('  network id         %s'):format(tostring(hit.netId)))

    local zones = {}
    if GetResourceState('nxc_zones') == 'started' then
        local ok, active = pcall(function() return exports.nxc_zones:activeZones() end)
        if ok and type(active) == 'table' then
            for _, id in ipairs(active) do zones[id] = true end
        end
    end

    local candidates = NxcTarget.Registry.candidates(registry, {
        model = hit.model, netId = hit.netId, entity = hit.entity,
        kind = hit.kind, zones = zones,
    })

    report(('  candidates         %d of %d options could apply')
        :format(#candidates, registry.count))

    if #candidates == 0 then
        report('    ^3none is attached to this kind of thing^7')
        return
    end

    -- Each candidate, and the filter that rejected it. This is the line that
    -- turns "the option is missing" into something actionable.
    local context = {
        distance = hit.distance, entity = hit.entity, kind = hit.kind,
        model = hit.model, bone = hit.bone, zones = zones,
        capabilities = {}, items = {},
    }

    for _, option in ipairs(candidates) do
        local shown, why = NxcTarget.Filters.applies(option, context)
        if shown then
            report(('    ^2shown^7    %s'):format(option.key))
        else
            report(('    ^3hidden^7   %s — %s'):format(option.key, tostring(why)))
        end
    end
end, false)

return true
