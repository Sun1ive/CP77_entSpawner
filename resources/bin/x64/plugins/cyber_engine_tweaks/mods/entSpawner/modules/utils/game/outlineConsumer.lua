local utils = require("modules/utils/core/utils")

---Shared outline-group plumbing.
---
---An outline is a `positionableGroup` of `area/outlineMarker` spawnables. A consumer only needs an
---`outlinePath` field and `onOutlineChanged` method.
---@class outlineConsumer
local outlineConsumer = {}

outlineConsumer.MARKER_MODULE_PATH = "area/outlineMarker"

---An outline group has to hold at least this many markers to describe a volume.
outlineConsumer.MIN_MARKERS = 3

---Consumers bucketed by outline path per root element.
---Marker drags notify every frame, so cache with the hierarchy epoch.
local outlineConsumerCache = setmetatable({}, { __mode = "k" })

---Bump when a consumer chooses a different outline path.
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

---Notifies every consumer that references an outline group.
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

---Every outline group under the consumer's own root.
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

    return paths
end

---Marker world positions and outline height, read live from the hierarchy.
---Uses direct path lookup because device bindings can refresh while dragged.
---@param consumer table Spawnable with `object` and `outlinePath`
---@return table[] markers World-space `{x, y, z}` tables, in group order
---@return number height
function outlineConsumer.getMarkers(consumer)
    local markers = {}
    local height = 0

    local object = consumer and consumer.object or nil
    local path = consumer and consumer.outlinePath or nil

    if not object or not path or path == "" or path == "None" then
        return markers, height
    end

    local sUI = object.sUI
    local outline = sUI and sUI.getElementByPath and sUI.getElementByPath(path) or nil

    if not outline or not outline.childs then
        return markers, height
    end

    -- Cross-root paths are stale bindings, not usable outlines.
    local ownRoot = object.getRootParent and object:getRootParent() or nil
    if not ownRoot or not outline.getRootParent or outline:getRootParent() ~= ownRoot then
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

---Outline points relative to a node's own position.
---`AreaShapeOutline.points` stores local offsets, not world coordinates.
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

---Creates an outline marker group around a consumer.
---@param consumer table Spawnable with `object` and `position`
---@param parent element
---@param options table? `{ namePrefix, offsets, height }`
---@return element? outlineGroup
function outlineConsumer.createMarkerGroup(consumer, parent, options)
    if not consumer or not consumer.object or not parent then
        return nil
    end

    local opts = options or {}
    local positionableGroup = require("modules/classes/editor/positionableGroup")
    local spawnableElement = require("modules/classes/editor/spawnableElement")
    local markerClass = require("modules/classes/spawn/area/outlineMarker")
    local outlineGroup = positionableGroup:new(consumer.object.sUI)
    local height = tonumber(opts.height) or 0
    local position = consumer.position or { x = 0, y = 0, z = 0 }

    outlineGroup.name = getNextChildName(parent, opts.namePrefix or "outline")
    outlineGroup.headerOpen = true
    outlineGroup:setParent(parent)

    for index, offset in ipairs(opts.offsets or {}) do
        local marker = markerClass:new()
        marker:loadSpawnData(
            { height = height },
            Vector4.new(
                position.x + (offset.x or 0),
                position.y + (offset.y or 0),
                position.z + (offset.z or 0),
                0
            ),
            EulerAngles.new(0, 0, 0)
        )

        local markerElement = spawnableElement:new(consumer.object.sUI)
        markerElement:load({
            name = string.format("marker_%02d", index),
            spawnable = marker:save(),
            modulePath = "modules/classes/editor/spawnableElement"
        })
        markerElement:setParent(outlineGroup)
    end

    return outlineGroup
end

return outlineConsumer
