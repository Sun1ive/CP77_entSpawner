local utils = require("modules/utils/core/utils")

---Shared support for groups of outline markers.
---@class outlineConsumer
local outlineConsumer = {}

outlineConsumer.MARKER_MODULE_PATH = "area/outlineMarker"

---Minimum markers needed to define a volume.
outlineConsumer.MIN_MARKERS = 3

---Defaults for generated outlines.
outlineConsumer.NEW_OUTLINE_GROUP_NAME = "outline"
outlineConsumer.NEW_OUTLINE_RADIUS = 4
outlineConsumer.NEW_OUTLINE_HEIGHT = 6

---Returns counter-clockwise square offsets from -X/-Y.
---@param radius number?
---@return table[] offsets `{x, y}` pairs
function outlineConsumer.getSquareOffsets(radius)
    local r = tonumber(radius) or outlineConsumer.NEW_OUTLINE_RADIUS

    return {
        { x = -r, y = -r },
        { x = r, y = -r },
        { x = r, y = r },
        { x = -r, y = r }
    }
end

---Caches consumers by root and outline path.
local outlineConsumerCache = setmetatable({}, { __mode = "k" })

---Incremented when an outline binding changes.
local outlineConsumerEpoch = 0

function outlineConsumer.invalidate()
    outlineConsumerEpoch = outlineConsumerEpoch + 1
end

---@param child table?
---@return boolean
local function isMarker(child)
    local spawnable = child and child.spawnable or nil

    return utils.isA(child, "spawnableElement")
        and spawnable ~= nil
        and spawnable.modulePath == outlineConsumer.MARKER_MODULE_PATH
end

outlineConsumer.isMarker = isMarker

---@param root element
---@param sUI table
---@return table<string, table[]>
local function getConsumers(root, sUI)
    if sUI.ensureCache then
        sUI.ensureCache()
    end

    local stamp = string.format("%s:%s", tostring(sUI.cacheEpoch or 0), tostring(outlineConsumerEpoch))
    local cached = outlineConsumerCache[root]

    if cached and cached.stamp == stamp then
        return cached.byPath
    end

    local byPath = {}

    for _, entry in pairs(sUI.paths or {}) do
        local ref = entry.ref
        local spawnable = ref and utils.isA(ref, "spawnableElement") and ref.spawnable or nil

        if spawnable and spawnable.onOutlineChanged and spawnable.outlinePath and spawnable.outlinePath ~= "" then
            if ref.getRootParent and ref:getRootParent() == root then
                local bucket = byPath[spawnable.outlinePath]

                if not bucket then
                    bucket = {}
                    byPath[spawnable.outlinePath] = bucket
                end

                table.insert(bucket, spawnable)
            end
        end
    end

    outlineConsumerCache[root] = { stamp = stamp, byPath = byPath }

    return byPath
end

---Notifies consumers that reference an outline group.
---@param object element Element inside the outline group, usually an outline marker.
---@param parentOverride element? Group to notify for, when the marker just left or entered one.
function outlineConsumer.notifyChanged(object, parentOverride)
    if not object then return end

    local parent = parentOverride or object.parent
    local sUI = object.sUI

    if not parent or not sUI or not parent.getPath then return end

    local path = parent:getPath()
    if not path or path == "" then return end

    local root = object.getRootParent and object:getRootParent() or nil
    if not root then return end

    for _, spawnable in ipairs(getConsumers(root, sUI)[path] or {}) do
        spawnable:onOutlineChanged()
    end
end

---Returns outline paths under the consumer's root.
---@param consumer table Spawnable with an `object` element
---@return string[]
function outlineConsumer.loadPaths(consumer)
    local paths = {}
    local object = consumer and consumer.object or nil
    local sUI = object and object.sUI or nil

    if not object or not sUI then
        return paths
    end

    if sUI.ensureCache then
        sUI.ensureCache()
    end

    local ownRoot = object.getRootParent and object:getRootParent() or nil
    if not ownRoot then
        return paths
    end

    for _, container in pairs(sUI.containerPaths or {}) do
        if container and container.ref and container.ref.getRootParent and container.ref:getRootParent() == ownRoot then
            local nMarkers = 0

            for _, child in pairs(container.ref.childs or {}) do
                if isMarker(child) then
                    nMarkers = nMarkers + 1
                end

                if nMarkers == outlineConsumer.MIN_MARKERS then
                    if container.path and container.path ~= "" then
                        table.insert(paths, container.path)
                    end
                    break
                end
            end
        end
    end

    -- Keep an incomplete selected outline in the list while drawing it.
    local own = outlineConsumer.getGroup(consumer)
    if own and utils.indexValue(paths, consumer.outlinePath) == -1 then
        table.insert(paths, consumer.outlinePath)
    end

    return paths
end

