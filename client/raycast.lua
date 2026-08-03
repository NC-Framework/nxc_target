--- What the player is looking at.
---
--- The only file in the resource that casts a ray, and one of two that touch
--- natives at all.
---
--- **IT CASTS ONE RAY FROM THE CAMERA AND ENUMERATES NOTHING.** The obvious
--- alternative — walk every entity in the world, find the nearest one roughly in
--- front — is the version of this resource that gets removed from servers, and
--- it is what directive 25.5 forbids. A shape test along a line is a fixed cost
--- that does not grow with how busy the street is.
---
--- The ray is also only cast while targeting is ACTIVE. A raycast every frame
--- for a player who is not holding the key is the same waste in a smaller
--- package.

if IsDuplicityVersion() then return end

local Raycast = {}

--- How far ahead to look.
---
--- Slightly beyond the furthest option any resource may register, so a player
--- can see what is there before the option becomes available. Looking further
--- than that costs a longer trace and offers nothing.
Raycast.REACH = NxcTarget.Options.MAX_DISTANCE + 2.0

--- Which categories of thing the ray collides with.
---
--- Peds, vehicles, objects, and the world. The world is included so a wall
--- between the player and a target BLOCKS the target — without it, options are
--- offered through solid geometry, and that is both wrong and a way to interact
--- with the inside of a building from outside it.
local TRACE_FLAGS = 1 + 2 + 8 + 16

--- What is under the crosshair right now.
---
---@return table|nil  { entity, kind, model, bone, position, distance }
function Raycast.aim()
    local camera = GetGameplayCamCoord()
    local direction = Raycast.directionFromRotation(GetGameplayCamRot(2))

    local destination = {
        x = camera.x + direction.x * Raycast.REACH,
        y = camera.y + direction.y * Raycast.REACH,
        z = camera.z + direction.z * Raycast.REACH,
    }

    local player = PlayerPedId()
    local handle = StartShapeTestLosProbe(
        camera.x, camera.y, camera.z,
        destination.x, destination.y, destination.z,
        TRACE_FLAGS, player, 4)

    local _, hit, endCoords, _, entity = GetShapeTestResult(handle)
    if hit ~= 1 or not entity or entity == 0 then return nil end

    local playerPosition = GetEntityCoords(player)
    local distance = #(playerPosition - endCoords)

    return {
        entity = entity,
        kind = Raycast.kindOf(entity),
        model = GetEntityModel(entity),
        bone = nil,  -- resolved by the caller only when an option needs one
        position = endCoords,
        distance = distance,
        netId = NetworkGetEntityIsNetworked(entity)
            and NetworkGetNetworkIdFromEntity(entity) or nil,
    }
end

--- A unit direction from camera rotation in degrees.
---
--- Separated from `aim` so it is arithmetic rather than a native call, which
--- means it can be checked. Getting this wrong produces a ray that is subtly off
--- and a resource that "sometimes does not detect things".
---
---@param rotation table  { x = pitch, z = yaw } in degrees
---@return table
function Raycast.directionFromRotation(rotation)
    local pitch = math.rad(rotation.x)
    local yaw = math.rad(rotation.z)
    local cosPitch = math.abs(math.cos(pitch))

    return {
        x = -math.sin(yaw) * cosPitch,
        y = math.cos(yaw) * cosPitch,
        z = math.sin(pitch),
    }
end

--- Which global kind an entity belongs to.
---
--- A player is a ped, so the more specific answer wins: an option registered for
--- every ped must not silently apply to every player as well, because the two
--- have very different interaction rules.
---
---@param entity number
---@return string
function Raycast.kindOf(entity)
    if IsEntityAPed(entity) then
        if IsPedAPlayer(entity) then return NxcTarget.Options.GLOBAL_KIND.PLAYER end
        return NxcTarget.Options.GLOBAL_KIND.PED
    end
    if IsEntityAVehicle(entity) then return NxcTarget.Options.GLOBAL_KIND.VEHICLE end
    return NxcTarget.Options.GLOBAL_KIND.OBJECT
end

NxcTarget.Raycast = Raycast
return Raycast
