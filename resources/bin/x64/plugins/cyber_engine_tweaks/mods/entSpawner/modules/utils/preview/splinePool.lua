local logger = require("modules/utils/core/logger")

---Allocates placeholder spline nodes used by live previews.
---AI commands require NodeRefs, so previews rewrite archived nodes.
---@class splinePool
local pool = {}

local refRoot = "$/mods/entSpawner/preview_placeholder/#"
local families = {
    worldSplineNode = "wb_preview_spline_",
    worldSpeedSplineNode = "wb_preview_speed_spline_",
    worldPatrolSplineNode = "wb_preview_patrol_spline_"
}
-- Must match the nodes shipped in the archive.
local slotsPerFamily = 10

---@class splinePoolSlot
---@field family string Node class the slot belongs to.
---@field index number 0-based slot index inside its family.
---@field ref string Full NodeRef string of the placeholder node.
---@field nodeRef NodeRef Resolved ref passed to the AI command.
---@field definition worldSplineNode? Definition valid while streamed.
---@field origin table? Node world position used for local points.
---@field owner table? Spawnable currently holding the slot.

---Slots by family, built lazily: `records[family][index]`.
local records = {}
---Slots indexed by owner.
local owners = {}

---Last claim error shown in the UI.
pool.lastReason = ""

local nativeChecked = false
local nativeAvailable = false

---Checks whether native spline tangent writes are available.
---@return boolean
function pool.hasNativeTangents()
    if not nativeChecked then
        nativeChecked = true
        local ok, ready = pcall(function()
            return WBSplineToolsReady ~= nil and WBSplineToolsReady()
        end)
        nativeAvailable = ok and ready == true
    end

    return nativeAvailable
end

---Returns Red Hot Tools' world inspector when available.
---@return worldInspector?
function pool.getInspector()
    local ok, inspector = pcall(function()
        return Game.GetWorldInspector and Game.GetWorldInspector()
    end)

    return ok and inspector or nil
end

---@param family string
---@param index number
---@return string
local function refFor(family, index)
    return refRoot .. families[family] .. index
end

---@param ref string
---@return worldSplineNode? definition
---@return NodeRef? nodeRef
local function resolveNode(ref)
    local inspector = pool.getInspector()
    if not inspector then return nil end

    local okRef, nodeRef = pcall(function()
        return CreateEntityReference(ref, {}).reference
    end)
    if not okRef or not nodeRef then return nil end

    local okGlobal, globalRef = pcall(function()
        return ResolveNodeRef(nodeRef, GlobalNodeID.GetRoot())
    end)
    if not okGlobal or not globalRef then return nil end

    local okNode, streamed = pcall(function()
        return inspector:FindStreamedNode(globalRef.hash)
    end)
    if not okNode or not streamed or not streamed.nodeDefinition then return nil end

    return streamed.nodeDefinition, nodeRef
end

---@param localPoints table Points already in node-local space.
---@param looped boolean
---@return Spline?
local function buildSpline(localPoints, looped)
    local ok, spline = pcall(function() return NewObject("handle:Spline") end)
    if not ok or not spline then return nil end

    if pool.hasNativeTangents() then
        local positions, tangentsIn, tangentsOut, automatic = {}, {}, {}, {}

        for i = 1, #localPoints do
            local point = localPoints[i]
            positions[i] = Vector3.new(point.position.x, point.position.y, point.position.z)
            tangentsIn[i] = Vector3.new(point.tangentIn.x, point.tangentIn.y, point.tangentIn.z)
            tangentsOut[i] = Vector3.new(point.tangentOut.x, point.tangentOut.y, point.tangentOut.z)
            automatic[i] = point.automaticTangents and true or false
        end

        local wrote, result = pcall(function()
            return WBSetSplinePoints(spline, positions, tangentsIn, tangentsOut, automatic)
        end)
        if not wrote or result ~= true then return nil end
    else
        local points = {}

        for i = 1, #localPoints do
            local okPoint, point = pcall(function() return NewObject("SplinePoint") end)
            if not okPoint or not point then return nil end

            local written = pcall(function()
                point.position = Vector3.new(
                    localPoints[i].position.x,
                    localPoints[i].position.y,
                    localPoints[i].position.z)
                -- Lua cannot write tangents, so let the engine fit them.
                point.automaticTangents = true
                point.continuousTangents = true
                point.id = i
            end)
            if not written then return nil end

            points[i] = point
        end

        if not pcall(function() spline.points = points end) then return nil end
    end

    pcall(function()
        spline.looped = looped and true or false
        -- The command controls direction.
        spline.reversed = false
        spline.hasDirection = true
    end)

    return spline
end

