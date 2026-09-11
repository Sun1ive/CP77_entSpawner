local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local logger = require("modules/utils/core/logger")
local element = require("modules/classes/editor/element")
local outlineConsumer = require("modules/utils/game/outlineConsumer")
local history = require("modules/utils/project/history")

---Class for worldAreaShapeNode
---@class area : visualized
---@field outlinePath string
---@field height number
---@field markers table
---@field protected maxPropertyWidth number
local area = setmetatable({}, { __index = visualized })

---Aliases for the shared outline helper.

function area.invalidateOutlineConsumers()
    outlineConsumer.invalidate()
end

---Notifies consumers that an outline changed.
---@param object element Element inside the outline group, usually an outline marker.
---@param parentOverride element? Group to notify for, when the marker just left or entered one.
function area.notifyOutlineChanged(object, parentOverride)
    outlineConsumer.notifyChanged(object, parentOverride)
end

function area:new()
	local o = visualized.new(self)

    o.spawnListType = "files"
    o.dataType = "Area"
    o.spawnDataPath = "data/spawnables/area/area/"
    o.modulePath = "area/area"
    o.node = "worldAreaShapeNode"
    o.description = "Base type for all area type nodes. Position is irrelevant, as the actual position is determined by the outline markers."
    o.icon = IconGlyphs.Select

    o.previewed = true
    o.previewColor = "cyan"
    o.outlinePath = ""

    -- Only used for saved data, to have easier access to it during export
    o.height = 0
    o.markers = {}

    o.maxPropertyWidth = nil

    setmetatable(o, { __index = self })
   	return o
end

function area:spawn()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.spawn(self)
end

function area:loadSpawnData(data, position, rotation)
    visualized.loadSpawnData(self, data, position, rotation)

    -- Copy markers because load payloads may be reused.
    self.markers = utils.deepcopy(self.markers)

    -- Loads, pastes, and undo may change the binding.
    area.invalidateOutlineConsumers()
end

function area:update()
    self.rotation = EulerAngles.new(0, 0, 0)
    visualized.update(self)
end

function area:getTransformUIConfig()
    return {
        showRotation = false
    }
end

---Called when the referenced outline changes.
---@protected
function area:onOutlineChanged()
end

function area:getMarkersData()
    return outlineConsumer.getMarkers(self)
end

function area:save()
    local data = visualized.save(self)

    data.outlinePath = self.outlinePath
    data.markers, data.height = self:getMarkersData()

    return data
end

function area:loadOutlinePaths()
    return outlineConsumer.loadPaths(self)
end

---Refreshes data derived from this area's outline.
function area:refreshOutline()
    element.bumpWireframeEpoch(self.object)
    area.invalidateOutlineConsumers()
    self:onOutlineChanged()
end

---Points this area at an outline group.
---@param outlineGroup element
function area:bindOutline(outlineGroup)
    self.outlinePath = outlineGroup and outlineGroup.getPath and outlineGroup:getPath() or ""
    self:refreshOutline()
end

---@return boolean
function area:canEditOutline()
    return self.object ~= nil and self.object.parent ~= nil and not self.object:isLocked()
end

---Returns a parent that lets the area and outline share a root group.
---@return element? parent
---@return table? wrapAction History action for the wrap, nil when no wrap was needed
function area:getOutlineParent()
    if not self.object then return nil, nil end

    return self.object:ensureParentGroup()
end

---Builds a square outline group next to this area and binds it.
---@return element? outlineGroup
function area:generateSquareOutline()
    if not self:canEditOutline() then return nil end

    local parent, wrapAction = self:getOutlineParent()
    if not parent then return nil end

    -- Snapshot before rebinding so undo restores the old outline.
    local areaChange = history.getElementChange(self.object)
    local outlineGroup = outlineConsumer.createMarkerGroup(self, parent, {
        offsets = outlineConsumer.getSquareOffsets(),
        height = outlineConsumer.NEW_OUTLINE_HEIGHT
    })

    if not outlineGroup then return nil end

    self:bindOutline(outlineGroup)

    local actions = { areaChange, history.getInsert({ outlineGroup }) }
    if wrapAction then
        table.insert(actions, 1, wrapAction)
    end

    history.addAction(history.getComposite(actions))

    return outlineGroup
