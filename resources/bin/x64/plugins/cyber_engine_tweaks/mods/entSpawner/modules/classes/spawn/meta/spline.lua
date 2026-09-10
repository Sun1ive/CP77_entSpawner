local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local gameUtils = require("modules/utils/game/gameUtils")
local cache = require("modules/utils/game/cache")
local builder = require("modules/utils/game/entityBuilder")
local Cron = require("modules/utils/vendor/Cron")
local history = require("modules/utils/project/history")
local settings = require("modules/utils/core/settings")
local visualizer = require("modules/utils/preview/visualizer")
local logger = require("modules/utils/core/logger")
local previewHosts = require("modules/utils/preview/previewHosts")
local splinePool = require("modules/utils/preview/splinePool")

local minCurvePreviewSamples = 8
local maxCurvePreviewSamples = 24
-- Per-entity component limit. Keep in sync with PATH_PREVIEW_MAX_SEGMENTS.
local maxEntityPreviewComponents = 320
-- Preview lines use separate hosts to stay below the per-entity limit.
local curvePreviewComponentsPerHost = 256
local curvePreviewHostTemplate = "base\\spawner\\empty_entity.ent"
-- Decimate beyond this limit instead of spawning more hosts.
local curvePreviewComponentCeiling = 4096
-- Chord-error range in meters.
local minCurveFlattenTolerance = 0.002
local maxCurveFlattenTolerance = 0.2
local lengthIntegrationEpsilon = 0.00001
local lengthIntegrationMaxDepth = 18

-- Interval for syncing marker changes to a running preview.
local followerGeometryInterval = 0.25
-- Delay before removing a character that reached the end.
local followerCleanupDelay = 2

---Class for worldSplineNode
---@class spline : visualized
---@field splinePath string
---@field points table
---@field reverse boolean
---@field looped boolean
---@field protected maxPropertyWidth number
---@field previewCharacter string
---@field splineFollowerSpeed number
---@field splineMoveType string
---@field splineIgnoreNavigation boolean
---@field protected _followerCommand AIMoveOnSplineCommand? Active preview command.
---@field protected _followerSlot splinePoolSlot? Placeholder spline node the preview runs on.
---@field protected _followerSignature string? Marker geometry last written to that node.
---@field protected _followerIssue string? Preview start error shown in the UI.
---@field protected _followerPlaying boolean Runtime-only preview state.
---@field protected _followerCleanupID number? Pending cleanup Cron handle.
---@field protected _followerResume boolean Resume the preview after respawn.
---@field npcID entEntityID
---@field npcSpawning boolean
---@field cronID number
---@field rigs table
---@field apps table
local spline = setmetatable({}, { __index = visualized })

function spline:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Spline"
    o.spawnDataPath = "data/spawnables/meta/Spline/"
    o.modulePath = "meta/spline"
    o.node = "worldSplineNode"
    o.description = "Basic spline with auto-tangents, which can be referenced using its NodeRef."
    o.icon = IconGlyphs.VectorPolyline

    -- Identifies worldSplineNode-derived spawnables.
    o.isSplineNode = true

    o.previewed = true
    o.previewColor = "violet"
    o.splinePath = ""

    o.reverse = false
    o.looped = false
    o.points = {}
    o.pointDefs = {}

    o.previewCharacter = settings.defaultAISpotNPC or ""
    o.splineFollowerSpeed = settings.defaultAISpotSpeed or 1.0

    o.maxPropertyWidth = nil
    o.npcID = nil
    o.npcSpawning = false
    o.cronID = nil
    o.rigs = {}
    o.apps = {}
    o.splineMoveType = "Walk"
    o.splineIgnoreNavigation = true
    o._followerCommand = nil
    o._followerSlot = nil
    o._followerSignature = nil
    o._followerIssue = nil
    -- Never persist preview playback.
    o._followerPlaying = false
    o._followerCleanupID = nil
    o._followerResume = false
    o._followerRebuildTimer = 0
    o.curvePreviewSamples = math.floor(math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, settings.defaultSplineCurveQuality or 12)))
    o._curvePreviewComponentCount = 0

    setmetatable(o, { __index = self })
   	return o
end