---Measures the placeholder's world origin for node-local points.
---@param record splinePoolSlot
---@return table? origin
local function calibrate(record)
    local spline = buildSpline({
        {
            position = { x = 0, y = 0, z = 0 },
            tangentIn = { x = 0, y = 0, z = 0 },
            tangentOut = { x = 0, y = 0, z = 0 },
            automaticTangents = true
        },
        {
            position = { x = 1, y = 0, z = 0 },
            tangentIn = { x = 0, y = 0, z = 0 },
            tangentOut = { x = 0, y = 0, z = 0 },
            automaticTangents = true
        }
    }, false)
    if not spline then return nil end

    if not pcall(function() record.definition.splineData = spline end) then return nil end

    if not AIScriptUtils or not AIScriptUtils.GetStartPointOfSpline then return nil end

    -- CET supplies GameInstance and returns the out parameter second.
    local ok, found, start = pcall(function()
        return AIScriptUtils.GetStartPointOfSpline(record.nodeRef)
    end)
    if not ok or not found or not start then return nil end

    return { x = start.x, y = start.y, z = start.z }
end

---Returns the first available slot in a family.
---@param family string
---@return splinePoolSlot?
local function acquireFrom(family)
    local list = records[family]
    if not list then
        list = {}
        records[family] = list
    end

    for index = 0, slotsPerFamily - 1 do
        local record = list[index]
        if not record then
            record = { family = family, index = index, ref = refFor(family, index) }
            list[index] = record
        end

        if not record.owner then
            -- Re-resolve because the definition is valid only while streamed.
            local definition, nodeRef = resolveNode(record.ref)

            if definition then
                record.definition = definition
                record.nodeRef = nodeRef
                record.origin = record.origin or calibrate(record)

                if record.origin then
                    return record
                end
            end

            record.definition = nil
        end
    end

    return nil
end

---Claims a matching placeholder, falling back to a plain spline.
---@param owner table Spawnable taking the slot.
---@param nodeClass string `worldSplineNode`, `worldSpeedSplineNode`, ...
---@return splinePoolSlot?
function pool.claim(owner, nodeClass)
    if owners[owner] then return owners[owner] end

    if not pool.getInspector() then
        pool.lastReason = "Red Hot Tools is not installed. The NPC preview needs it to reach the placeholder spline nodes."
        return nil
    end

    -- Reclaim slots left by despawned previews.
    for _, list in pairs(records) do
        for _, record in pairs(list) do
            if record.owner and record.owner ~= owner then
                local ok, spawned = pcall(function() return record.owner:isSpawned() end)
                if ok and not spawned then
                    owners[record.owner] = nil
                    record.owner = nil
                end
            end
        end
    end

    local order = { "worldSplineNode" }
    if families[nodeClass] and nodeClass ~= "worldSplineNode" then
        order = { nodeClass, "worldSplineNode" }
    end

    for i = 1, #order do
        local record = acquireFrom(order[i])

        if record then
            record.owner = owner
            owners[owner] = record
            pool.lastReason = ""
            return record
        end
    end

    pool.lastReason = "No preview spline node is available. Either all 10 slots are in use, or the World Builder preview sector is not streaming - which needs a full game restart after installing or updating the mod."
    return nil
end

---Releases a slot without clearing its spline data.
---@param owner table
function pool.release(owner)
    local record = owners[owner]
    if not record then return end

    owners[owner] = nil
    record.owner = nil
end

---Writes authored marker geometry to a claimed slot.
---@param record splinePoolSlot
---@param defs table Marker defs in world space.
---@param looped boolean
---@return boolean
function pool.write(record, defs, looped)
    if not record or not record.definition or not record.origin then return false end
    if not defs or #defs < 2 then return false end

    local localPoints = {}
    local origin = record.origin

    for i = 1, #defs do
        local def = defs[i]
        local tangentIn = def.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = def.tangentOut or { x = 0, y = 0, z = 0 }

        localPoints[i] = {
            position = {
                x = def.position.x - origin.x,
                y = def.position.y - origin.y,
                z = def.position.z - origin.z
            },
            tangentIn = { x = tangentIn.x or 0, y = tangentIn.y or 0, z = tangentIn.z or 0 },
            tangentOut = { x = tangentOut.x or 0, y = tangentOut.y or 0, z = tangentOut.z or 0 },
            automaticTangents = def.automaticTangents == nil and true or def.automaticTangents
        }
    end

    local spline = buildSpline(localPoints, looped)
    if not spline then
        logger:warn("[splinePool] could not build spline data for " .. record.ref)
        return false
    end

    return pcall(function() record.definition.splineData = spline end)
end

return pool