end

---Adds a marker, creating and binding an outline when needed.
---@param position Vector4? World position
---@return element? markerElement
function area:addOutlinePoint(position)
    if not position or not self:canEditOutline() then return nil end

    local outlineGroup = outlineConsumer.getGroup(self)
    local areaChange, wrapAction = nil, nil

    if not outlineGroup then
        local parent
        parent, wrapAction = self:getOutlineParent()
        if not parent then return nil end

        areaChange = history.getElementChange(self.object)
        outlineGroup = outlineConsumer.createMarkerGroup(self, parent)

        if not outlineGroup then return nil end

        self:bindOutline(outlineGroup)
    end

    local markerElement = outlineConsumer.addMarker(self, outlineGroup, position, outlineConsumer.NEW_OUTLINE_HEIGHT)
    if not markerElement then return nil end

    self:refreshOutline()

    if areaChange then
        -- The group is new, so its insert carries the marker with it.
        local actions = { areaChange, history.getInsert({ outlineGroup }) }
        if wrapAction then
            table.insert(actions, 1, wrapAction)
        end

        history.addAction(history.getComposite(actions))
    else
        history.addAction(history.getInsert({ markerElement }))
    end

    return markerElement
end

---@return boolean
function area:isPlacingOutlinePoints()
    local sUI = self.object and self.object.sUI or nil

    return sUI ~= nil
        and type(sUI.isHierarchyPickActive) == "function"
        and sUI.isHierarchyPickActive(self.object) == true
end

---Starts click-to-place outline markers.
---@return boolean started
function area:beginOutlinePointPlacement()
    local sUI = self.object and self.object.sUI or nil

    if not sUI or type(sUI.beginHierarchyPick) ~= "function" then
        return false
    end

    return sUI.beginHierarchyPick(self.object, function(target)
        -- Stop if this area's panel is no longer available.
        if not self:canEditOutline() or self.object.selected ~= true then
            return true
        end

        self:addOutlinePoint(target:getPosition())

        -- Keep the pick armed until the button or Esc ends it.
        return false
    end, {
        -- Accept only the editor's world-position pick.
        canPick = function(target)
            return type(target) == "table" and target.id == nil and type(target.getPosition) == "function"
        end,
        -- Ignore existing markers so later clicks still reach the world.
        getWorldExcludeIds = function()
            local ids = {}
            local outlineGroup = outlineConsumer.getGroup(self)

            for _, child in ipairs(outlineGroup and outlineGroup.childs or {}) do
                if child.id then
                    ids[child.id] = true
                end
            end

            return ids
        end,
        restoreOwnerSelection = false
    })
end

function area:cancelOutlinePointPlacement()
    local sUI = self.object and self.object.sUI or nil

    if sUI and type(sUI.cancelHierarchyPick) == "function" then
        sUI.cancelHierarchyPick(self.object)
    end
end