---Resolves the bound outline within the consumer's root.
---@param consumer table Spawnable with `object` and `outlinePath`
---@return element? outlineGroup
function outlineConsumer.getGroup(consumer)
    local object = consumer and consumer.object or nil
    local path = consumer and consumer.outlinePath or nil

    if not object or not path or path == "" or path == "None" then
        return nil
    end

    local sUI = object.sUI
    local outline = sUI and sUI.getElementByPath and sUI.getElementByPath(path) or nil

    if not outline or not outline.childs then
        return nil
    end

    -- Reject stale cross-root bindings.
    local ownRoot = object.getRootParent and object:getRootParent() or nil
    if not ownRoot or not outline.getRootParent or outline:getRootParent() ~= ownRoot then
        return nil
    end

    return outline
end

---Returns live marker positions and outline height.
---@param consumer table Spawnable with `object` and `outlinePath`
---@return table[] markers World-space `{x, y, z}` tables, in group order
---@return number height
function outlineConsumer.getMarkers(consumer)
    local markers = {}
    local height = 0
    local outline = outlineConsumer.getGroup(consumer)

    if not outline then
        return markers, height
    end

    for _, child in ipairs(outline.childs) do
        if isMarker(child) then
            local spawnable = child.spawnable

            if spawnable.position then
                table.insert(markers, utils.fromVector(spawnable.position))
            end
            height = tonumber(spawnable.height) or height
        end
    end

    if #markers < outlineConsumer.MIN_MARKERS then
        return {}, 0
    end

    return markers, height
end

---Returns outline points relative to the consumer.
---@param consumer table Spawnable with `object`, `outlinePath` and `position`
---@return table[] points `Vector3` tables ready for `AreaShapeOutline.points`
---@return number height
function outlineConsumer.getLocalPoints(consumer)
    local markers, height = outlineConsumer.getMarkers(consumer)
    local origin = consumer and consumer.position or nil
    local points = {}

    for _, marker in ipairs(markers) do
        table.insert(points, {
            ["$type"] = "Vector3",
            X = marker.x - (origin and origin.x or 0),
            Y = marker.y - (origin and origin.y or 0),
            Z = marker.z - (origin and origin.z or 0)
        })
    end

    return points, height
end

---@param parent element
---@param namePrefix string
---@return string
local function getNextChildName(parent, namePrefix)
    local prefix = tostring(namePrefix or "outline")
    local nextIndex = 0

    while true do
        local candidate = prefix .. "_" .. tostring(nextIndex)
        local exists = false

        for _, child in ipairs(parent.childs or {}) do
            if tostring(child.name or "") == candidate then
                exists = true
                break
            end
        end

        if not exists then
            return candidate
        end

        nextIndex = nextIndex + 1
    end
end

---Adds a marker; only the first marker uses the supplied height.
---@param consumer table Spawnable with an `object` element
---@param outlineGroup element Group to append to
---@param position Vector4|table World position
---@param height number? Height of the first marker, defaults to `NEW_OUTLINE_HEIGHT`
---@return element? markerElement
function outlineConsumer.addMarker(consumer, outlineGroup, position, height)
    if not consumer or not consumer.object or not outlineGroup or not position then
        return nil
    end

    local spawnableElement = require("modules/classes/editor/spawnableElement")
    local markerClass = require("modules/classes/spawn/area/outlineMarker")
    local index = 1

    for _, child in ipairs(outlineGroup.childs or {}) do
        if isMarker(child) then
            index = index + 1
        end
    end

    local marker = markerClass:new()
    marker:loadSpawnData(
        { height = tonumber(height) or outlineConsumer.NEW_OUTLINE_HEIGHT },
        Vector4.new(position.x or 0, position.y or 0, position.z or 0, 0),
        EulerAngles.new(0, 0, 0)
    )

    local markerElement = spawnableElement:new(consumer.object.sUI)
    markerElement:load({
        name = string.format("marker_%02d", index),
        spawnable = marker:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    markerElement:setParent(outlineGroup)

    return markerElement
end

---Creates an outline marker group for a consumer.
---@param consumer table Spawnable with `object` and `position`
---@param parent element
---@param options table? `{ namePrefix, offsets, height }`, no offsets creating an empty group
---@return element? outlineGroup
function outlineConsumer.createMarkerGroup(consumer, parent, options)
    if not consumer or not consumer.object or not parent then
        return nil
    end

    local opts = options or {}
    local positionableGroup = require("modules/classes/editor/positionableGroup")
    local outlineGroup = positionableGroup:new(consumer.object.sUI)
    local height = tonumber(opts.height) or 0
    local position = consumer.position or { x = 0, y = 0, z = 0 }

    outlineGroup.name = getNextChildName(parent, opts.namePrefix or outlineConsumer.NEW_OUTLINE_GROUP_NAME)
    outlineGroup.headerOpen = true
    outlineGroup:setParent(parent)

    for _, offset in ipairs(opts.offsets or {}) do
        outlineConsumer.addMarker(consumer, outlineGroup, {
            x = position.x + (offset.x or 0),
            y = position.y + (offset.y or 0),
            z = position.z + (offset.z or 0)
        }, height)
    end

    return outlineGroup
end

return outlineConsumer