function spline:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    self.previewCharacter = utils.stripNonASCII(self.previewCharacter)
    self.curvePreviewSamples = math.floor(math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, self.curvePreviewSamples or 12)))

    self.pointDefs = {}
    if data.pointDefs and #data.pointDefs > 0 then
        for _, pointDef in ipairs(data.pointDefs) do
            local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
            local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }
            table.insert(self.pointDefs, {
                position = pointDef.position or { x = 0, y = 0, z = 0 },
                tangentIn = tangentIn,
                tangentOut = tangentOut,
                automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents
            })
        end
    elseif data.points and #data.points > 0 then
        for _, point in ipairs(data.points) do
            table.insert(self.pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    if self.splinePath and self.splinePath ~= "" and self.splinePath ~= "None" then
        Cron.After(0.5, function()
            self:refreshLinkedMarkerTangents(self.looped)
            self:respawn()
        end)
    end
end

function spline:getVisualizerSize()
    return { x = 0.25, y = 0.25, z = 0.25 }
end

function spline:getNPC()
    return gameUtils.getNPC(self.npcID)
end

function spline:getInterpolatedPosition(t)
    if #self.points == 0 then
        self:loadSplinePoints()
    end

    -- Normalize t from 0 to 1.
    if #self.points == 0 then
        return self.position
    end

    if #self.points == 1 then
        return self.points[1]
    end

    local points = {}
    for i = 1, #self.points do
        table.insert(points, self.points[i])
    end

    -- Find the segment containing t.
    local segmentCount = #points - 1
    local scaledT = t * segmentCount
    local segmentIndex = math.floor(scaledT) + 1
    local localT = scaledT - math.floor(scaledT)

    if self.looped and segmentIndex > segmentCount then
        segmentIndex = 1
        localT = 0
    end

    if segmentIndex > segmentCount then
        return points[#points]
    end

    local p0 = points[segmentIndex]
    local p1 = points[segmentIndex + 1]

    -- Interpolate between the endpoints.
    local interpolated = Vector4.new(
        p0.x + (p1.x - p0.x) * localT,
        p0.y + (p1.y - p0.y) * localT,
        p0.z + (p1.z - p0.z) * localT,
        0
    )

    return interpolated
end

function spline:getOrderedPoints()
    if #self.points == 0 then
        self:loadSplinePoints()
    end

    local ordered = {}
    for i = 1, #self.points do
        table.insert(ordered, self.points[i])
    end

    return ordered
end

function spline:hasCurveTangents(pointDefs)
    local function lengthSq(tab)
        return tab.x * tab.x + tab.y * tab.y + tab.z * tab.z
    end

    if not pointDefs or #pointDefs < 2 then
        return false
    end

    for i = 1, #pointDefs - 1 do
        local current = pointDefs[i]
        local nxt = pointDefs[i + 1]
        if current and nxt and (lengthSq(current.tangentOut) > 0.00000001 or lengthSq(nxt.tangentIn) > 0.00000001) then
            return true
        end
    end

    if self.looped then
        local last = pointDefs[#pointDefs]
        local first = pointDefs[1]
        if last and first and (lengthSq(last.tangentOut) > 0.00000001 or lengthSq(first.tangentIn) > 0.00000001) then
            return true
        end
    end

    return false
end

function spline:getFollowerPathPoints()
    local pointDefs = self:getFollowerPreviewSplineMarkerDefs()
    local function applyPreviewDirection(points)
        if not self.reverse then
            return points
        end

        local reversed = {}
        for i = #points, 1, -1 do
            table.insert(reversed, points[i])
        end

        return reversed
    end

    if #pointDefs == 0 then
        self:loadSplinePoints()
        local points = {}
        for i = 1, #self.points do
            table.insert(points, self.points[i])
        end
        return applyPreviewDirection(points)
    end

    if not self:hasCurveTangents(pointDefs) then
        local points = {}
        for _, pointDef in ipairs(pointDefs) do
            table.insert(points, utils.fromVector(pointDef.position))
        end
        return applyPreviewDirection(points)
    end

    local pathPoints = {}
    local samples = math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, self.curvePreviewSamples or 12))

    local function sampleSegment(defA, defB)
        local p0 = defA.position
        local p1 = defB.position
        local c0 = utils.addVector(p0, Vector4.new(defA.tangentOut.x, defA.tangentOut.y, defA.tangentOut.z, 0))
        local c1 = utils.addVector(p1, Vector4.new(defB.tangentIn.x, defB.tangentIn.y, defB.tangentIn.z, 0))

        if #pathPoints == 0 then
            table.insert(pathPoints, utils.fromVector(p0))
        end

        for i = 1, samples do
            local t = i / samples
            table.insert(pathPoints, utils.fromVector(self:getBezierPoint(p0, c0, c1, p1, t)))
        end
    end

    for i = 1, #pointDefs - 1 do
        sampleSegment(pointDefs[i], pointDefs[i + 1])
    end

    if self.looped and #pointDefs > 1 then
        sampleSegment(pointDefs[#pointDefs], pointDefs[1])
    end

    return applyPreviewDirection(pathPoints)
end

function spline:getTotalLength()
    local pointDefs = self:getFollowerPreviewSplineMarkerDefs()

    local function sumLinear(points, looped)
        if #points < 2 then
            return 0
        end

        local total = 0
        for i = 1, #points - 1 do
            total = total + utils.distanceVector(points[i], points[i + 1])
        end

        if looped and #points > 1 then
            total = total + utils.distanceVector(points[#points], points[1])
        end

        return total
    end

    if #pointDefs == 0 then
        self:loadSplinePoints()
        local points = {}
        for i = 1, #self.points do
            table.insert(points, self.points[i])
        end

        return sumLinear(points, self.looped)
    end

    local total = 0
    local function bezierSegmentLength(defA, defB)
        local p0 = defA.position
        local p1 = defB.position
        local c0 = utils.addVector(p0, Vector4.new(defA.tangentOut.x, defA.tangentOut.y, defA.tangentOut.z, 0))
        local c1 = utils.addVector(p1, Vector4.new(defB.tangentIn.x, defB.tangentIn.y, defB.tangentIn.z, 0))

        return self:getBezierArcLength(p0, c0, c1, p1, lengthIntegrationEpsilon, lengthIntegrationMaxDepth)
    end

    for i = 1, #pointDefs - 1 do
        total = total + bezierSegmentLength(pointDefs[i], pointDefs[i + 1])
    end

    if self.looped and #pointDefs > 1 then
        total = total + bezierSegmentLength(pointDefs[#pointDefs], pointDefs[1])
    end

    return total
end

function spline:refreshLinkedMarkerTangents(refreshEdgeTangents)
    local paths = self:loadSplinePaths()
    if utils.indexValue(paths, self.splinePath) == -1 then return end

    local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
    if not splineGroup then return end

    local markers = {}
    for _, child in ipairs(splineGroup.childs) do
        if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
            table.insert(markers, child.spawnable)
        end
    end

    for _, marker in ipairs(markers) do
        -- Refresh connectors after topology changes such as loop toggles.
        marker:updateTransform(splineGroup)
    end

    if refreshEdgeTangents and #markers > 1 then
        local first = markers[1]
        local last = markers[#markers]

        if first and first.symmetricTangents then
            first:applyAutoTangents(splineGroup)
            first:updateTransform(splineGroup)
        end

        if last and last.symmetricTangents then
            last:applyAutoTangents(splineGroup)
            last:updateTransform(splineGroup)
        end
    end
end

---Builds a signature used to detect preview geometry changes.
---@param defs table
---@return string
local function geometrySignature(defs, looped)
    local parts = {}

    for i = 1, #defs do
        local def = defs[i]
        local tangentIn = def.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = def.tangentOut or { x = 0, y = 0, z = 0 }

        parts[i] = string.format("%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%s",
            def.position.x, def.position.y, def.position.z,
            tangentIn.x or 0, tangentIn.y or 0, tangentIn.z or 0,
            tangentOut.x or 0, tangentOut.y or 0, tangentOut.z or 0,
            tostring(def.automaticTangents ~= false))
    end

    parts[#parts + 1] = looped and "looped" or "open"

    return table.concat(parts, ";")
end

---Returns the authored marker data used by preview and export.
---@return table
function spline:getFollowerSplineDefs()
    local defs = self:getSplineMarkerDefs()

    if #defs == 0 and self.pointDefs and #self.pointDefs > 0 then
        defs = utils.deepcopy(self.pointDefs)
    end

    if #defs == 0 then
        self:loadSplinePoints()
        for i = 1, #self.points do
            defs[i] = {
                position = self.points[i],
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            }
        end
    end

    return defs
end

---Writes changed marker geometry to the preview node.
---@return boolean written
function spline:refreshFollowerGeometry()
    if not self._followerSlot then return false end

    local defs = self:getFollowerSplineDefs()
    if #defs < 2 then return false end

    local signature = geometrySignature(defs, self.looped)
    if signature == self._followerSignature then return false end

    if not splinePool.write(self._followerSlot, defs, self.looped) then return false end

    self._followerSignature = signature
    return true
end

---Builds the movement spec for the preview command.
---@return AIMovementTypeSpec
function spline:buildFollowerMovementType()
    local movementType = NewObject("AIMovementTypeSpec")
    movementType.useNPCMovementParams = false
    movementType.movementType = self.splineMoveType

    return movementType
end

---Starts movement on the placeholder spline node.
---@param npc gameObject
---@return boolean sent
function spline:sendSplineCommand(npc)
    local slot = self._followerSlot
    local aiController = npc and npc:GetAIControllerComponent()
    if not slot or not aiController then return false end

    local cmd = NewObject("handle:AIMoveOnSplineCommand")
    cmd.spline = slot.nodeRef
    cmd.movementType = self:buildFollowerMovementType()
    -- Direction belongs to the command, not the node data.
    cmd.reverse = self.reverse and true or false
    cmd.ignoreNavigation = self.splineIgnoreNavigation and true or false
    cmd.startFromClosestPoint = true
    -- Re-read the spline while walking to follow marker edits.
    cmd.splineRecalculation = true
    cmd.snapToTerrain = true
    cmd.useStart = true
    cmd.useStop = true
    cmd.rotateEntityTowardsFacingTarget = false

    self._followerCommand = cmd
    aiController:SendCommand(cmd)

    return true
end

---Restarts movement from the character's current position.
function spline:restartFollowerCommand()
    if not self._followerSlot then return end

    local npc = self:getNPC()
    if not npc then return end

    self:sendSplineCommand(npc)
end

---Command states that indicate an active run.
local followerRunningStates = { NotExecuting = true, Enqueued = true, Executing = true }

---@return boolean running
function spline:isFollowerCommandRunning()
    if not self._followerCommand then return false end

    local ok, state = pcall(function() return self._followerCommand.state end)
    if not ok or not state then return true end

    local name = state.value or tostring(state)

    return followerRunningStates[name] == true
end

function spline:loadSplinePoints()
    self.points = {}
    local paths = self:loadSplinePaths()

    if utils.indexValue(paths, self.splinePath) ~= -1 then
        local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
        if splineGroup then
            for _, child in pairs(splineGroup.childs) do
                if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
                    table.insert(self.points, utils.fromVector(child.spawnable.position))
                end
            end
        end
    end
end

function spline:collectSplineMarkerDefs()
    local defs = {}
    if not self.splinePath or self.splinePath == "" or self.splinePath == "None" then
        return defs
    end

    local splineGroup = self.object.sUI.getElementByPath(self.splinePath)
    if not splineGroup then
        return defs
    end

    for _, child in ipairs(splineGroup.childs) do
        if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
            local marker = child.spawnable
            local saved = marker.spawnData or {}
            local tangentIn = marker.tangentIn or saved.tangentIn or { x = 0, y = 0, z = 0 }
            local tangentOut = marker.tangentOut or saved.tangentOut or { x = 0, y = 0, z = 0 }

            table.insert(defs, {
                position = marker.position,
                tangentIn = {
                    x = tonumber(tangentIn.x) or 0,
                    y = tonumber(tangentIn.y) or 0,
                    z = tonumber(tangentIn.z) or 0
                },
                tangentOut = {
                    x = tonumber(tangentOut.x) or 0,
                    y = tonumber(tangentOut.y) or 0,
                    z = tonumber(tangentOut.z) or 0
                },
                automaticTangents = marker.automaticTangents == nil and true or marker.automaticTangents
            })
        end
    end

    return defs
end

function spline:getSplineMarkerDefs()
    return self:collectSplineMarkerDefs()
end

function spline:getFollowerPreviewSplineMarkerDefs()
    local defs = self:collectSplineMarkerDefs()
    if #defs == 0 then
        return defs
    end

    return self:buildPreviewSplineMarkerDefs(defs)
end

function spline:buildPreviewSplineMarkerDefs(defs)
    if #defs == 0 then
        return defs
    end

    local function toV4(tab)
        return Vector4.new(tab.x, tab.y, tab.z, 0)
    end

    local function toTable(v)
        return { x = v.x, y = v.y, z = v.z }
    end

    local previewDefs = utils.deepcopy(defs)

    for i, def in ipairs(previewDefs) do
        if def.automaticTangents then
            local prevIndex = i - 1
            local nextIndex = i + 1
            local prev = previewDefs[prevIndex]
            local nxt = previewDefs[nextIndex]

            if self.looped then
                if not prev then prev = previewDefs[#previewDefs] end
                if not nxt then nxt = previewDefs[1] end
            end

            local currentPos = toV4(def.position)
            local tangent = Vector4.new(0, 0, 0, 0)

            if prev and nxt then
                tangent = utils.subVector(toV4(nxt.position), toV4(prev.position))
                tangent = Vector4.new(tangent.x / 6, tangent.y / 6, tangent.z / 6, 0)
            elseif nxt then
                tangent = utils.subVector(toV4(nxt.position), currentPos)
                tangent = Vector4.new(tangent.x / 3, tangent.y / 3, tangent.z / 3, 0)
            elseif prev then
                tangent = utils.subVector(currentPos, toV4(prev.position))
                tangent = Vector4.new(tangent.x / 3, tangent.y / 3, tangent.z / 3, 0)
            end

            def.tangentIn = toTable(Vector4.new(-tangent.x, -tangent.y, -tangent.z, 0))
            def.tangentOut = toTable(tangent)
        end
    end

    return previewDefs
end

function spline:getPreviewSplineMarkerDefs()
    local defs = self:getSplineMarkerDefs()
    return self:buildPreviewSplineMarkerDefs(defs)
end

function spline:getBezierPoint(p0, c0, c1, p1, t)
    local u = 1 - t
    local uu = u * u
    local uuu = uu * u
    local tt = t * t
    local ttt = tt * t

    return Vector4.new(
        uuu * p0.x + 3 * uu * t * c0.x + 3 * u * tt * c1.x + ttt * p1.x,
        uuu * p0.y + 3 * uu * t * c0.y + 3 * u * tt * c1.y + ttt * p1.y,
        uuu * p0.z + 3 * uu * t * c0.z + 3 * u * tt * c1.z + ttt * p1.z,
        0
    )
end

function spline:getBezierSpeed(p0, c0, c1, p1, t)
    local u = 1 - t
    local uu = u * u
    local tt = t * t

    local aX = c0.x - p0.x
    local aY = c0.y - p0.y
    local aZ = c0.z - p0.z
    local bX = c1.x - c0.x
    local bY = c1.y - c0.y
    local bZ = c1.z - c0.z
    local cX = p1.x - c1.x
    local cY = p1.y - c1.y
    local cZ = p1.z - c1.z

    local dX = 3 * (uu * aX + 2 * u * t * bX + tt * cX)
    local dY = 3 * (uu * aY + 2 * u * t * bY + tt * cY)
    local dZ = 3 * (uu * aZ + 2 * u * t * bZ + tt * cZ)

    return math.sqrt(dX * dX + dY * dY + dZ * dZ)
end

function spline:getBezierArcLength(p0, c0, c1, p1, epsilon, maxDepth)
    epsilon = epsilon or lengthIntegrationEpsilon
    maxDepth = maxDepth or lengthIntegrationMaxDepth

    local function simpson(fa, fm, fb, h)
        return h * (fa + 4 * fm + fb) / 6
    end

    local function integrateRecursive(a, b, fa, fm, fb, whole, eps, depth)
        local m = (a + b) / 2
        local lm = (a + m) / 2
        local rm = (m + b) / 2

        local flm = self:getBezierSpeed(p0, c0, c1, p1, lm)
        local frm = self:getBezierSpeed(p0, c0, c1, p1, rm)

        local left = simpson(fa, flm, fm, m - a)
        local right = simpson(fm, frm, fb, b - m)
        local delta = left + right - whole

        if depth <= 0 or math.abs(delta) <= 15 * eps then
            -- Improve precision with Richardson extrapolation.
            return left + right + delta / 15
        end

        return integrateRecursive(a, m, fa, flm, fm, left, eps / 2, depth - 1)
            + integrateRecursive(m, b, fm, frm, fb, right, eps / 2, depth - 1)
    end

    local a = 0
    local b = 1
    local m = 0.5
    local fa = self:getBezierSpeed(p0, c0, c1, p1, a)
    local fm = self:getBezierSpeed(p0, c0, c1, p1, m)
    local fb = self:getBezierSpeed(p0, c0, c1, p1, b)
    local whole = simpson(fa, fm, fb, b - a)

    return integrateRecursive(a, b, fa, fm, fb, whole, epsilon, maxDepth)
end

---Distance from `point` to the chord between `p0` and `p1`.
---@param point Vector4
---@param p0 Vector4
---@param p1 Vector4
---@return number
local function chordDistance(point, p0, p1)
    local dx, dy, dz = p1.x - p0.x, p1.y - p0.y, p1.z - p0.z
    local px, py, pz = point.x - p0.x, point.y - p0.y, point.z - p0.z
    local lengthSq = dx * dx + dy * dy + dz * dz

    if lengthSq > 0.000001 then
        local t = math.max(0, math.min(1, (px * dx + py * dy + pz * dz) / lengthSq))
        px, py, pz = px - dx * t, py - dy * t, pz - dz * t
    end

    return math.sqrt(px * px + py * py + pz * pz)
end

---Returns the chord-error tolerance for a curve quality.
---@param quality number
---@return number
local function getFlattenTolerance(quality)
    local t = (quality - minCurvePreviewSamples) / math.max(1, maxCurvePreviewSamples - minCurvePreviewSamples)

    return maxCurveFlattenTolerance * (minCurveFlattenTolerance / maxCurveFlattenTolerance) ^ t
end

---@param index number Global 1-based line index.
---@return string
local function getCurvePreviewName(index)
    return "curvePreview" .. tostring(index)
end

---Checks whether an entity can accept another preview component.
---@param entity entEntity
---@return boolean
function spline:canAddPreviewComponent(entity)
    local count = 0

    for _ in pairs(entity:GetComponents()) do
        count = count + 1
    end

    return count < maxEntityPreviewComponents
end

---Returns the host pool for curve preview lines.
---@return previewHostPool
function spline:getCurvePreviewHosts()
    if not self._curvePreviewHosts then
        self._curvePreviewHosts = previewHosts.new(curvePreviewComponentsPerHost, function ()
            self:updateCurvePreview()
        end)
    end

    return self._curvePreviewHosts
end

---@param index number
---@return entMeshComponent|nil
function spline:getCurvePreviewComponent(index)
    local host = self:getCurvePreviewHosts():hostFor(index, self.position)
    if not host then return nil end

    local name = getCurvePreviewName(index)
    local component = host:FindComponentByName(name)
    if component then
        return component
    end

    component = entMeshComponent.new()
    component.name = name
    component.mesh = ResRef.FromString("base\\spawner\\cube_aligned.mesh")
    component.meshAppearance = self.previewColor or "violet"
    component.visualScale = Vector3.new(0.005, 0.005, 0.005)
    component.isEnabled = self.previewed
    visualizer.bindToPlacedParent(host, component)
    host:AddComponent(component)

    return component
end

---Builds bezier segments, including the closing loop segment.
---@param pointDefs table
---@return table segments List of { defA, defB } pairs.
function spline:getCurveSegments(pointDefs)
    local segments = {}
    if #pointDefs < 2 then return segments end

    for i = 1, #pointDefs - 1 do
        table.insert(segments, { pointDefs[i], pointDefs[i + 1] })
    end

    if self.looped then
        table.insert(segments, { pointDefs[#pointDefs], pointDefs[1] })
    end

    return segments
end

---Returns bezier control points for two markers.
---@return Vector4 p0, Vector4 c0, Vector4 c1, Vector4 p1
function spline:getSegmentControlPoints(defA, defB)
    local p0 = defA.position
    local p1 = defB.position
    local c0 = utils.addVector(p0, Vector4.new(defA.tangentOut.x, defA.tangentOut.y, defA.tangentOut.z, 0))
    local c1 = utils.addVector(p1, Vector4.new(defB.tangentIn.x, defB.tangentIn.y, defB.tangentIn.z, 0))

    return p0, c0, c1, p1
end

---Estimates samples needed to keep the segment within the error tolerance.
---@param tolerance number Chord error budget in meters.
---@param maxSamples number Upper bound, from the curve quality setting.
---@return number
function spline:getSegmentSampleCount(p0, c0, c1, p1, tolerance, maxSamples)
    local deviation = math.max(chordDistance(c0, p0, p1), chordDistance(c1, p0, p1))
    if deviation <= tolerance then return 1 end

    return math.max(1, math.min(maxSamples, math.ceil(math.sqrt(0.75 * deviation / tolerance))))
end

---Returns per-segment samples and their total.
---@param segments table
---@param quality number
---@param tolerance number
---@return table samplesPerSegment, number total
function spline:getCurvePreviewPlan(segments, quality, tolerance)
    local samplesPerSegment = {}
    local total = 0

    for i, segment in ipairs(segments) do
        local p0, c0, c1, p1 = self:getSegmentControlPoints(segment[1], segment[2])
        local samples = self:getSegmentSampleCount(p0, c0, c1, p1, tolerance, quality)

        samplesPerSegment[i] = samples
        total = total + samples
    end

    return samplesPerSegment, total
end

function spline:renderCurveSegmentLine(startPos, endPos, index)
    local diff = utils.subVector(endPos, startPos)
    local length = diff:Length()
    if length <= 0.0001 then
        return false
    end

    local line = self:getCurvePreviewComponent(index)
    if not line then return false end

    local localStart = utils.subVector(startPos, self.position)
    local yaw = diff:ToRotation().yaw + 90
    local roll = diff:ToRotation().pitch

    line.visualScale = Vector3.new(math.max(0.0001, length / 2), 0.01, 0.01)
    line:SetLocalOrientation(EulerAngles.new(roll, 0, yaw):ToQuat())
    line:SetLocalPosition(Vector4.new(localStart.x, localStart.y, localStart.z, 0))
    line:Toggle(self.previewed)
    line:RefreshAppearance()

    return true
end

function spline:drawBezierPreviewSegment(defA, defB, samples, used, budget)
    local p0, c0, c1, p1 = self:getSegmentControlPoints(defA, defB)
    local prev = p0

    for i = 1, samples do
        if used >= budget then break end

        local current = self:getBezierPoint(p0, c0, c1, p1, i / samples)
        local nextUsed = used + 1
        if self:renderCurveSegmentLine(prev, current, nextUsed) then
            used = nextUsed
        end
        prev = current
    end

    return used
end

---Draws the full spline within a fixed line budget.
---@param segments table
---@param budget number
---@return number used
function spline:drawDecimatedCurvePreview(segments, budget)
    local used = 0
    local prev = nil

    for step = 0, budget do
        local position = (step / budget) * #segments
        local index = math.min(#segments, math.floor(position) + 1)
        local p0, c0, c1, p1 = self:getSegmentControlPoints(segments[index][1], segments[index][2])
        local current = self:getBezierPoint(p0, c0, c1, p1, position - (index - 1))

        if prev and used < budget then
            local nextUsed = used + 1
            if self:renderCurveSegmentLine(prev, current, nextUsed) then
                used = nextUsed
            end
        end

        prev = current
    end

    return used
end

function spline:updateCurvePreview()
    if not self:getEntity() then return end

    local pool = self:getCurvePreviewHosts()
    local used = 0
    pool.pending = false

    -- Keep existing hosts while hidden for fast reactivation.
    if self.previewed then
        local segments = self:getCurveSegments(self:getPreviewSplineMarkerDefs())
        local quality = math.floor(math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, self.curvePreviewSamples or 12)))
        local tolerance = getFlattenTolerance(quality)

        if #segments > curvePreviewComponentCeiling then
            pool:ensure(curvePreviewComponentCeiling, self.position)
            used = self:drawDecimatedCurvePreview(segments, curvePreviewComponentCeiling)
        else
            local samplesPerSegment, total = self:getCurvePreviewPlan(segments, quality, tolerance)
            pool:ensure(math.min(total, curvePreviewComponentCeiling), self.position)

            for i, segment in ipairs(segments) do
                used = self:drawBezierPreviewSegment(segment[1], segment[2], samplesPerSegment[i], used, curvePreviewComponentCeiling)
            end
        end
    end

    -- Let a spawning host redraw once its final line count is known.
    if pool.pending then return end

    for i = used + 1, self._curvePreviewComponentCount do
        local line = pool:findComponent(i, getCurvePreviewName(i))
        if line then
            line:Toggle(false)
        end
    end

    self._curvePreviewComponentCount = math.max(self._curvePreviewComponentCount, used)

    if self.previewed then
        local chunks = math.max(1, pool:getChunkCount(used))

        pool:trim(chunks)
        self._curvePreviewComponentCount = math.min(self._curvePreviewComponentCount, chunks * curvePreviewComponentsPerHost)
    end
end

function spline:onNPCSpawned(npc)
    self._followerIssue = nil

    -- Fall back to the saved default character.
    if not self.previewCharacter or not self.previewCharacter:match("^Character.") then
        self.previewCharacter = settings.defaultAISpotNPC or ""
        if not self.previewCharacter or not self.previewCharacter:match("^Character.") then
            return
        end
    end

    local defs = self:getFollowerSplineDefs()
    if #defs < 2 then
        self._followerIssue = "This spline needs at least two markers to walk."
        self:stopPreviewNPC()
        return
    end

    -- Match the preview node class to the exported node class.
    local slot = splinePool.claim(self, self.node)
    if not slot then
        self._followerIssue = splinePool.lastReason
        logger:warn("[Spline] preview NPC could not start: " .. tostring(splinePool.lastReason))
        self:stopPreviewNPC()
        return
    end

    self._followerSlot = slot
    self._followerSignature = nil

    if not self:refreshFollowerGeometry() then
        self._followerIssue = "The preview spline node could not be written."
        self:stopPreviewNPC()
        return
    end

    -- Time dilation affects all animation; movement type controls speed.
    if self.splineFollowerSpeed ~= 1 then
        npc:SetIndividualTimeDilation("", self.splineFollowerSpeed)
    end

    local points = self:getFollowerPathPoints()
    if #points > 0 then
        local start = points[1]
        local yaw = 0
        if #points > 1 then
            yaw = utils.subVector(ToVector4(points[2]), ToVector4(start)):ToRotation().yaw
        end
        Game.GetTeleportationFacility():Teleport(npc, ToVector4(start), EulerAngles.new(0, 0, yaw))
    end

    if not self:sendSplineCommand(npc) then
        self._followerIssue = "The character would not take the spline command."
        self:stopPreviewNPC()
        return
    end

    self._followerRebuildTimer = 0

    self.cronID = Cron.OnUpdate(function()
        if not self.npcID or not self:isSpawned() or not self._followerPlaying then return end

        local follower = self:getNPC()
        if not follower then return end

        -- Periodically sync dragged markers into the active walk.
        local moved = false
        self._followerRebuildTimer = (self._followerRebuildTimer or 0) + (Cron.deltaTime or 0)
        if self._followerRebuildTimer >= followerGeometryInterval then
            self._followerRebuildTimer = 0
            moved = self:refreshFollowerGeometry()
        end

        -- Restart looped or edited runs; finish completed open splines.
        if not self:isFollowerCommandRunning() and not self._followerCleanupID then
            if self.looped or moved then
                self:sendSplineCommand(follower)
            else
                -- Briefly hold at the end before cleanup.
                self._followerCommand = nil
                self:scheduleFollowerCleanup()
            end
        end
    end)
end

function spline:onAssemble(entity)
    visualized.onAssemble(self, entity)
    self:updateCurvePreview()

    if self._followerResume then
        self._followerResume = false
        self:startPreviewNPC()
    end
end

---Spawns the preview character and starts movement.
---@return boolean started
function spline:startPreviewNPC()
    if self._followerPlaying then return false end

    self._followerIssue = nil

    if not self.previewCharacter or not self.previewCharacter:match("^Character.") then
        self.previewCharacter = settings.defaultAISpotNPC or ""
    end

    if not self.previewCharacter:match("^Character.") then
        self._followerIssue = "Set a Character record before playing the preview."
        return false
    end

    local points = self:getFollowerPathPoints()
    if #points < 2 then
        self._followerIssue = "This spline needs at least two markers to walk."
        return false
    end

    self._followerPlaying = true

    local spawnPos = ToVector4(points[1])

    local spec = DynamicEntitySpec.new()
    spec.recordID = self.previewCharacter
    spec.position = spawnPos
    spec.orientation = EulerAngles.new(0, 0, 0):ToQuat()
    spec.alwaysSpawned = true
    self.npcID = Game.GetDynamicEntitySystem():CreateEntity(spec)
    self.npcSpawning = true

    builder.registerAttachCallback(self.npcID, function(entity)
        self:onNPCSpawned(entity)
    end)

    local appCacheKey = self.previewCharacter .. "_apps"
    cache.tryGet(appCacheKey)
    .notFound(function(task)
        local finished = false
        local function complete(apps)
            if finished then return end
            finished = true

            cache.addValue(appCacheKey, apps or {})
            task:taskCompleted()
        end

        local templateFlat = TweakDB:GetFlat(self.previewCharacter .. ".entityTemplatePath")
        local templateHash = templateFlat and templateFlat.hash
        if not templateHash then
            complete({})
            return
        end

        local templateResRef = ResRef.FromHash(templateHash)
        local depot = Game.GetResourceDepot()
        local exists = false
        if depot then
            pcall(function()
                exists = depot:ResourceExists(templateResRef)
            end)
        end
        if not exists then
            complete({})
            return
        end

        local ok = pcall(function()
            builder.registerLoadResource(templateResRef, function(resource)
                local apps = {}
                if resource and resource.appearances then
                    for _, appearance in ipairs(resource.appearances) do
                        if appearance and appearance.name and appearance.name.value then
                            table.insert(apps, appearance.name.value)
                        end
                    end
                end

                complete(apps)
            end)
        end)
        if not ok then
            complete({})
        end
    end)
    .found(function()
        self.apps = cache.getValue(appCacheKey) or {}
    end)

    return true
end

---Stops the preview, removes its character, and releases its node.
function spline:stopPreviewNPC()
    if self._followerCleanupID then
        Cron.Halt(self._followerCleanupID)
        self._followerCleanupID = nil
    end

    if self.cronID then
        Cron.Halt(self.cronID)
        self.cronID = nil
    end

    self._followerCommand = nil
    self._followerRebuildTimer = 0
    self._followerSignature = nil
    self._followerPlaying = false

    -- Release the node; its unused geometry can remain.
    splinePool.release(self)
    self._followerSlot = nil

    if self.npcID then
        Game.GetDynamicEntitySystem():DeleteEntity(self.npcID)
        self.npcID = nil
    end

    self.npcSpawning = false
end

---Schedules cleanup after the arrival delay.
function spline:scheduleFollowerCleanup()
    if self._followerCleanupID then return end

    self._followerCleanupID = Cron.After(followerCleanupDelay, function()
        self._followerCleanupID = nil
        self:stopPreviewNPC()
    end)
end

function spline:despawn()
    visualized.despawn(self)

    self:getCurvePreviewHosts():despawn()
    self._curvePreviewComponentCount = 0

    -- Resume an active preview after spline respawn.
    self._followerResume = self._followerPlaying
    self:stopPreviewNPC()
end

function spline:spawn()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.spawn(self)
end

function spline:update()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.update(self)
    self:getCurvePreviewHosts():updateTransforms(self.position)
    self:updateCurvePreview()
end

function spline:getTransformUIConfig()
    return {
        showRotation = false,
        showScale = false
    }
end

function spline:setPreview(state)
    visualized.setPreview(self, state)
    self:updateCurvePreview()
end

function spline:save()
    local data = visualized.save(self)

    local pointDefs = self:getSplineMarkerDefs()
    if #pointDefs == 0 and self.pointDefs and #self.pointDefs > 0 then
        pointDefs = utils.deepcopy(self.pointDefs)
    end
    if #pointDefs == 0 and self.points and #self.points > 0 then
        for _, point in ipairs(self.points) do
            table.insert(pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    local points = {}
    local savedPointDefs = {}
    for _, pointDef in ipairs(pointDefs) do
        local position = utils.fromVector(pointDef.position)
        local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }

        table.insert(points, position)
        table.insert(savedPointDefs, {
            position = position,
            tangentIn = {
                x = tonumber(tangentIn.x) or 0,
                y = tonumber(tangentIn.y) or 0,
                z = tonumber(tangentIn.z) or 0
            },
            tangentOut = {
                x = tonumber(tangentOut.x) or 0,
                y = tonumber(tangentOut.y) or 0,
                z = tonumber(tangentOut.z) or 0
            },
            automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents
        })
    end

    data.splinePath = self.splinePath
    data.points = points
    data.pointDefs = savedPointDefs
    data.reverse = self.reverse
    data.looped = self.looped
    data.previewCharacter = self.previewCharacter
    data.splineFollowerSpeed = self.splineFollowerSpeed
    data.splineMoveType = self.splineMoveType
    data.splineIgnoreNavigation = self.splineIgnoreNavigation
    data.curvePreviewSamples = self.curvePreviewSamples

    return data
end

function spline:loadSplinePaths()
    local paths = {}
    local ownRoot = self.object:getRootParent()

    for _, container in pairs(self.object.sUI.containerPaths) do
        if container.ref:getRootParent() == ownRoot then
            local nMarkers = 0
            for _, child in pairs(container.ref.childs) do
                if utils.isA(child, "spawnableElement") and child.spawnable.modulePath == "meta/splineMarker" then
                    nMarkers = nMarkers + 1
                end

                if nMarkers == 2 then
                    table.insert(paths, container.path)
                    break
                end
            end
        end
    end

    return paths
end

function spline:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize position", "Curve Quality", "Spline Path", "Spline Length", "Reverse", "Looped", "Preview NPC", "Preview NPC Record", "Movement Type", "Ignore Navmesh", "Time Dilation" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    local paths = self:loadSplinePaths()
    table.insert(paths, 1, "None")

    local index = math.max(1, utils.indexValue(paths, self.splinePath))

    style.mutedText("Spline Path")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local idx, changed = style.trackedCombo(self.object, "##splinePath", index - 1, paths, 225, {
        tooltip = "Path to the group containing the spline points.\nMust be contained within the same root group as this spline."
    })
    if changed then
        self.splinePath = paths[idx + 1]
        if self.object and self.object.sUI and self.object.sUI.bumpWireframeEpoch then
            self.object.sUI.bumpWireframeEpoch()
        end
        self:respawn()
    end
    style.mutedText("Spline Length")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    ImGui.Text(string.format("%.2fm", self:getTotalLength()))
    style.tooltip("Total spline length based on current curve sampling.")

    style.mutedText("Reverse")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local changed
    self.reverse, changed = style.trackedCheckbox(self.object, "##reverse", self.reverse)
    if changed then
        self:updateCurvePreview()
        -- Reverse through the command without respawning.
        self:restartFollowerCommand()
    end

    style.mutedText("Looped")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.looped, changed = style.trackedCheckbox(self.object, "##looped", self.looped)
    if changed then
        self:refreshLinkedMarkerTangents(true)
        self:respawn()
    end

    if ImGui.TreeNodeEx("Previewing Options", ImGuiTreeNodeFlags.SpanFullWidth) then
        local previewPropertyWidth = self.maxPropertyWidth + ImGui.GetTreeNodeToLabelSpacing()

        self:drawPreviewCheckbox("Preview Spline", previewPropertyWidth)

        style.mutedText("Curve Quality")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        local finished
        self.curvePreviewSamples, changed, finished = style.trackedDragInt(self.object, "##curvePreviewSamples", self.curvePreviewSamples, minCurvePreviewSamples, maxCurvePreviewSamples, 60)
        style.tooltip("Preview accuracy. Samples are spent where the curve actually bends, so\nstraight runs stay cheap no matter how many points the spline has.")
        if changed then
            self:updateCurvePreview()
        end
        if finished then
            self:respawn()
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        ImGui.PushID("saveCurveQuality")
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultSplineCurveQuality = math.floor(math.max(minCurvePreviewSamples, math.min(maxCurvePreviewSamples, self.curvePreviewSamples or 12)))
            settings.save()
        end
        ImGui.PopID()
        style.tooltip("Save this curve quality as the default for Spline previews.")
        style.pushButtonNoBG(false)

        style.mutedText("Preview NPC")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)

        -- Playback is a one-shot runtime action.
        local spawned = self:isSpawned()
        style.pushGreyedOut(not spawned)
        if self._followerPlaying then
            if style.dangerButton(IconGlyphs.Stop .. " Stop##splineFollower", 120 * style.viewSize, 0) and spawned then
                self:stopPreviewNPC()
            end
            style.tooltip("Remove the preview character and free the spline node it is walking.")
        else
            if ImGui.Button(IconGlyphs.Play .. " Play##splineFollower", 120 * style.viewSize, 0) and spawned then
                self:startPreviewNPC()
            end
            style.tooltip("Walks a character along the spline using the game's own spline movement, so\nthe path shown is the one an AIMoveOnSpline command would take.\nAn open spline clears itself a couple of seconds after the character arrives.")
        end
        style.popGreyedOut(not spawned)

        if self._followerIssue then
            -- Wrap errors so important instructions remain visible.
            style.styledTextWrapped(IconGlyphs.AlertOutline .. "  " .. self._followerIssue, style.warnColor)
        elseif not splinePool.hasNativeTangents() then
            style.styledText(IconGlyphs.AlertOutline .. "  Approximated tangents", style.extraMutedColor)
            style.tooltip("The WorldBuilderTools plugin is not loaded, so the preview node cannot be given\nthe authored tangents and the engine fits its own. Markers left on automatic\ntangents are unaffected; hand-edited ones will walk a slightly different curve.")
        end

        style.mutedText("Preview NPC Record")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.previewCharacter, _, finished = style.trackedTextField(self.object, "##previewCharacter", self.previewCharacter, "Character.", 200)
        -- Restart the run when its character changes.
        if finished and self._followerPlaying then
            self:stopPreviewNPC()
            self:startPreviewNPC()
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultAISpotNPC = self.previewCharacter
            settings.save()
        end
        style.tooltip("Save this character as the default for Spline previews.")
        style.pushButtonNoBG(false)

        -- These settings also update a live command.
        local npc = self:getNPC()

        local movementTypes = { "Walk", "Sprint" }
        local moveTypeIndex = math.max(1, utils.indexValue(movementTypes, self.splineMoveType))
        style.mutedText("Movement Type")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        local moveIdx
        moveIdx, changed = style.trackedCombo(self.object, "##splineMoveType", moveTypeIndex - 1, movementTypes, 120)
        if changed then
            self.splineMoveType = movementTypes[moveIdx + 1]
            -- The move handler picks this up without a respawn.
            if self._followerCommand then
                self._followerCommand.movementType = self:buildFollowerMovementType()
            end
        end

        style.mutedText("Ignore Navmesh")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.splineIgnoreNavigation, changed = style.trackedCheckbox(self.object, "##splineIgnoreNavigation", self.splineIgnoreNavigation)
        style.tooltip("On: follows the curve exactly, even through geometry.\nOff: follows the navmesh and stops at obstacles. Use this to test if the spline is walkable.")
        if changed and self._followerCommand then
            self._followerCommand.ignoreNavigation = self.splineIgnoreNavigation
        end

        style.mutedText("Time Dilation")
        ImGui.SameLine()
        ImGui.SetCursorPosX(previewPropertyWidth)
        self.splineFollowerSpeed, changed, _ = style.trackedDragFloat(self.object, "##splineFollowerSpeed", self.splineFollowerSpeed, 0.1, 0, 5, "%.2f", 60)
        style.tooltip("Change animation speed.")
        if changed and npc then
            npc:SetIndividualTimeDilation("", self.splineFollowerSpeed)
        end
        ImGui.SameLine()
        style.pushButtonNoBG(true)

        ImGui.PushID("saveSpeed")
        if ImGui.Button(IconGlyphs.ContentSaveSettingsOutline) then
            settings.defaultAISpotSpeed = self.splineFollowerSpeed
            settings.save()
        end
        ImGui.PopID()

        style.tooltip("Save this speed as the default for Spline previews.")
        style.pushButtonNoBG(false)

        ImGui.TreePop()
    end
end

function spline:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
end

function spline:export()
    local data = visualized.export(self)
    data.type = "worldSplineNode"
    data.data = {}

    local pointDefs = {}
    if self.pointDefs and #self.pointDefs > 0 then
        pointDefs = utils.deepcopy(self.pointDefs)
    elseif self.points and #self.points > 0 then
        for _, point in pairs(self.points) do
            table.insert(pointDefs, {
                position = point,
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            })
        end
    end

    if #pointDefs == 0 then
        table.insert(self.object.sUI.spawner.baseUI.exportUI.exportIssues.noSplineMarker, self.object.name)

        return data
    end

    local points = {}

    for _, pointDef in pairs(pointDefs) do
        local position = utils.subVector(ToVector4(pointDef.position), self.position)
        local tangentIn = pointDef.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = pointDef.tangentOut or { x = 0, y = 0, z = 0 }
        local automaticTangents = pointDef.automaticTangents == nil and true or pointDef.automaticTangents

        table.insert(points, {
            ["$type"] = "SplinePoint",
            ["position"] = {
                ["$type"] = "Vector3",
                ["X"] = position.x,
                ["Y"] = position.y,
                ["Z"] = position.z
            },
            ["automaticTangents"] = automaticTangents and 1 or 0,
            ["tangents"] = {
                ["Elements"] = {
                    {
                        ["$type"] = "Vector3",
                        ["X"] = tonumber(tangentIn.x) or 0,
                        ["Y"] = tonumber(tangentIn.y) or 0,
                        ["Z"] = tonumber(tangentIn.z) or 0
                    },
                    {
                        ["$type"] = "Vector3",
                        ["X"] = tonumber(tangentOut.x) or 0,
                        ["Y"] = tonumber(tangentOut.y) or 0,
                        ["Z"] = tonumber(tangentOut.z) or 0
                    }
                }
            }
        })
    end

    data.data = {
        ["splineData"] = {
            ["Data"] = {
                ["$type"] = "Spline",
                ["points"] = points,
                ["reversed"] = self.reverse and 1 or 0,
                ["looped"] = self.looped and 1 or 0
            }
        }
    }

    return data
end

return spline
