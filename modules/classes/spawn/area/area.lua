local visualized = require("modules/classes/spawn/visualized")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local logger = require("modules/utils/core/logger")
local element = require("modules/classes/editor/element")
local outlineConsumer = require("modules/utils/game/outlineConsumer")

---Class for worldAreaShapeNode
---@class area : visualized
---@field outlinePath string
---@field height number
---@field markers table
---@field protected maxPropertyWidth number
local area = setmetatable({}, { __index = visualized })

---Compatibility wrappers for the shared outline consumer helper.

function area.invalidateOutlineConsumers()
    outlineConsumer.invalidate()
end

---Notifies every consumer referencing an outline group that its geometry changed.
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

    -- `spawnable.loadSpawnData` assigns tables by reference, and its payloads outlive the load
    -- (project cache, clipboard), so two areas would otherwise share one marker table.
    self.markers = utils.deepcopy(self.markers)

    -- Loading a project, pasting, or undoing an edit can all point this area at a different outline.
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
    local idx, changed = style.trackedCombo(self.object, "##outlinePath", index - 1, paths, 225)
    if changed then
        self.outlinePath = paths[idx + 1]
        element.bumpWireframeEpoch(self.object)
        area.invalidateOutlineConsumers()
        self:onOutlineChanged()
    end
    style.tooltip("Path to the group containing the outline markers.\nMust be contained within the same root group as this area.")
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
                -- Outline points are stored as local coords in the node. Convert world-space
                -- marker offsets into the node's local frame when a rotation is provided.
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