function area:getMarkersCenter()
    local markers = self.markers
    local center = Vector4.new(0, 0, 0, 0)
    local nMarkers = math.max(1, #markers)

	for _, position in ipairs(markers) do
		center = utils.addVector(center, ToVector4(position))
	end

    return Vector4.new(center.x / nMarkers, center.y / nMarkers, center.z / nMarkers, 0)
end

function area:draw()
    visualized.draw(self)

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth({ "Visualize", "Outline Path" }) + 2 * ImGui.GetStyle().ItemSpacing.x + ImGui.GetCursorPosX()
    end

    self:drawPreviewCheckbox("Visualize", self.maxPropertyWidth)

    local paths = self:loadOutlinePaths()
    table.insert(paths, 1, "None")

    local index = math.max(1, utils.indexValue(paths, self.outlinePath))

    style.mutedText("Outline Path")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    local idx, changed = style.trackedCombo(self.object, "##outlinePath", index - 1, paths, 225, {
        tooltip = "Path to the group containing the outline markers.\nMust be contained within the same root group as this area."
    })
    if changed then
        self.outlinePath = paths[idx + 1]
        self:refreshOutline()
    end

    self:drawOutlineActions()
end

---Draws outline creation controls.
---@protected
function area:drawOutlineActions()
    local editable = self:canEditOutline()
    local placing = self:isPlacingOutlinePoints()

    -- Cancel picks when the area is locked.
    if placing and not editable then
        self:cancelOutlinePointPlacement()
        placing = false
    end

    ImGui.SameLine()
    style.pushButtonNoBG(true)
    ImGui.BeginDisabled(not editable or placing)
    if ImGui.Button(IconGlyphs.VectorSquare .. "##generateOutlineSquare") then
        self:generateSquareOutline()
    end
    ImGui.EndDisabled()
    style.pushButtonNoBG(false)
    style.tooltip(
        string.format(
            "Generate a new outline group of four markers, %.0fm to each side of this area, and use it.",
            outlineConsumer.NEW_OUTLINE_RADIUS
        ),
        ImGuiHoveredFlags.AllowWhenDisabled
    )

    ImGui.SameLine()
    ImGui.BeginDisabled(not editable)
    local nextPlacing, placingChanged = style.toggleButton(IconGlyphs.MapMarkerPlusOutline .. "##addOutlinePoint", placing)
    ImGui.EndDisabled()

    if placingChanged then
        if nextPlacing then
            self:beginOutlinePointPlacement()
        else
            self:cancelOutlinePointPlacement()
        end
    end

    if not editable then
        style.tooltip("Unlock this area to add outline points.", ImGuiHoveredFlags.AllowWhenDisabled)
    elseif placing then
        style.tooltip("Click in the world to drop an outline marker there.\nPress Esc or this button again to stop.", ImGuiHoveredFlags.AllowWhenDisabled)
    else
        style.tooltip("Add outline markers by clicking in the world.\nCreates a new outline group when this area has none.", ImGuiHoveredFlags.AllowWhenDisabled)
    end
end

function area:getProperties()
    return self:addNodeProperty(visualized.getProperties(self))
end

---@protected
---@return Quaternion?
function area:getOutlineLocalRotationForExport()
    return nil
end

function area:export(_, _, markersZOffset)
    local data = visualized.export(self)
    data.type = "worldAreaShapeNode"
    data.data = {}
    local markers = self.markers
    local outlineLocalRotation = self:getOutlineLocalRotationForExport()

    if #markers == 0 then
        local issues = self.object.sUI.spawner.baseUI.exportUI.exportIssues
        table.insert(issues.noOutlineMarkers, self.object.name)

        return data
    end

    if #markers > 255 then
        logger:warn(string.format("Issue during export: Area outline %s has more than 255 markers. Only the first 255 will be utilized.", self.outlinePath))
    end

    -- Grab center
    local center = self:getMarkersCenter()
    data.position = utils.fromVector(center)

    local buffer = utils.intToHex(math.min(255, #markers))
    buffer = buffer .. "000000"

    for idx, marker in ipairs(markers) do
        if idx <= 255 then
            local diff = utils.subVector(ToVector4(marker), center)
            if outlineLocalRotation and outlineLocalRotation.TransformInverse then
                -- Convert world marker offsets to the node's local frame.
                diff = outlineLocalRotation:TransformInverse(diff)
            end

            buffer = buffer .. utils.floatToHex(diff.x)
            buffer = buffer .. utils.floatToHex(diff.y)
            buffer = buffer .. utils.floatToHex(diff.z + (markersZOffset or 0))
            buffer = buffer .. utils.floatToHex(1)
        end
    end

    buffer = buffer .. utils.floatToHex(self.height)

    data.data["outline"] = {
        ["Data"] = {
            ["$type"] = "AreaShapeOutline",
            ["buffer"] = utils.hexToBase64(buffer),
        }
    }

    return data
end

return area
