local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")
local utils = require("modules/utils/utils")
local visualizer = require("modules/utils/visualizer")

local occluderPaths = {
    { name = "Box", path = "engine\\meshes\\editor\\box_occluder.w2mesh" },
    { name = "Plane One-Sided", path = "engine\\meshes\\editor\\plane_occluder_onesided_xz.mesh" },
    { name = "Plane Two-Sided", path = "engine\\meshes\\editor\\plane_occluder_twosided_xz.mesh" }
}

---Class for worldStaticOccluderMeshNode
---@class occluder : spawnable
---@field public scale {x: number, y: number, z: number}
---@field public occluderType integer
---@field public occluderMesh integer
---@field private previewed boolean
---@field private occluderTypes table
local occluder = setmetatable({}, { __index = spawnable })

function occluder:new()
	local o = spawnable.new(self)

    o.spawnListType = "files"
    o.dataType = "Static Occluder"
    o.spawnDataPath = "data/spawnables/meta/occluder/"
    o.modulePath = "meta/occluder"
    o.node = "worldStaticOccluderMeshNode"
    o.description = "Places an occluder of variable size and shape, which will cause anything completely behind it to not be rendered."
    o.icon = IconGlyphs.CubeOffOutline

    o.occluderTypes = utils.enumTable("visWorldOccluderType")

    o.scaleLocked = false
    o.scale = { x = 1, y = 1, z = 1 }
    o.occluderType = 0
    o.occluderMesh = 1
    o.previewed = true

    o.uk10 = 1120
    o.uk11 = 640

    setmetatable(o, { __index = self })
   	return o
end

function occluder:onAssemble(entity)
    spawnable.onAssemble(self, entity)

    local scale = self.scale
    if self.occluderMesh == 2 or self.occluderMesh == 3 then
        scale = { x = scale.x, y = 0.01, z = scale.z }
    end
    visualizer.addBox(entity, scale, "green")

    local component = entStaticOccluderMeshComponent.new()
    component.name = "occluder"
    ResourceHelper.LoadReferenceResource(component, "mesh", occluderPaths[self.occluderMesh].path, true)
    component.scale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)
    component.occluderType = Enum.new("visWorldOccluderType", self.occluderType)
    entity:AddComponent(component)

    visualizer.updateScale(entity, self:getVisualizerSize(), "arrows")
    visualizer.toggleAll(entity, self.previewed)
end

function occluder:spawn()
    self.spawnData = "base\\spawner\\empty_entity.ent"
    spawnable.spawn(self)
end

function occluder:save()
    local data = spawnable.save(self)

    data.scale = { x = self.scale.x, y = self.scale.y, z = self.scale.z }
    data.occluderType = self.occluderType
    data.occluderMesh = self.occluderMesh
    data.previewed = self.previewed

    return data
end

---@protected
function occluder:updateScale(finished)
    if finished then
        self:respawn()
        return
    end

    local entity = self:getEntity()
    if not entity then return end

    local scale = self.scale
    if self.occluderMesh == 2 or self.occluderMesh == 3 then
        scale = { x = scale.x, y = 0.01, z = scale.z }
    end

    visualizer.updateScale(entity, self:getVisualizerSize(), "arrows")
    visualizer.updateScale(entity, scale, "box")
end

function occluder:getSize()
    return self.scale
end

function occluder:getVisualizerSize()
    local size = self:getSize()

    local max = math.min(math.max(size.x, size.y, size.z, 1.5) * 0.5, 3)
    return { x = max, y = max, z = max }
end

function occluder:draw()
    spawnable.draw(self)

    self.previewed, changed = style.trackedCheckbox(self.object, "Visualize outline", self.previewed)
    if changed then
        visualizer.toggleAll(self:getEntity(), self.previewed)
    end

    local names = {}
    for _, path in ipairs(occluderPaths) do
        table.insert(names, path.name)
    end

    ImGui.Text("Occluder Mesh")
    ImGui.SameLine()
    local value, changed = style.trackedCombo(self.object, "##occluderMesh", self.occluderMesh - 1, names)
    if changed then
        self.occluderMesh = value + 1
        self:respawn()
    end

    ImGui.Text("Occluder Type")
    ImGui.SameLine()
    self.occluderType, changed = style.trackedCombo(self.object, "##occluderType", self.occluderType, self.occluderTypes)
    if changed then
        local entity = self:getEntity()

        if entity then
            local component = entity:FindComponentByName("occluder")
            component.occluderType = Enum.new("visWorldOccluderType", self.occluderType)
        end
    end
end

function occluder:getProperties()
    local properties = spawnable.getProperties(self)
    table.insert(properties, {
        id = self.node,
        name = self.dataType,
        defaultHeader = true,
        draw = function()
            self:draw()
        end
    })
    return properties
end

function occluder:getGroupedProperties()
    local properties = spawnable.getGroupedProperties(self)

    properties["visualization"] = {
		name = "Visualization",
        id = "occluder",
		data = {},
		draw = function(_, entries)
            ImGui.Text("Occluder")

            ImGui.SameLine()

            ImGui.PushID("occluder")

			if ImGui.Button("Off") then
				for _, entry in ipairs(entries) do
                    if entry.spawnable.node == "worldStaticOccluderMeshNode" then
                        entry.spawnable.previewed = false
                        visualizer.toggleAll(entry.spawnable:getEntity(), entry.spawnable.previewed)
                    end
				end
			end

            ImGui.SameLine()

            if ImGui.Button("On") then
				for _, entry in ipairs(entries) do
                    if entry.spawnable.node == "worldStaticOccluderMeshNode" then
                        entry.spawnable.previewed = true
                        visualizer.toggleAll(entry.spawnable:getEntity(), entry.spawnable.previewed)
                    end
				end
			end

            ImGui.PopID()
		end,
		entries = { self.object }
	}

    return properties
end

function occluder:export()
    local data = spawnable.export(self)
    data.type = "worldStaticOccluderMeshNode"
    data.scale = self.scale
    data.data = {
        ["occluderType"] = self.occluderTypes[self.occluderType + 1],
        ["mesh"] = {
            ["DepotPath"] = {
                ["$type"] = "ResourcePath",
                ["$storage"] = "string",
                ["$value"] = occluderPaths[self.occluderMesh].path
            },
            Flags = "Default"
        }
    }

    return data
end

return occluder