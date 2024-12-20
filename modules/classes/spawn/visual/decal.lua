local spawnable = require("modules/classes/spawn/spawnable")
local style = require("modules/ui/style")

---Class for worldStaticDecalNode
---@class decal : spawnable
---@field private alpha number
---@field private horizontalFlip boolean
---@field private verticalFlip boolean
---@field private autoHideDistance number
---@field private scale {x: number, y: number, z: number}
---@field private scaleLocked boolean
local decal = setmetatable({}, { __index = spawnable })

function decal:new()
	local o = spawnable.new(self)

    o.spawnListType = "list"
    o.dataType = "Decals"
    o.spawnDataPath = "data/spawnables/visual/decals/"
    o.modulePath = "visual/decal"
    o.node = "worldStaticDecalNode"
    o.description = "Places a decal on the nearest surface, from a given .mi file"
    o.icon = IconGlyphs.StickerOutline

    o.alpha = 1
    o.horizontalFlip = false
    o.verticalFlip = false
    o.autoHideDistance = 150
    o.scale = { x = 1, y = 1, z = 1 }

    o.scaleLocked = true

    setmetatable(o, { __index = self })
   	return o
end

function decal:onAssemble(entity)
    spawnable.onAssemble(self, entity)

    local component = entDecalComponent.new()
    ResourceHelper.LoadReferenceResource(component, "material", self.spawnData, true)

    component.alpha = self.alpha
    component.horizontalFlip = self.horizontalFlip
    component.verticalFlip = self.verticalFlip
    component.autoHideDistance = self.autoHideDistance
    component.aspectRatio = 1
    component.name = "decal"
    component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)

    entity:AddComponent(component)
end

function decal:spawn()
    local decal = self.spawnData
    self.spawnData = "base\\spawner\\empty_entity.ent"

    spawnable.spawn(self)
    self.spawnData = decal
end

function decal:save()
    local data = spawnable.save(self)
    data.alpha = self.alpha
    data.horizontalFlip = self.horizontalFlip
    data.verticalFlip = self.verticalFlip
    data.autoHideDistance = self.autoHideDistance
    data.scale = { x = self.scale.x, y = self.scale.y, z = self.scale.z }
    data.scaleLocked = self.scaleLocked

    return data
end

function decal:getVisualizerSize()
    local max = math.min(math.max(self.scale.x, self.scale.y, self.scale.z, 1) * 0.5, 3.5)
    return { x = max, y = max, z = max }
end

function decal:getSize()
    return self.scale
end

function decal:updateScale()
    local entity = self:getEntity()
    if not entity then return end

    local component = entity:FindComponentByName("decal")
    component.visualScale = Vector3.new(self.scale.x, self.scale.y, self.scale.z)

    component:Toggle(false)
    component:Toggle(true)
end

---Respawn the decal to update parameters, if changed
---@param changed boolean
---@protected
function decal:updateFull(changed)
    if changed and self:isSpawned() then self:respawn() end
end

function decal:draw()
    spawnable.draw(self)

    ImGui.PushItemWidth(150 * style.viewSize)

    self.alpha, changed, deactivatedAfterEdit = style.trackedDragFloat(self.object, "##alpha", self.alpha, 0.01, 0, 100, "%.2f Alpha")
    self:updateFull(deactivatedAfterEdit)

    ImGui.SameLine()
    self.autoHideDistance = style.trackedDragFloat(self.object, "##autoHideDistance", self.autoHideDistance, 0.05, 0, 9999, "%.2f Hide Dist.", 100)

    self.verticalFlip, changed = style.trackedCheckbox(self.object, "Vertical Flip", self.verticalFlip)
    self:updateFull(ImGui.IsItemDeactivatedAfterEdit())

    ImGui.SameLine()
    self.horizontalFlip, changed = style.trackedCheckbox(self.object, "Horizontal Flip", self.horizontalFlip)
    self:updateFull(ImGui.IsItemDeactivatedAfterEdit())

    ImGui.PopItemWidth()
end

function decal:getProperties()
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

function decal:export()
    local data = spawnable.export(self)
    data.type = "worldStaticDecalNode"
    data.scale = self.scale
    data.data = {
        alpha = self.alpha,
        autoHideDistance = self.autoHideDistance,
        horizontalFlip = self.horizontalFlip and 1 or 0,
        verticalFlip = self.verticalFlip and 1 or 0,
        isStretchingEnabled = 1,
        material = {
            DepotPath = {
                ["$storage"] = "string",
                ["$value"] = self.spawnData
            }
        }
    }

    return data
end

return decal