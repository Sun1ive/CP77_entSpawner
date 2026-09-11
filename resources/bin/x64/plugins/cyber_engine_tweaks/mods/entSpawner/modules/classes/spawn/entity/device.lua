local entity = require("modules/classes/spawn/entity/entity")
local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local registry = require("modules/utils/game/nodeRefRegistry")
local history = require("modules/utils/project/history")
local visualizer = require("modules/utils/preview/visualizer")
local Cron = require("modules/utils/vendor/Cron")
local quickElevatorSetupUI = require("modules/utils/ui/quickElevatorSetup")
local quickSoundSystemSetupUI = require("modules/utils/ui/quickSoundSystemSetup")
local quickDeviceOperationsSetupUI = require("modules/utils/ui/quickDeviceOperationsSetup")
local quickTransformAnimationSetupUI = require("modules/utils/ui/quickTransformAnimationSetup")
local quickSecuritySetupUI = require("modules/utils/ui/quickSecuritySetup")
local positionableGroup = require("modules/classes/editor/positionableGroup")
local spawnableElement = require("modules/classes/editor/spawnableElement")
local staticMarker = require("modules/classes/spawn/meta/staticMarker")
local elevatorDoors = require("modules/utils/data/elevatorDoors")
local soundSystemData = require("modules/utils/data/soundSystem")
local deviceOperationsData = require("modules/utils/data/deviceOperations")
local transformAnimationsData = require("modules/utils/data/transformAnimations")
local securitySystemData = require("modules/utils/data/securitySystem")
local redValue = require("modules/utils/data/redValue")
local outlineConsumer = require("modules/utils/game/outlineConsumer")

local POSITION_MARKER_COLOR = "blue"
local LIFT_CONTROLLER_CLASS = "LiftControllerPS"
local ELEVATOR_FLOOR_CONTROLLER_CLASS = "ElevatorFloorTerminalControllerPS"
local ELEVATOR_FLOOR_TERMINAL_PATH = "base\\gameplay\\devices\\elevators\\terminals\\elevator_floor_terminal_1.ent"
local ELEVATOR_FLOOR_TERMINAL_COMPONENT_ID = "1394923055520256000"
local DEFAULT_DOOR_CONNECTION_CLASS = "DoorControllerPS"
local LIFT_FLOOR_DOOR_DEFINITIONS = {
    common = {
        key = "common",
        label = "Common Lift Door",
        spawnData = "base\\gameplay\\devices\\doors\\elevator\\common_lift_door.ent",
        namePrefix = "Common_Lift_Door"
    },
    industrial = {
        key = "industrial",
        label = "Industrial Lift Door",
        spawnData = "base\\gameplay\\devices\\doors\\elevator\\industrial_lift_door_1.ent",
        namePrefix = "Industrial_Lift_Door"
    }
}
local LIFT_FLOOR_DOOR_BY_SPAWNDATA = {}
for key, definition in pairs(LIFT_FLOOR_DOOR_DEFINITIONS) do
    LIFT_FLOOR_DOOR_BY_SPAWNDATA[string.lower(definition.spawnData)] = key
end

local propertyNames = {
    "Device Class Name",
    "Persistent"
}

---Class for worldDeviceNode
---@class device : entity
---@field public deviceConnections {deviceClassName : string, nodeRef : string}[]
---@field public connectionNodeRefSearch table<string, string>
---@field public connectionsHeaderState boolean
---@field public persistent boolean
---@field private maxPropertyWidth number?
---@field public controllerComponent string
---@field public showSpeakerRangeSphere boolean Speaker range preview
local device = setmetatable({}, { __index = entity })

---@param doorType string?
---@return table?
local function getLiftFloorDoorDefinition(doorType)
    local key = string.lower(tostring(doorType or ""))
    if key == "" then
        return nil
    end

    return LIFT_FLOOR_DOOR_DEFINITIONS[key]
end

---@param nodeRef string?
---@param storage string?
---@return "string"|"uint64"
local function normalizeNodeRefStorage(storage)
    local normalized = string.lower(tostring(storage or ""))
    if normalized == "string" then
        return "string"
    end

    return "uint64"
end

---@param nodeRef string?
---@param storage string?
---@return table
local function buildNodeRefHashValue(nodeRef, storage)
    local nodeRefStorage = normalizeNodeRefStorage(storage)
    local normalizedNodeRef = utils.sanitizeText(nodeRef)
    local value

    if nodeRefStorage == "string" then
        value = normalizedNodeRef
    else
        value = utils.nodeRefStringToHashString(normalizedNodeRef)
    end

    return {
        ["$type"] = "NodeRef",
        ["$storage"] = nodeRefStorage,
        ["$value"] = tostring(value or (nodeRefStorage == "string" and "" or "0"))
    }
end

---@param componentData table?
---@return string?
local function getPersistentStateClassName(componentData)
    if type(componentData) ~= "table" then
        return nil
    end

    local persistentState = componentData.persistentState
    if type(persistentState) ~= "table" then
        return nil
    end

    local data = persistentState.Data
    if type(data) == "table" and type(data["$type"]) == "string" then
        return data["$type"]
    end

    return nil
end

---Recursively merges overrides into a copy of the defaults.
---@param base table
---@param override table
---@return table
local function mergeTableWithDefaults(base, override)
    local merged = utils.deepcopy(base or {})

    local function mergeIn(target, source)
        for key, value in pairs(source or {}) do
            if type(value) == "table" and type(target[key]) == "table" then
                mergeIn(target[key], value)
            else
                target[key] = utils.deepcopy(value)
            end
        end
    end

    mergeIn(merged, override or {})
    return merged
end

function device:new()
	local o = entity.new(self)

    o.dataType = "Device"
    o.modulePath = "entity/device"
    o.spawnDataPath = "data/spawnables/entity/device/"
    o.node = "worldDeviceNode"
    o.description = "Spawns an entity (.ent), as a worldDeviceNode. This allows it to be connected to other worldDeviceNodes."
    o.previewNote = "Device connections / functionality is not previewed."

    o.icon = IconGlyphs.AlphaDBoxOutline
    o.entryFilter = "deviceClass"

    o.deviceConnections = {}
    o.connectionNodeRefSearch = {}
    o.connectionsHeaderState = false
    o.persistent = false

    o.maxPropertyWidth = nil
    o.controllerComponent = ""
    o.positionMarkerColor = POSITION_MARKER_COLOR
    o.showDoorsHelper = true
    o.showSpeakerHelper = true
    o.showSpeakerRangeSphere = false

    setmetatable(o, { __index = self })
   	return o
end

function device:onAssemble(entRef)
    entity.onAssemble(self, entRef)

    for _, component in pairs(entRef:GetComponents()) do
        if component:IsA("gameDeviceComponent") then
            -- `.psrep` keys persistent state by component name.
            self.controllerComponent = component.name.value

            break
        end
    end

    self:updatePositionMarker()

    -- Add before attachment because late `AddComponent` calls are unreliable.
    if self.deviceClassName == soundSystemData.SPEAKER_CONTROLLER_CLASS then
        local size = self.showSpeakerRangeSphere
            and self:getSpeakerRangeSphereSize()
            or { x = 0.01, y = 0.01, z = 0.01 }

        visualizer.addSphere(entRef, size, soundSystemData.RANGE_SPHERE_COLOR, soundSystemData.RANGE_SPHERE_COMPONENT)
        self:updateSpeakerRangeSphere(entRef)
    end

    -- Refresh security-area outline bindings after component data is available.
    if self:isOutlineHost() then
        self:refreshOutlineBinding()
    end
end

---Returns the audible-range sphere scale from `speakerSetup.range`.
---@return { x: number, y: number, z: number }
function device:getSpeakerRangeSphereSize()
    local setup = self:getSpeakerSetup(self)
    local range = math.max(0, tonumber(setup and setup.range) or 0)

    return { x = range, y = range, z = range }
end

---Updates the speaker range sphere when available.
---@param entityRef entEntity? Defaults to this spawnable's live entity
---@param rangeOverride number? Live drag value, so the sphere follows the slider before it commits
function device:updateSpeakerRangeSphere(entityRef, rangeOverride)
    local target = entityRef or self:getEntity()
    if not target then
        return
    end

    local sphere = target:FindComponentByName(soundSystemData.RANGE_SPHERE_COMPONENT)
    if not sphere then
        return
    end

    -- Read persistent state only when showing the sphere.
    if self.deviceClassName ~= soundSystemData.SPEAKER_CONTROLLER_CLASS or self.showSpeakerRangeSphere ~= true then
        if sphere:IsEnabled() then
            sphere:Toggle(false)
        end

        return
    end

    local override = tonumber(rangeOverride)
    local size = override
        and { x = math.max(0, override), y = math.max(0, override), z = math.max(0, override) }
        or self:getSpeakerRangeSphereSize()

    -- Scale first because `updateScale` toggles enabled components.
    visualizer.updateScale(target, size, soundSystemData.RANGE_SPHERE_COMPONENT)

    local shouldShow = size.x > 0
    if sphere:IsEnabled() ~= shouldShow then
        sphere:Toggle(shouldShow)
    end
end

---@param state boolean
function device:setSpeakerRangeSphereVisible(state)
    self.showSpeakerRangeSphere = state == true
    self:updateSpeakerRangeSphere()
end

function device:save()
    local data = entity.save(self)
    data.deviceConnections = utils.deepcopy(self.deviceConnections)
    data.persistent = self.persistent
    data.controllerComponent = self.controllerComponent
    data.showPositionMarker = self.showPositionMarker
    data.showDoorsHelper = self.showDoorsHelper
    data.showSpeakerHelper = self.showSpeakerHelper
    data.showSpeakerRangeSphere = self.showSpeakerRangeSphere
    -- Keep this nil for devices that are not security areas.
    data.outlinePath = self.outlinePath

    return data
end

-- Outline binding --------------------------------------------------------------------------------
-- Security areas bind their trigger volume to an outline marker group.

---@return boolean
function device:isOutlineHost()
    return self.spawnData == securitySystemData.SECURITY_AREA_PATH
end

function device:loadSpawnData(data, position, rotation)
    entity.loadSpawnData(self, data, position, rotation)

    -- `outlinePath` is absent on plain devices, so restore it explicitly.
    if data.outlinePath ~= nil then
        self.outlinePath = data.outlinePath
    elseif self:isOutlineHost() and self.outlinePath == nil then
        self.outlinePath = ""
    end

    -- Project load, paste and undo can all change outline bindings.
    outlineConsumer.invalidate()
end

function device:loadOutlinePaths()
    return outlineConsumer.loadPaths(self)
end

---The `area` component holding the outline, when loaded.
---@return string?
function device:getAreaShapeComponentID()
    local componentID = self.findComponentIDByType
        and self:findComponentIDByType(securitySystemData.AREA_SHAPE_COMPONENT_CLASS)
        or nil

    if componentID then
        return componentID
    end

    -- Fallback once component data is loaded.
    if self.defaultComponentData and self.defaultComponentData[securitySystemData.AREA_SHAPE_COMPONENT_ID] then
        return securitySystemData.AREA_SHAPE_COMPONENT_ID
    end

    return nil
end

---Loads components needed to write an outline.
---@return string?
function device:ensureAreaShapeLoaded()
    local componentID = self:getAreaShapeComponentID()
    if componentID then return componentID end

    local entityRef = self.getEntity and self:getEntity() or nil
    if not entityRef or not self.loadInstanceData then return nil end

    local ok = pcall(function ()
        self:loadInstanceData(entityRef, true)
    end)
    if not ok then return nil end

    return self:getAreaShapeComponentID()
end

---Writes the bound outline onto the `area` component without respawning.
---@return boolean written
function device:refreshOutlineBinding()
    if not self:isOutlineHost() then return false end

    local outlinePath = self.outlinePath
    if not outlinePath or outlinePath == "" or outlinePath == "None" then return false end

    -- Force-load the trigger component once if only controller data is present.
    local componentID = self:ensureAreaShapeLoaded()
    if not componentID then return false end

    local points, height = outlineConsumer.getLocalPoints(self)
    if #points < outlineConsumer.MIN_MARKERS then return false end

    -- Outline points are stored in the node's local frame.
    local rotation = self.rotation
    local hasRotation = rotation and (rotation.roll ~= 0 or rotation.pitch ~= 0 or rotation.yaw ~= 0)

    if hasRotation then
        local quat = rotation:ToQuat()

        for _, point in ipairs(points) do
            local local_ = quat:TransformInverse(Vector4.new(point.X, point.Y, point.Z, 0))
            point.X, point.Y, point.Z = local_.x, local_.y, local_.z
        end
    end

    local outline = securitySystemData.newOutline(points, height)

    -- Dragging calls `update` every frame; write only real geometry changes.
    local current = self:getComponentPathValue(self, componentID, securitySystemData.OUTLINE_PATH)
    if securitySystemData.outlineMatches(current, outline) then return false end

    self:updateComponentPathValue(self, componentID, securitySystemData.OUTLINE_PATH, outline, {
        suppressRespawn = true
    })

    return true
end

---Called by `outlineConsumer` when the bound marker group changes.
function device:onOutlineChanged()
    self:refreshOutlineBinding()
end

-- Security network wiring ------------------------------------------------------------------------
-- Quick Security actions create and connect nodes in one undo step.

---Creates a child device node.
---@param parent element
---@param options table `{ spawnData, app, controllerClass, namePrefix, position, rotation, persistent, deviceConnections }`
---@return element element
---@return table spawnable
function device:createChildDeviceNode(parent, options)
    options = options or {}

    if not self.object or not parent then
        return nil, nil
    end

    local seed = device:new()
    seed:loadSpawnData({
        spawnData = options.spawnData,
        app = options.app,
        nodeRef = "",
        persistent = false,
        deviceClassName = options.controllerClass,
        deviceConnections = utils.deepcopy(options.deviceConnections or {}),
        instanceDataChanges = utils.deepcopy(options.instanceDataChanges or {}),
        defaultComponentData = utils.deepcopy(options.defaultComponentData or {})
    }, options.position, options.rotation)

    local newElement = spawnableElement:new(self.object.sUI)
    newElement:load({
        name = self:getNextChildName(parent, options.namePrefix or "Device"),
        spawnable = seed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    newElement:setParent(parent)
    parent.headerOpen = true

    self:refreshNodeRefCaches()

    local newSpawnable = newElement.spawnable
    newSpawnable.nodeRef = utils.sanitizeText(registry.generate(newElement))
    newSpawnable.deviceClassName = utils.sanitizeText(options.controllerClass)

    if options.persistent ~= nil then
        newSpawnable.persistent = options.persistent == true and newSpawnable.nodeRef ~= ""
    end

    self:refreshNodeRefCaches()

    return newElement, newSpawnable
end

---Creates an unconnected device node.
---@param parent element
---@param spawnData string Entity path
---@param controllerClass string
---@param namePrefix string
---@param position Vector4
---@param rotation EulerAngles
---@return element element
---@return table spawnable
function device:createSecurityNode(parent, spawnData, controllerClass, namePrefix, position, rotation)
    return self:createChildDeviceNode(parent, {
        spawnData = spawnData,
        app = "default",
        controllerClass = controllerClass,
        namePrefix = namePrefix,
        position = position,
        rotation = rotation,
        persistent = true
    })
end

---Adds a connection unless the NodeRef is already present.
---@param className string
---@param nodeRef string
---@return boolean added
function device:addSecurityConnection(className, nodeRef)
    local cleanClass = utils.sanitizeText(className)
    local cleanRef = utils.sanitizeText(nodeRef)

    if cleanClass == "" or cleanRef == "" then
        return false
    end

    for _, connection in ipairs(self.deviceConnections) do
        if utils.sanitizeText(connection.deviceClassName) == cleanClass
            and utils.sanitizeText(connection.nodeRef) == cleanRef then
            return false
        end
    end

    table.insert(self.deviceConnections, {
        deviceClassName = cleanClass,
        nodeRef = cleanRef
    })

    return true
end

---Creates and binds an outline without recording history.
---@param parentOverride element? Group to build under; defaults to this device's own parent
---@return element? outlineGroup
function device:addSecurityOutline(parentOverride)
    local parent = parentOverride or (self.object and self.object.parent) or nil

    if not self.object or not parent then
        return nil
    end

    local outlineGroup = outlineConsumer.createMarkerGroup(self, parent, {
        namePrefix = securitySystemData.NEW_OUTLINE_GROUP_NAME,
        offsets = securitySystemData.getNewOutlineOffsets(),
        height = securitySystemData.NEW_OUTLINE_HEIGHT
    })
    if not outlineGroup then
        return nil
    end

    self:refreshNodeRefCaches()

    -- Refresh the cache before resolving the new path.
    self.outlinePath = outlineGroup.getPath and outlineGroup:getPath() or ""
    outlineConsumer.invalidate()

    if self.refreshOutlineBinding then
        self:refreshOutlineBinding()
    end

    return outlineGroup
end

---Creates and connects a security area with an outline.
---@return element? areaElement
function device:addSecurityArea()
    if not self.object or not self.object.parent or self.object:isLocked() then
        return nil
    end

    local actions = {}
    local parent, wrapAction = self:getQuickSetupChildParent()
    if wrapAction then
        table.insert(actions, wrapAction)
    end

    if not parent then
        return nil
    end

    -- Start at the system position.
    local position = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    -- Keep marker offsets directly exportable.
    local rotation = EulerAngles.new(0, 0, 0)

    local areaElement, areaSpawnable = self:createSecurityNode(
        parent,
        securitySystemData.SECURITY_AREA_PATH,
        securitySystemData.SECURITY_AREA_CONTROLLER_CLASS,
        "SecurityArea",
        position,
        rotation
    )
    if not areaElement or not areaSpawnable then
        return nil
    end

    -- Keep markers and the area in the same group.
    local outlineGroup = areaSpawnable:addSecurityOutline(parent)

    -- Use the common restrictive default.
    self:updateComponentPathValue(
        areaSpawnable,
        securitySystemData.SECURITY_AREA_COMPONENT_ID,
        securitySystemData.AREA_TYPE_PATH,
        securitySystemData.DEFAULT_AREA_TYPE,
        { suppressRespawn = true }
    )

    table.insert(actions, history.getElementChange(self.object))
    self:addSecurityConnection(securitySystemData.SECURITY_AREA_CONTROLLER_CLASS, areaSpawnable.nodeRef)

    table.insert(actions, history.getInsert(outlineGroup and { areaElement, outlineGroup } or { areaElement }))

    self:refreshNodeRefCaches()

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end

    return areaElement
end

---Creates and connects a security slave device.
---@param key string Key from `securitySystem.SLAVE_CLASSES`
---@param spawnData string? One of the entry's `variants` paths, or nil for its default
---@return element? slaveElement
function device:addSecuritySlave(key, spawnData)
    if not self.object or not self.object.parent or self.object:isLocked() then
        return nil
    end

    local definition = securitySystemData.getSlaveDefinition(tostring(key or ""))
    local slavePath = securitySystemData.resolveSlaveSpawnData(definition, spawnData)
    if not slavePath then
        return nil
    end

    local actions = {}
    local parent, wrapAction = self:getQuickSetupChildParent()
    if wrapAction then
        table.insert(actions, wrapAction)
    end

    if not parent then
        return nil
    end

    local position = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    local rotation = EulerAngles.new(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)

    local slaveElement, slaveSpawnable = self:createSecurityNode(
        parent,
        slavePath,
        definition.class,
        definition.namePrefix or "SecurityDevice",
        position,
        rotation
    )
    if not slaveElement or not slaveSpawnable then
        return nil
    end

    table.insert(actions, history.getElementChange(self.object))
    self:addSecurityConnection(definition.class, slaveSpawnable.nodeRef)
    table.insert(actions, history.getInsert({ slaveElement }))

    self:refreshNodeRefCaches()

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end

    return slaveElement
end

---Creates a security system linked to this area.
---@return element? systemElement
function device:addSecuritySystemForArea()
    if not self.object or not self.object.parent or self.object:isLocked() then
        return nil
    end

    if utils.sanitizeText(self.nodeRef) == "" then
        return nil
    end

    local actions = {}
    local parent, wrapAction = self:getQuickSetupChildParent()
    if wrapAction then
        table.insert(actions, wrapAction)
    end

    if not parent then
        return nil
    end

    local systemElement, systemSpawnable = self:createSecurityNode(
        parent,
        securitySystemData.SECURITY_SYSTEM_PATH,
        securitySystemData.SECURITY_SYSTEM_CONTROLLER_CLASS,
        "SecuritySystem",
        Vector4.new(self.position.x, self.position.y, self.position.z, 0),
        EulerAngles.new(0, 0, 0)
    )
    if not systemElement or not systemSpawnable then
        return nil
    end

    -- Allow provoked factions to settle after combat.
    self:updateComponentPathValue(
        systemSpawnable,
        securitySystemData.SECURITY_SYSTEM_COMPONENT_ID,
        securitySystemData.ATTITUDE_MODE_PATH,
        securitySystemData.DEFAULT_ATTITUDE_MODE,
        { suppressRespawn = true }
    )

    -- The area link lives on the system.
    systemSpawnable:addSecurityConnection(securitySystemData.SECURITY_AREA_CONTROLLER_CLASS, self.nodeRef)

    table.insert(actions, history.getInsert({ systemElement }))

    self:refreshNodeRefCaches()

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end

    return systemElement
end

---Removes a connection row by index.
---@param connectionIndex number
---@return boolean removed
function device:removeSecurityConnection(connectionIndex)
    local index = tonumber(connectionIndex)

    if not index or not self.deviceConnections[index] then
        return false
    end

    history.addAction(history.getElementChange(self.object))
    table.remove(self.deviceConnections, index)
    registry.invalidate()

    return true
end

---Returns an area's bound outline within the same root.
---@param areaSpawnable table?
---@return element?
function device:resolveSecurityOutlineGroup(areaSpawnable)
    local path = areaSpawnable and areaSpawnable.outlinePath or nil

    if type(path) ~= "string" or path == "" or path == "None" then
        return nil
    end

    local object = areaSpawnable.object
    local sUI = object and object.sUI or nil
    local group = sUI and sUI.getElementByPath and sUI.getElementByPath(path) or nil

    if not group or not group.getRootParent or not object.getRootParent then
        return nil
    end

    -- Reject stale cross-root bindings.
    return group:getRootParent() == object:getRootParent() and group or nil
end

---Removes a connection and optionally its node and outline.
---@param entry table Network entry `{ connection, nodeRef, spawnable, element }`
---@param deleteNode boolean Remove the target element as well
---@return boolean removed
function device:removeSecurityNode(entry, deleteNode)
    if not entry then
        return false
    end

    local targetNodeRef = utils.sanitizeText(entry.nodeRef)
    local removedConnection = false

    for index = #self.deviceConnections, 1, -1 do
        local candidate = self.deviceConnections[index]
        local sameConnection = entry.connection ~= nil and candidate == entry.connection
        local sameNodeRef = targetNodeRef ~= ""
            and utils.sanitizeText(candidate.nodeRef) == targetNodeRef

        if sameConnection or sameNodeRef then
            self.connectionNodeRefSearch[tostring(candidate)] = nil
            table.remove(self.deviceConnections, index)
            removedConnection = true
        end
    end

    local removedElements = {}

    if deleteNode and entry.element then
        table.insert(removedElements, entry.element)

        local outlineGroup = self:resolveSecurityOutlineGroup(entry.spawnable)
        if outlineGroup then
            table.insert(removedElements, outlineGroup)
        end
    end

    local removeAction = nil
    if #removedElements > 0 then
        -- Snapshot before detaching for undo.
        removeAction = history.getRemove(removedElements)

        for _, element in ipairs(removedElements) do
            element:remove()
        end
    end

    if not removedConnection and not removeAction then
        return false
    end

    local actions = { history.getElementChange(self.object) }
    if removeAction then
        table.insert(actions, removeAction)
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end

    self:refreshNodeRefCaches()
    outlineConsumer.invalidate()

    return true
end
---Creates and connects an NPC community.
---@return element? communityElement
function device:addSecurityCommunity()
    if not self.object or not self.object.parent or self.object:isLocked() then
        return nil
    end

    local actions = {}
    local parent, wrapAction = self:getQuickSetupChildParent()
    if wrapAction then
        table.insert(actions, wrapAction)
    end

    if not parent then
        return nil
    end

    local communityClass = require("modules/classes/spawn/ai/communityArea")
    local seed = communityClass:new()
    seed:loadSpawnData(
        {},
        Vector4.new(self.position.x, self.position.y, self.position.z, 0),
        EulerAngles.new(0, 0, 0)
    )

    local communityElement = spawnableElement:new(self.object.sUI)
    communityElement:load({
        name = self:getNextChildName(parent, "Community"),
        spawnable = seed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    communityElement:setParent(parent)
    parent.headerOpen = true

    self:refreshNodeRefCaches()

    local communitySpawnable = communityElement.spawnable
    communitySpawnable.nodeRef = utils.sanitizeText(registry.generate(communityElement))
    self:refreshNodeRefCaches()

    table.insert(actions, history.getElementChange(self.object))
    self:addSecurityConnection(securitySystemData.COMMUNITY_PROXY_CLASS, communitySpawnable.nodeRef)
    table.insert(actions, history.getInsert({ communityElement }))

    self:refreshNodeRefCaches()

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end

    return communityElement
end

function device:update()
    entity.update(self)

    -- Points are relative to this node.
    self:refreshOutlineBinding()
end

---@param currentValue string
---@return table
function device:getConnectionNodeRefOptions(currentValue)
    registry.update()

    local options = {}
    local root = self.object and self.object:getRootParent()
    local rootRefs = root and registry.refs[root.name] or nil

    if rootRefs then
        for ref, _ in pairs(rootRefs) do
            if ref ~= self.nodeRef then
                table.insert(options, ref)
            end
        end
    end

    table.sort(options)

    local cleanCurrentValue = utils.sanitizeText(currentValue)
    if cleanCurrentValue ~= "" and utils.indexValue(options, cleanCurrentValue) == -1 then
        table.insert(options, 1, cleanCurrentValue)
    end

    return options
end

---@param nodeRef string
---@return string?
function device:resolveConnectionClassName(nodeRef)
    local spawnable = registry.getSpawnableByNodeRef(self.object, nodeRef)
    local className = spawnable and utils.sanitizeText(spawnable.deviceClassName) or ""

    if className ~= "" then
        return className
    end

    return nil
end

---@param nodeRef string
---@return spawnable?, string
function device:resolveConnectionTargetSpawnable(nodeRef)
    local cleanNodeRef = utils.sanitizeText(nodeRef)
    if cleanNodeRef == "" then
        return nil, cleanNodeRef
    end

    registry.update()

    local spawnable = registry.getSpawnableByNodeRef(self.object, cleanNodeRef)
    local resolvedNodeRef = cleanNodeRef

    -- Resolve stored hashes to root-local NodeRefs.
    if not spawnable and not string.find(cleanNodeRef, "%D") then
        local root = self.object and self.object:getRootParent()
        local rootRefs = root and registry.refs[root.name] or nil

        if rootRefs then
            for ref, entry in pairs(rootRefs) do
                if utils.nodeRefStringToHashString(ref) == cleanNodeRef then
                    spawnable = entry.spawnable
                    resolvedNodeRef = ref
                    break
                end
            end
        end
    end

    -- Fall back to the hierarchy if the registry is stale.
    if not spawnable and self.object and self.object.getRootParent then
        local root = self.object:getRootParent()
        if root and root.getPathsRecursive then
            for _, path in ipairs(root:getPathsRecursive(true)) do
                local ref = path.ref
                if utils.isA(ref, "spawnableElement") and ref.spawnable then
                    local candidate = utils.sanitizeText(ref.spawnable.nodeRef)
                    if candidate ~= "" and (candidate == cleanNodeRef or utils.nodeRefStringToHashString(candidate) == cleanNodeRef) then
                        spawnable = ref.spawnable
                        resolvedNodeRef = candidate
                        break
                    end
                end
            end
        end
    end

    return spawnable, resolvedNodeRef
end

function device:refreshNodeRefCaches()
    registry.invalidate()

    if self.object and self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
end

---Updates a NodeRef and optional references to its old value.
---@param targetSpawnable table?
---@param targetElement element?
---@param newNodeRef string
---@param options table? `{ currentNodeRef, includeOwnerChange, updateReferrers, rewriteReferrersOnSameValue, onUpdated }`
---@return boolean updated
function device:updateNodeRefAndReferrers(targetSpawnable, targetElement, newNodeRef, options)
    if not targetSpawnable then
        return false
    end

    local normalizedNodeRef = utils.sanitizeText(newNodeRef)
    if normalizedNodeRef == "" then
        return false
    end

    local opts = options or {}
    local currentNodeRef = utils.sanitizeText(opts.currentNodeRef or targetSpawnable.nodeRef)
    local shouldRewrite = opts.rewriteReferrersOnSameValue == true

    if normalizedNodeRef == currentNodeRef and not shouldRewrite then
        return false
    end

    local changes = {}
    local changedElements = {}
    local function addElementChange(elementRef)
        if elementRef and not changedElements[elementRef] then
            table.insert(changes, history.getElementChange(elementRef))
            changedElements[elementRef] = true
        end
    end

    addElementChange(targetElement or self.object)

    if opts.includeOwnerChange then
        addElementChange(self.object)
    end

    local referrers = {}
    local updateReferrers = opts.updateReferrers ~= false
    local currentHash = currentNodeRef ~= "" and utils.nodeRefStringToHashString(currentNodeRef) or nil

    if updateReferrers and currentNodeRef ~= "" and self.object and self.object.getRootParent then
        local root = self.object:getRootParent()

        if root and root.getPathsRecursive then
            for _, path in ipairs(root:getPathsRecursive(true)) do
                local ref = path.ref
                local spawnable = utils.isA(ref, "spawnableElement") and ref.spawnable or nil

                if spawnable and type(spawnable.deviceConnections) == "table" then
                    for _, connection in ipairs(spawnable.deviceConnections) do
                        local targetRef = utils.sanitizeText(connection.nodeRef)

                        if targetRef ~= "" and (
                            targetRef == currentNodeRef
                            or targetRef == currentHash
                            or utils.nodeRefStringToHashString(targetRef) == currentHash
                        ) then
                            addElementChange(ref)
                            table.insert(referrers, connection)
                        end
                    end
                end
            end
        end
    end

    if #changes > 1 then
        history.addAction(history.getComposite(changes))
    elseif #changes == 1 then
        history.addAction(changes[1])
    end

    targetSpawnable.nodeRef = normalizedNodeRef

    for _, connection in ipairs(referrers) do
        connection.nodeRef = normalizedNodeRef
    end

    if opts.onUpdated then
        opts.onUpdated(normalizedNodeRef, referrers)
    end

    self:refreshNodeRefCaches()

    return true
end

---Resolves device connections to their target spawnables.
---@param sourceSpawnable table?
---@param options table? `{ className, excludeClasses, requireNodeRef, filter, decorate }`
---@return table[]
function device:getResolvedDeviceConnections(sourceSpawnable, options)
    if not sourceSpawnable or type(sourceSpawnable.deviceConnections) ~= "table" then
        return {}
    end

    registry.update()

    local opts = options or {}
    local wantedClass = opts.className and utils.sanitizeText(opts.className) or nil
    local excludeClasses = opts.excludeClasses or {}
    local entries = {}

    for connectionIndex, connection in ipairs(sourceSpawnable.deviceConnections) do
        local className = utils.sanitizeText(connection.deviceClassName)
        local rawNodeRef = utils.sanitizeText(connection.nodeRef)
        local keep = className ~= ""

        if keep and wantedClass and className ~= wantedClass then
            keep = false
        end

        if keep and excludeClasses[className] then
            keep = false
        end

        if keep and opts.requireNodeRef and rawNodeRef == "" then
            keep = false
        end

        if keep and opts.filter then
            keep = opts.filter(connection, className, rawNodeRef, connectionIndex) == true
        end

        if keep then
            local targetSpawnable, resolvedNodeRef = sourceSpawnable:resolveConnectionTargetSpawnable(rawNodeRef)
            local entry = {
                connection = connection,
                connectionIndex = connectionIndex,
                rawNodeRef = rawNodeRef,
                className = className,
                nodeRef = resolvedNodeRef ~= "" and resolvedNodeRef or rawNodeRef,
                spawnable = targetSpawnable,
                element = targetSpawnable and targetSpawnable.object or nil
            }

            if opts.decorate then
                opts.decorate(entry)
            end

            table.insert(entries, entry)
        end
    end

    return entries
end

---@param targetSpawnable entity
---@param className string
---@param fallbackComponentID string?
---@return string?
function device:getPersistentComponentID(targetSpawnable, className, fallbackComponentID)
    if not targetSpawnable then
        return nil
    end

    className = utils.sanitizeText(className)

    local function scanComponentData(source)
        for componentID, componentData in pairs(source or {}) do
            if getPersistentStateClassName(componentData) == className then
                return tostring(componentID)
            end
        end

        return nil
    end

    local componentID = scanComponentData(targetSpawnable.defaultComponentData)
    if componentID then
        return componentID
    end

    componentID = scanComponentData(targetSpawnable.instanceDataChanges)
    if componentID then
        return componentID
    end

    if targetSpawnable.getEntity and targetSpawnable.loadInstanceData then
        local entityRef = targetSpawnable:getEntity()
        if entityRef then
            pcall(function()
                targetSpawnable:loadInstanceData(entityRef, true)
            end)

            componentID = scanComponentData(targetSpawnable.defaultComponentData)
            if componentID then
                return componentID
            end

            componentID = scanComponentData(targetSpawnable.instanceDataChanges)
            if componentID then
                return componentID
            end
        end
    end

    if fallbackComponentID then
        fallbackComponentID = tostring(fallbackComponentID)
        if (targetSpawnable.defaultComponentData and targetSpawnable.defaultComponentData[fallbackComponentID])
            or (targetSpawnable.instanceDataChanges and targetSpawnable.instanceDataChanges[fallbackComponentID]) then
            return fallbackComponentID
        end
    end

    return nil
end

---@param targetSpawnable entity
---@param componentID string
---@param path table
---@return any
function device:getComponentPathValue(targetSpawnable, componentID, path)
    if not targetSpawnable or not componentID then
        return nil
    end

    componentID = tostring(componentID)
    local defaultRoot = targetSpawnable.defaultComponentData and targetSpawnable.defaultComponentData[componentID]

    local changedRoot = targetSpawnable.instanceDataChanges and targetSpawnable.instanceDataChanges[componentID]
    if changedRoot then
        local changedValue = utils.getNestedValue(changedRoot, path)
        if changedValue ~= nil then
            local defaultValue = defaultRoot and utils.getNestedValue(defaultRoot, path) or nil
            if type(changedValue) == "table" and type(defaultValue) == "table" then
                return mergeTableWithDefaults(defaultValue, changedValue)
            end
            return changedValue
        end
    end

    if defaultRoot then
        return utils.getNestedValue(defaultRoot, path)
    end

    return nil
end

---Reads an array override as a complete value instead of merging defaults.
---@param targetSpawnable entity
---@param componentID string
---@param path table
---@return table
function device:getComponentPathArray(targetSpawnable, componentID, path)
    if not targetSpawnable or not componentID then
        return {}
    end

    componentID = tostring(componentID)

    local changedRoot = targetSpawnable.instanceDataChanges and targetSpawnable.instanceDataChanges[componentID]
    if changedRoot then
        local changedValue = utils.getNestedValue(changedRoot, path)
        if type(changedValue) == "table" then
            return utils.deepcopy(changedValue)
        end
    end

    local defaultRoot = targetSpawnable.defaultComponentData and targetSpawnable.defaultComponentData[componentID]
    if defaultRoot then
        local defaultValue = utils.getNestedValue(defaultRoot, path)
        if type(defaultValue) == "table" then
            return utils.deepcopy(defaultValue)
        end
    end

    return {}
end

---@param targetSpawnable entity
---@param componentID string
---@param path table
---@param value any
---@param options table?
function device:updateComponentPathValue(targetSpawnable, componentID, path, value, options)
    if not targetSpawnable or not componentID then
        return
    end

    options = options or {}
    local suppressRespawn = options.suppressRespawn == true

    componentID = tostring(componentID)

    local hasDefaultComponent = targetSpawnable.defaultComponentData
        and targetSpawnable.defaultComponentData[componentID]
    if not hasDefaultComponent and targetSpawnable.getEntity and targetSpawnable.loadInstanceData then
        local entityRef = targetSpawnable:getEntity()
        if entityRef then
            pcall(function()
                targetSpawnable:loadInstanceData(entityRef, true)
            end)
        end
    end

    targetSpawnable.instanceDataChanges = targetSpawnable.instanceDataChanges or {}
    targetSpawnable.instanceDataChanges[componentID] = targetSpawnable.instanceDataChanges[componentID] or {}

    local rootKey = path[1]
    local defaultRoot = targetSpawnable.defaultComponentData
        and targetSpawnable.defaultComponentData[componentID]
        and targetSpawnable.defaultComponentData[componentID][rootKey]

    if rootKey == "persistentState" then
        local persistentState = targetSpawnable.instanceDataChanges[componentID][rootKey]
        if defaultRoot ~= nil and type(persistentState) == "table" then
            persistentState = mergeTableWithDefaults(defaultRoot, persistentState)
            targetSpawnable.instanceDataChanges[componentID][rootKey] = persistentState
        elseif defaultRoot ~= nil and persistentState ~= nil and type(persistentState) ~= "table" then
            persistentState = utils.deepcopy(defaultRoot)
            targetSpawnable.instanceDataChanges[componentID][rootKey] = persistentState
        end

        if type(persistentState) == "table" then
            if persistentState.HandleId == nil then
                persistentState.HandleId = "0"
            end
            if type(persistentState.Data) ~= "table" then
                persistentState.Data = {}
            end
        end
    end

    if not suppressRespawn
        and targetSpawnable.defaultComponentData
        and targetSpawnable.defaultComponentData[componentID]
        and targetSpawnable.updatePropValue then
        -- Heal legacy/partial persistentState overrides by merging onto default root.
        if rootKey == "persistentState" and defaultRoot ~= nil then
            local changedRoot = targetSpawnable.instanceDataChanges[componentID][rootKey]
            if type(changedRoot) == "table" then
                targetSpawnable.instanceDataChanges[componentID][rootKey] = mergeTableWithDefaults(defaultRoot, changedRoot)
            elseif changedRoot ~= nil then
                targetSpawnable.instanceDataChanges[componentID][rootKey] = nil
            end
        end

        targetSpawnable:updatePropValue(componentID, path, value)
        return
    end

    if targetSpawnable.instanceDataChanges[componentID][rootKey] == nil then
        if defaultRoot ~= nil then
            targetSpawnable.instanceDataChanges[componentID][rootKey] = utils.deepcopy(defaultRoot)
        else
            if rootKey == "persistentState" then
                targetSpawnable.instanceDataChanges[componentID][rootKey] = {
                    HandleId = "0",
                    Data = {}
                }
            else
                targetSpawnable.instanceDataChanges[componentID][rootKey] = {}
            end
        end
    end

    if rootKey == "persistentState" then
        local persistentState = targetSpawnable.instanceDataChanges[componentID][rootKey]
        if type(persistentState) ~= "table" then
            persistentState = { HandleId = "0", Data = {} }
            targetSpawnable.instanceDataChanges[componentID][rootKey] = persistentState
        end
        if persistentState.HandleId == nil then
            persistentState.HandleId = "0"
        end
        if type(persistentState.Data) ~= "table" then
            persistentState.Data = {}
        end
    end

    local nested = targetSpawnable.instanceDataChanges[componentID]
    for i = 1, #path - 1 do
        local key = path[i]
        if type(nested[key]) ~= "table" then
            nested[key] = {}
        end
        nested = nested[key]
    end
    nested[path[#path]] = value

    if defaultRoot ~= nil and utils.deepcompare(defaultRoot, targetSpawnable.instanceDataChanges[componentID][rootKey], false) then
        targetSpawnable.instanceDataChanges[componentID][rootKey] = nil
        if utils.tableLength(targetSpawnable.instanceDataChanges[componentID]) == 0 then
            targetSpawnable.instanceDataChanges[componentID] = nil
        end
    end

    if not suppressRespawn then
        targetSpawnable:respawn()
    end
end

---@param terminalSpawnable entity
---@param markerNodeRef string
function device:applyLiftFloorSetupToTerminal(terminalSpawnable, markerNodeRef)
    if not terminalSpawnable then
        return
    end

    local function applyNow(options)
        options = options or {}

        local componentID = self:getPersistentComponentID(
            terminalSpawnable,
            ELEVATOR_FLOOR_CONTROLLER_CLASS,
            ELEVATOR_FLOOR_TERMINAL_COMPONENT_ID
        )
        if not componentID then
            return false
        end

        local setupPath = { "persistentState", "Data", "elevatorFloorSetup" }
        local currentSetup = self:getComponentPathValue(terminalSpawnable, componentID, setupPath)
        local normalizedSetup = self:normalizeElevatorFloorSetup(currentSetup, markerNodeRef)
        self:updateComponentPathValue(terminalSpawnable, componentID, setupPath, normalizedSetup, {
            suppressRespawn = options.suppressRespawn == true
        })
        return true
    end

    if applyNow() then
        return
    end

    if terminalSpawnable._pendingLiftFloorSetupCallback then
        return
    end

    terminalSpawnable._pendingLiftFloorSetupCallback = true
    if terminalSpawnable.registerSpawnedAndAttachedCallback then
        terminalSpawnable:registerSpawnedAndAttachedCallback(function ()
            -- Defer setup work out of the engine attach callback to avoid hard-crash respawn timing.
            Cron.After(0.05, function ()
                terminalSpawnable._pendingLiftFloorSetupCallback = nil
                if terminalSpawnable.object then
                    applyNow({ suppressRespawn = true })
                end
            end)
        end)
    else
        terminalSpawnable._pendingLiftFloorSetupCallback = nil
    end
end

---@param markerNodeRef string?
---@return table
function device:createDefaultElevatorFloorSetup(markerNodeRef)
    return {
        ["$type"] = "ElevatorFloorSetup",
        floorName = "",
        floorDisplayName = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = "None"
        },
        authorizationTextOverride = "",
        isHidden = 0,
        isInactive = 0,
        doorShouldOpenFrontLeftRight = { 1, 1, 1 },
        floorMarker = buildNodeRefHashValue(markerNodeRef)
    }
end

---@param floorSetup table?
---@param markerNodeRef string?
---@return table
function device:normalizeElevatorFloorSetup(floorSetup, markerNodeRef)
    local normalized = utils.deepcopy(floorSetup or {})
    normalized["$type"] = "ElevatorFloorSetup"
    normalized.floorName = tostring(normalized.floorName or "")
    normalized.authorizationTextOverride = tostring(normalized.authorizationTextOverride or "")
    normalized.isHidden = redValue.boolToInt(normalized.isHidden, 0)
    normalized.isInactive = redValue.boolToInt(normalized.isInactive, 0)

    local doors = normalized.doorShouldOpenFrontLeftRight or { 1, 1, 1 }
    normalized.doorShouldOpenFrontLeftRight = {
        redValue.boolToInt(doors[1], 1),
        redValue.boolToInt(doors[2], 1),
        redValue.boolToInt(doors[3], 1)
    }

    if type(normalized.floorDisplayName) ~= "table" then
        normalized.floorDisplayName = {
            ["$type"] = "CName",
            ["$storage"] = "string",
            ["$value"] = "None"
        }
    else
        normalized.floorDisplayName["$type"] = "CName"
        normalized.floorDisplayName["$storage"] = normalized.floorDisplayName["$storage"] or "string"
        normalized.floorDisplayName["$value"] = tostring(normalized.floorDisplayName["$value"] or "None")
    end

    local existingFloorMarkerStorage = type(normalized.floorMarker) == "table"
        and normalizeNodeRefStorage(normalized.floorMarker["$storage"])
        or "uint64"

    if markerNodeRef then
        normalized.floorMarker = buildNodeRefHashValue(markerNodeRef, existingFloorMarkerStorage)
    elseif type(normalized.floorMarker) ~= "table" then
        normalized.floorMarker = buildNodeRefHashValue("", "uint64")
    else
        local markerStorage = normalizeNodeRefStorage(normalized.floorMarker["$storage"])
        normalized.floorMarker["$type"] = "NodeRef"
        normalized.floorMarker["$storage"] = markerStorage

        if markerStorage == "string" then
            normalized.floorMarker["$value"] = utils.sanitizeText(normalized.floorMarker["$value"])
        else
            local markerValue = tostring(normalized.floorMarker["$value"] or "0")
            markerValue = utils.trimString(markerValue)
            if markerValue == "" then
                markerValue = "0"
            elseif string.find(markerValue, "%D") then
                markerValue = utils.nodeRefStringToHashString(markerValue)
            end
            normalized.floorMarker["$value"] = markerValue
        end
    end

    return normalized
end

---@param doorIndex number
---@return Vector4?
function device:getLiftDoorWorldPosition(doorIndex)
    if tostring(self.deviceClassName or "") ~= LIFT_CONTROLLER_CLASS then
        return nil
    end

    local layout, layoutKey = elevatorDoors.resolveLayout(self.spawnData)
    if type(layout) ~= "table" then
        return nil
    end

    local side = elevatorDoors.rotateSide(layout[doorIndex], elevatorDoors.LAYOUT_ROTATIONS[layoutKey])
    if not side then
        return nil
    end

    return elevatorDoors.getMarkerWorldPosition(self, side)
end

---Wraps this device in a group for quick-setup nodes when needed.
---@return element?, table? group, history action for the wrap (nil when no wrap was needed)
function device:ensureOwnParentGroup()
    if not self.object then
        return nil, nil
    end

    local wrapper, wrapAction = self.object:ensureParentGroup()

    -- The device moved, so every path-keyed cache pointing at it is stale.
    if wrapAction then
        self:refreshNodeRefCaches()
    end

    return wrapper, wrapAction
end

---@return element?, table?
function device:getQuickSetupChildParent()
    if not self.object or not self.object.parent then
        return nil, nil
    end

    local parent = self.object.parent
    if utils.isA(parent, "positionableGroup") then
        return parent, nil
    end

    return self:ensureOwnParentGroup()
end

---@param parent element
---@return number
function device:getNextElevatorFloorIndex(parent)
    local used = {}

    for _, child in ipairs(parent.childs or {}) do
        local suffix = tostring(child.name or ""):match("^Elevator_Floor_(%d+)$")
        if suffix then
            used[tonumber(suffix)] = true
        end
    end

    local nextIndex = 0
    while used[nextIndex] do
        nextIndex = nextIndex + 1
    end

    return nextIndex
end

---@return table[]
function device:getLiftFloorEntries()
    registry.update()

    local entries = {}

    for connectionIndex, connection in ipairs(self.deviceConnections) do
        local className = utils.sanitizeText(connection.deviceClassName)
        local rawNodeRef = utils.sanitizeText(connection.nodeRef)

        if className == ELEVATOR_FLOOR_CONTROLLER_CLASS and rawNodeRef ~= "" then
            local terminalSpawnable, resolvedNodeRef = self:resolveConnectionTargetSpawnable(rawNodeRef)
            local terminalElement = terminalSpawnable and terminalSpawnable.object or nil
            local folderElement = terminalElement and terminalElement.parent or nil
            local markerElement = nil

            if folderElement and folderElement.childs then
                for _, child in ipairs(folderElement.childs) do
                    if child ~= terminalElement
                        and utils.isA(child, "spawnableElement")
                        and child.spawnable
                        and child.spawnable.modulePath == "meta/staticMarker" then
                        markerElement = child
                        break
                    end
                end
            end

            table.insert(entries, {
                connection = connection,
                connectionIndex = connectionIndex,
                rawNodeRef = rawNodeRef,
                nodeRef = resolvedNodeRef,
                terminalSpawnable = terminalSpawnable,
                terminalElement = terminalElement,
                folderElement = folderElement,
                markerElement = markerElement
            })
        end
    end

    return entries
end

---@return table[]
function device:getLiftFloorDoorDefinitions()
    local ordered = { "common", "industrial" }
    local definitions = {}

    for _, key in ipairs(ordered) do
        local definition = LIFT_FLOOR_DOOR_DEFINITIONS[key]
        if definition then
            table.insert(definitions, {
                key = definition.key,
                label = definition.label,
                spawnData = definition.spawnData
            })
        end
    end

    return definitions
end

---@param parent element
---@param namePrefix string
---@return string
function device:getNextLiftFloorDoorName(parent, namePrefix)
    local prefix = tostring(namePrefix or "Lift_Door")
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

---@param entry table
---@return table[]
function device:getLiftFloorDoorEntries(entry)
    local floorDoorEntries = {}
    if not entry or not entry.terminalSpawnable then
        return floorDoorEntries
    end

    registry.update()

    local terminalSpawnable = entry.terminalSpawnable
    terminalSpawnable.deviceConnections = terminalSpawnable.deviceConnections or {}

    local seenNodeRefs = {}
    local floorGroup = entry.folderElement

    local function appendDoorEntry(connection, connectionIndex, rawNodeRef, resolvedNodeRef, doorSpawnable)
        local doorElement = doorSpawnable and doorSpawnable.object or nil
        local spawnData = string.lower(tostring(doorSpawnable and doorSpawnable.spawnData or ""))
        local definitionKey = LIFT_FLOOR_DOOR_BY_SPAWNDATA[spawnData]
        local definition = definitionKey and LIFT_FLOOR_DOOR_DEFINITIONS[definitionKey] or nil

        local finalNodeRef = utils.sanitizeText(resolvedNodeRef)
        if finalNodeRef == "" then
            finalNodeRef = utils.sanitizeText(rawNodeRef)
        end

        local className = utils.sanitizeText(connection and connection.deviceClassName or "")
        if className == "" and doorSpawnable then
            className = utils.sanitizeText(doorSpawnable.deviceClassName)
        end

        table.insert(floorDoorEntries, {
            connection = connection,
            connectionIndex = connectionIndex,
            rawNodeRef = utils.sanitizeText(rawNodeRef),
            nodeRef = finalNodeRef,
            doorSpawnable = doorSpawnable,
            doorElement = doorElement,
            doorType = definition and definition.key or "custom",
            doorLabel = definition and definition.label or "Custom Door",
            doorSpawnData = doorSpawnable and doorSpawnable.spawnData or (definition and definition.spawnData or ""),
            doorClassName = className
        })

        if finalNodeRef ~= "" then
            seenNodeRefs[finalNodeRef] = true
        end
    end

    for connectionIndex, connection in ipairs(terminalSpawnable.deviceConnections) do
        local className = utils.sanitizeText(connection.deviceClassName)
        local rawNodeRef = utils.sanitizeText(connection.nodeRef)
        if rawNodeRef ~= "" then
            local doorSpawnable, resolvedNodeRef = self:resolveConnectionTargetSpawnable(rawNodeRef)
            local doorElement = doorSpawnable and doorSpawnable.object or nil
            local spawnData = string.lower(tostring(doorSpawnable and doorSpawnable.spawnData or ""))
            local definitionKey = LIFT_FLOOR_DOOR_BY_SPAWNDATA[spawnData]
            local hasKnownSpawnData = definitionKey ~= nil
            local inFloorGroup = floorGroup and doorElement and doorElement.parent == floorGroup
            local classNameLower = string.lower(className)
            local looksLikeDoorConnection = classNameLower ~= "" and string.find(classNameLower, "door", 1, true) ~= nil

            if hasKnownSpawnData or inFloorGroup or looksLikeDoorConnection then
                appendDoorEntry(connection, connectionIndex, rawNodeRef, resolvedNodeRef, doorSpawnable)
            end
        end
    end

    if floorGroup and floorGroup.childs then
        for _, child in ipairs(floorGroup.childs) do
            if child ~= entry.terminalElement
                and utils.isA(child, "spawnableElement")
                and child.spawnable then
                local spawnData = string.lower(tostring(child.spawnable.spawnData or ""))
                local definitionKey = LIFT_FLOOR_DOOR_BY_SPAWNDATA[spawnData]
                if definitionKey then
                    local childNodeRef = utils.sanitizeText(child.spawnable.nodeRef)
                    if childNodeRef ~= "" and not seenNodeRefs[childNodeRef] then
                        appendDoorEntry(nil, nil, childNodeRef, childNodeRef, child.spawnable)
                    end
                end
            end
        end
    end

    return floorDoorEntries
end

---@param entry table
---@param doorType string
function device:addLiftFloorDoor(entry, doorType)
    if not entry or not entry.folderElement or not entry.terminalSpawnable then
        return
    end

    if self.object and self.object.isLocked and self.object:isLocked() then
        return
    end

    local doorDefinition = getLiftFloorDoorDefinition(doorType)
    if not doorDefinition then
        return
    end

    local floorGroup = entry.folderElement
    local terminalSpawnable = entry.terminalSpawnable
    terminalSpawnable.deviceConnections = terminalSpawnable.deviceConnections or {}

    local terminalPosition = (entry.terminalSpawnable and entry.terminalSpawnable.position) or self.position
    local markerPosition = (entry.markerElement and entry.markerElement.spawnable and entry.markerElement.spawnable.position) or terminalPosition
    local sourceRotation = (entry.terminalSpawnable and entry.terminalSpawnable.rotation) or self.rotation

    local markerX = tonumber(markerPosition and markerPosition.x) or tonumber(terminalPosition and terminalPosition.x) or 0
    local markerY = tonumber(markerPosition and markerPosition.y) or tonumber(terminalPosition and terminalPosition.y) or 0
    local markerZ = tonumber(markerPosition and markerPosition.z) or tonumber(terminalPosition and terminalPosition.z) or 0
    local terminalX = tonumber(terminalPosition and terminalPosition.x) or markerX
    local terminalY = tonumber(terminalPosition and terminalPosition.y) or markerY
    local towardTerminalFactor = 0.8

    local doorPosition = Vector4.new(
        markerX + (terminalX - markerX) * towardTerminalFactor,
        markerY + (terminalY - markerY) * towardTerminalFactor,
        markerZ,
        0
    )
    local doorRotation = EulerAngles.new(
        tonumber(sourceRotation and sourceRotation.roll) or 0,
        tonumber(sourceRotation and sourceRotation.pitch) or 0,
        tonumber(sourceRotation and sourceRotation.yaw) or 0
    )

    local doorSeed = device:new()
    doorSeed:loadSpawnData({
        spawnData = doorDefinition.spawnData,
        app = "default",
        nodeRef = "",
        persistent = false,
        deviceClassName = DEFAULT_DOOR_CONNECTION_CLASS,
        deviceConnections = {},
        instanceDataChanges = {},
        defaultComponentData = {}
    }, doorPosition, doorRotation)

    local doorElement = spawnableElement:new(self.object.sUI)
    doorElement:load({
        name = self:getNextLiftFloorDoorName(floorGroup, doorDefinition.namePrefix),
        spawnable = doorSeed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    doorElement:setParent(floorGroup)
    floorGroup.headerOpen = true

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()

    local doorSpawnable = doorElement.spawnable
    doorSpawnable.nodeRef = registry.generate(doorElement)
    registry.invalidate()

    local doorNodeRef = utils.sanitizeText(doorSpawnable.nodeRef)
    local connectionClassName = utils.sanitizeText(doorSpawnable.deviceClassName)
    if connectionClassName == "" then
        connectionClassName = utils.sanitizeText(self:resolveConnectionClassName(doorNodeRef))
    end
    if connectionClassName == "" then
        connectionClassName = DEFAULT_DOOR_CONNECTION_CLASS
    end

    local alreadyConnected = false
    for _, connection in ipairs(terminalSpawnable.deviceConnections) do
        if utils.sanitizeText(connection.nodeRef) == doorNodeRef then
            alreadyConnected = true
            if utils.sanitizeText(connection.deviceClassName) == "" then
                connection.deviceClassName = connectionClassName
            end
            break
        end
    end

    if not alreadyConnected then
        table.insert(terminalSpawnable.deviceConnections, {
            deviceClassName = connectionClassName,
            nodeRef = doorNodeRef
        })
    end

    local actions = {}
    local terminalOwner = entry.terminalElement or self.object
    if terminalOwner then
        table.insert(actions, history.getElementChange(terminalOwner))
    end
    table.insert(actions, history.getInsert({ doorElement }))

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()
end

---@param entry table
---@param doorEntry table
---@param newNodeRef string
function device:updateLiftFloorDoorNodeRef(entry, doorEntry, newNodeRef)
    if not entry or not doorEntry or not entry.terminalSpawnable then
        return
    end

    local normalizedNodeRef = utils.sanitizeText(newNodeRef)
    if normalizedNodeRef == "" then
        return
    end
    local currentNodeRef = utils.sanitizeText(doorEntry.connection and doorEntry.connection.nodeRef or doorEntry.nodeRef or doorEntry.rawNodeRef or "")
    if normalizedNodeRef == currentNodeRef then
        return
    end

    local actions = {}
    local terminalOwner = entry.terminalElement or self.object
    if terminalOwner then
        table.insert(actions, history.getElementChange(terminalOwner))
    end
    if doorEntry.doorElement then
        table.insert(actions, history.getElementChange(doorEntry.doorElement))
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end

    local terminalConnections = entry.terminalSpawnable.deviceConnections or {}
    entry.terminalSpawnable.deviceConnections = terminalConnections

    local connection = doorEntry.connection
    if not connection then
        local className = utils.sanitizeText(doorEntry.doorClassName)
        if className == "" then
            className = utils.sanitizeText(doorEntry.doorSpawnable and doorEntry.doorSpawnable.deviceClassName)
        end
        if className == "" then
            className = utils.sanitizeText(self:resolveConnectionClassName(normalizedNodeRef))
        end
        if className == "" then
            className = DEFAULT_DOOR_CONNECTION_CLASS
        end

        connection = {
            deviceClassName = className,
            nodeRef = normalizedNodeRef
        }
        table.insert(terminalConnections, connection)
        doorEntry.connection = connection
        doorEntry.connectionIndex = #terminalConnections
    else
        connection.nodeRef = normalizedNodeRef
        if utils.sanitizeText(connection.deviceClassName) == "" then
            local className = utils.sanitizeText(self:resolveConnectionClassName(normalizedNodeRef))
            if className == "" then
                className = utils.sanitizeText(doorEntry.doorClassName)
            end
            if className == "" then
                className = DEFAULT_DOOR_CONNECTION_CLASS
            end
            connection.deviceClassName = className
        end
    end

    if doorEntry.doorSpawnable then
        doorEntry.doorSpawnable.nodeRef = normalizedNodeRef
    end
    doorEntry.nodeRef = normalizedNodeRef
    doorEntry.rawNodeRef = normalizedNodeRef

    self:refreshNodeRefCaches()
end

---@param entry table
---@param doorEntry table
function device:generateLiftFloorDoorNodeRef(entry, doorEntry)
    if not doorEntry or not doorEntry.doorElement then
        return
    end

    self:updateLiftFloorDoorNodeRef(entry, doorEntry, registry.generate(doorEntry.doorElement))
end

---@param entry table
---@param doorEntry table
function device:removeLiftFloorDoor(entry, doorEntry)
    if not entry or not doorEntry or not entry.terminalSpawnable then
        return
    end

    local terminalConnections = entry.terminalSpawnable.deviceConnections or {}
    entry.terminalSpawnable.deviceConnections = terminalConnections

    local targetNodeRef = utils.sanitizeText(doorEntry.connection and doorEntry.connection.nodeRef or doorEntry.nodeRef or doorEntry.rawNodeRef or "")
    local removedConnection = false

    for index = #terminalConnections, 1, -1 do
        local connection = terminalConnections[index]
        local sameConnection = doorEntry.connection and connection == doorEntry.connection
        local sameNodeRef = targetNodeRef ~= "" and utils.sanitizeText(connection.nodeRef) == targetNodeRef

        if sameConnection or sameNodeRef then
            table.remove(terminalConnections, index)
            removedConnection = true
            if sameConnection then
                break
            end
        end
    end

    local removeAction = nil
    if doorEntry.doorElement then
        removeAction = history.getRemove({ doorEntry.doorElement })
        doorEntry.doorElement:remove()
    end

    if not removedConnection and not removeAction then
        return
    end

    local actions = {}
    local terminalOwner = entry.terminalElement or self.object
    if terminalOwner then
        table.insert(actions, history.getElementChange(terminalOwner))
    end
    if removeAction then
        table.insert(actions, removeAction)
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end

    self:refreshNodeRefCaches()
end

function device:addLiftFloor()
    if not self.object or not self.object.parent or self.object:isLocked() then
        return
    end

    local parent = self.object.parent
    local actions = {}

    if not utils.isA(parent, "positionableGroup") then
        local wrappedParent, wrapAction = self:ensureOwnParentGroup()
        if wrappedParent then
            parent = wrappedParent
        end
        if wrapAction then
            table.insert(actions, wrapAction)
        end
    end

    if not parent then
        return
    end

    local floorIndex = self:getNextElevatorFloorIndex(parent)
    local suffix = tostring(floorIndex)
    local elevatorPosition = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    local markerPosition = Vector4.new(elevatorPosition.x, elevatorPosition.y, elevatorPosition.z, 0)
    local terminalPosition = self:getLiftDoorWorldPosition(1) or markerPosition
    local rotation = EulerAngles.new(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)

    local group = positionableGroup:new(self.object.sUI)
    group.name = "Elevator_Floor_" .. suffix
    group.headerOpen = true
    group:setParent(parent)
    parent.headerOpen = true

    local markerSeed = staticMarker:new()
    markerSeed:loadSpawnData({
        app = "default",
        nodeRef = "",
        questMarker = false,
        previewed = true
    }, markerPosition, rotation)

    local markerElement = spawnableElement:new(self.object.sUI)
    markerElement:load({
        name = "Ground_Marker_Floor_" .. suffix,
        spawnable = markerSeed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    markerElement:setParent(group)

    local terminalSeed = device:new()
    terminalSeed:loadSpawnData({
        spawnData = ELEVATOR_FLOOR_TERMINAL_PATH,
        app = "default",
        nodeRef = "",
        persistent = true,
        deviceClassName = ELEVATOR_FLOOR_CONTROLLER_CLASS,
        deviceConnections = {},
        instanceDataChanges = {},
        defaultComponentData = {}
    }, terminalPosition, rotation)

    local terminalElement = spawnableElement:new(self.object.sUI)
    terminalElement:load({
        name = "Terminal_Floor_" .. suffix,
        spawnable = terminalSeed:save(),
        modulePath = "modules/classes/editor/spawnableElement"
    })
    terminalElement:setParent(group)

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end
    registry.invalidate()

    local markerSpawnable = markerElement.spawnable
    markerSpawnable.nodeRef = registry.generate(markerElement)
    registry.invalidate()

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end

    local terminalSpawnable = terminalElement.spawnable
    terminalSpawnable.nodeRef = registry.generate(terminalElement)
    terminalSpawnable.persistent = true
    terminalSpawnable.deviceClassName = ELEVATOR_FLOOR_CONTROLLER_CLASS
    registry.invalidate()

    self:applyLiftFloorSetupToTerminal(terminalSpawnable, markerSpawnable.nodeRef)

    local objectChange = history.getElementChange(self.object)
    table.insert(self.deviceConnections, {
        deviceClassName = ELEVATOR_FLOOR_CONTROLLER_CLASS,
        nodeRef = terminalSpawnable.nodeRef
    })

    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end

    local insertAction = history.getInsert({ group })
    table.insert(actions, objectChange)
    table.insert(actions, insertAction)

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end
end

---@param entries table[]
---@param index number
---@param direction number
function device:moveLiftFloor(entries, index, direction)
    local targetIndex = index + direction
    if targetIndex < 1 or targetIndex > #entries then
        return
    end

    local ownConnectionIndex = entries[index].connectionIndex
    local targetConnectionIndex = entries[targetIndex].connectionIndex
    if not ownConnectionIndex or not targetConnectionIndex then
        return
    end

    history.addAction(history.getElementChange(self.object))
    self.deviceConnections[ownConnectionIndex], self.deviceConnections[targetConnectionIndex]
        = self.deviceConnections[targetConnectionIndex], self.deviceConnections[ownConnectionIndex]
end

---@param entry table
function device:removeLiftFloor(entry)
    if not entry or not entry.connectionIndex then
        return
    end

    local actions = { history.getElementChange(self.object) }
    local removalTarget = entry.folderElement or entry.terminalElement

    if removalTarget then
        table.insert(actions, history.getRemove({ removalTarget }))
    end

    local connection = self.deviceConnections[entry.connectionIndex]
    if connection then
        self.connectionNodeRefSearch[tostring(connection)] = nil
        table.remove(self.deviceConnections, entry.connectionIndex)
    end

    if removalTarget then
        removalTarget:remove()
    end

    registry.invalidate()
    if self.object.sUI and self.object.sUI.cachePaths then
        self.object.sUI.cachePaths()
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end
end

---@param entry table
---@param componentID string
---@param floorSetup table
---@return table
function device:updateElevatorFloorSetup(entry, componentID, floorSetup)
    local markerNodeRef = entry.markerElement
        and entry.markerElement.spawnable
        and entry.markerElement.spawnable.nodeRef
        or nil

    local normalized = self:normalizeElevatorFloorSetup(floorSetup, markerNodeRef)
    self:updateComponentPathValue(
        entry.terminalSpawnable,
        componentID,
        { "persistentState", "Data", "elevatorFloorSetup" },
        normalized
    )

    return normalized
end

-- Sound system / speaker chain -------------------------------------------------------------------

---@return string?
function device:getSoundSystemComponentID()
    return self:getPersistentComponentID(
        self,
        soundSystemData.SOUND_SYSTEM_CONTROLLER_CLASS,
        soundSystemData.SOUND_SYSTEM_COMPONENT_ID
    )
end

---Normalized `soundSystemSettings` entries, plus the component they live on.
---@return table[], string?
function device:getSoundSystemEntries()
    local componentID = self:getSoundSystemComponentID()
    if not componentID then
        return {}, nil
    end

    local raw = self:getComponentPathArray(self, componentID, soundSystemData.SETTINGS_PATH)
    local entries = {}

    for index = 1, #raw do
        table.insert(entries, soundSystemData.normalizeEntry(raw[index]))
    end

    return entries, componentID
end

---Writes entries and clamps `defaultAction` to the array bounds.
---@param entries table[]
---@param componentID string?
function device:setSoundSystemEntries(entries, componentID)
    componentID = componentID or self:getSoundSystemComponentID()
    if not componentID then
        return
    end

    local normalized = {}
    for index = 1, #entries do
        table.insert(normalized, soundSystemData.normalizeEntry(entries[index]))
    end

    -- Clamp without respawning before the array write.
    local defaultAction = math.floor(tonumber(
        self:getComponentPathValue(self, componentID, soundSystemData.DEFAULT_ACTION_PATH)
    ) or 0)
    local clampedAction = math.max(0, math.min(defaultAction, math.max(0, #normalized - 1)))

    if clampedAction ~= defaultAction then
        self:updateComponentPathValue(
            self,
            componentID,
            soundSystemData.DEFAULT_ACTION_PATH,
            clampedAction,
            { suppressRespawn = true }
        )
    end

    self:updateComponentPathValue(self, componentID, soundSystemData.SETTINGS_PATH, normalized)
end

---@param options table?
function device:addSoundSystemEntry(options)
    local entries, componentID = self:getSoundSystemEntries()
    if not componentID then
        return
    end

    history.addAction(history.getElementChange(self.object))
    table.insert(entries, soundSystemData.createEntry(options))
    self:setSoundSystemEntries(entries, componentID)
end

---@param index number
function device:removeSoundSystemEntry(index)
    local entries, componentID = self:getSoundSystemEntries()
    if not componentID or not entries[index] then
        return
    end

    history.addAction(history.getElementChange(self.object))
    table.remove(entries, index)
    self:setSoundSystemEntries(entries, componentID)
end

---@param index number
---@param direction number
function device:moveSoundSystemEntry(index, direction)
    local targetIndex = index + direction
    local entries, componentID = self:getSoundSystemEntries()

    if not componentID or targetIndex < 1 or targetIndex > #entries or not entries[index] then
        return
    end

    history.addAction(history.getElementChange(self.object))
    entries[index], entries[targetIndex] = entries[targetIndex], entries[index]
    self:setSoundSystemEntries(entries, componentID)
end

---Replaces one complete `musicSettings` entry.
---@param index number
---@param entry table
function device:updateSoundSystemEntry(index, entry)
    local entries, componentID = self:getSoundSystemEntries()
    if not componentID or not entries[index] then
        return
    end

    entries[index] = soundSystemData.normalizeEntry(entry)
    self:setSoundSystemEntries(entries, componentID)
end

---Returns speaker connections and their spawnables when found.
---@return table[]
function device:getSpeakerEntries()
    return self:getResolvedDeviceConnections(self, {
        className = soundSystemData.SPEAKER_CONTROLLER_CLASS,
        requireNodeRef = true,
        decorate = function (entry)
            local definition = entry.spawnable
                and soundSystemData.resolveSpeakerDefinition(entry.spawnable.spawnData)
                or nil

            entry.speakerSpawnable = entry.spawnable
            entry.speakerElement = entry.element
            entry.definition = definition
            entry.label = definition and definition.label or "Speaker"
        end
    })
end

---Returns connections ignored because their targets are not speakers.
---@return { nodeRef: string, className: string, reason: string, element: element? }[]
function device:getIgnoredSlaveConnections()
    return self:getResolvedDeviceConnections(self, {
        requireNodeRef = true,
        filter = function (_, className)
            return soundSystemData.getSlaveRejectionReason(className) ~= nil
        end,
        decorate = function (entry)
            entry.reason = soundSystemData.getSlaveRejectionReason(entry.className)
        end
    })
end

---Returns the first free `<prefix>_<n>` child name.
---@param parent element
---@param namePrefix string
---@return string
function device:getNextChildName(parent, namePrefix)
    local prefix = tostring(namePrefix or "Node")
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

---Creates and connects a speaker with a NodeRef.
---@param speakerType string `speaker` or `virtual`
function device:addSpeaker(speakerType)
    if not self.object or not self.object.parent or self.object:isLocked() then
        return
    end

    local definition = soundSystemData.SPEAKER_DEFINITIONS[string.lower(tostring(speakerType or ""))]
    if not definition then
        return
    end

    local actions = {}
    local parent, wrapAction = self:getQuickSetupChildParent()
    if wrapAction then
        table.insert(actions, wrapAction)
    end

    if not parent then
        return
    end

    -- Nothing in the data says where a speaker belongs, so it starts on the system and gets dragged.
    local position = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    local rotation = EulerAngles.new(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)

    local speakerElement, speakerSpawnable = self:createChildDeviceNode(parent, {
        spawnData = definition.spawnData,
        app = definition.defaultApp,
        controllerClass = soundSystemData.SPEAKER_CONTROLLER_CLASS,
        namePrefix = definition.namePrefix,
        position = position,
        rotation = rotation
    })
    if not speakerElement or not speakerSpawnable then
        return
    end

    table.insert(actions, history.getElementChange(self.object))
    table.insert(self.deviceConnections, {
        deviceClassName = soundSystemData.SPEAKER_CONTROLLER_CLASS,
        nodeRef = utils.sanitizeText(speakerSpawnable.nodeRef)
    })

    table.insert(actions, history.getInsert({ speakerElement }))

    self:refreshNodeRefCaches()

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end
end

---Updates a speaker and its connection to the same NodeRef.
---@param speakerEntry table
---@param newNodeRef string
function device:updateSpeakerNodeRef(speakerEntry, newNodeRef)
    if not speakerEntry then
        return
    end

    local normalizedNodeRef = utils.sanitizeText(newNodeRef)
    if normalizedNodeRef == "" then
        return
    end

    local connectionNodeRef = utils.sanitizeText(speakerEntry.connection and speakerEntry.connection.nodeRef or "")
    local currentNodeRef = utils.sanitizeText(speakerEntry.nodeRef or speakerEntry.rawNodeRef or "")
    local needsReferrerRewrite = connectionNodeRef ~= "" and currentNodeRef ~= "" and connectionNodeRef ~= currentNodeRef

    if normalizedNodeRef == currentNodeRef and not needsReferrerRewrite then
        return
    end

    if not speakerEntry.speakerSpawnable then
        history.addAction(history.getElementChange(self.object))

        if speakerEntry.connection then
            speakerEntry.connection.nodeRef = normalizedNodeRef
        end

        speakerEntry.nodeRef = normalizedNodeRef
        speakerEntry.rawNodeRef = normalizedNodeRef
        self:refreshNodeRefCaches()

        return
    end

    self:updateNodeRefAndReferrers(speakerEntry.speakerSpawnable, speakerEntry.speakerElement, normalizedNodeRef, {
        currentNodeRef = currentNodeRef,
        includeOwnerChange = true,
        rewriteReferrersOnSameValue = needsReferrerRewrite,
        onUpdated = function (updatedNodeRef)
            if speakerEntry.connection then
                speakerEntry.connection.nodeRef = updatedNodeRef
            end

            speakerEntry.nodeRef = updatedNodeRef
            speakerEntry.rawNodeRef = updatedNodeRef
        end
    })
end

---@param speakerEntry table
function device:generateSpeakerNodeRef(speakerEntry)
    if not speakerEntry or not speakerEntry.speakerElement then
        return
    end

    self:updateSpeakerNodeRef(speakerEntry, registry.generate(speakerEntry.speakerElement))
end

---Removes the speaker node and its connection row.
---@param speakerEntry table
function device:removeSpeaker(speakerEntry)
    if not speakerEntry then
        return
    end

    local targetNodeRef = utils.sanitizeText(
        speakerEntry.connection and speakerEntry.connection.nodeRef
        or speakerEntry.nodeRef
        or speakerEntry.rawNodeRef
        or ""
    )
    local removedConnection = false

    for index = #self.deviceConnections, 1, -1 do
        local connection = self.deviceConnections[index]
        local sameConnection = speakerEntry.connection and connection == speakerEntry.connection
        local sameNodeRef = targetNodeRef ~= "" and utils.sanitizeText(connection.nodeRef) == targetNodeRef

        if sameConnection or sameNodeRef then
            self.connectionNodeRefSearch[tostring(connection)] = nil
            table.remove(self.deviceConnections, index)
            removedConnection = true
            if sameConnection then
                break
            end
        end
    end

    local removeAction = nil
    if speakerEntry.speakerElement then
        removeAction = history.getRemove({ speakerEntry.speakerElement })
        speakerEntry.speakerElement:remove()
    end

    if not removedConnection and not removeAction then
        return
    end

    local actions = { history.getElementChange(self.object) }
    if removeAction then
        table.insert(actions, removeAction)
    end

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    else
        history.addAction(actions[1])
    end

    self:refreshNodeRefCaches()
end

---@param speakerSpawnable entity
---@return table?, string? setup, componentID
function device:getSpeakerSetup(speakerSpawnable)
    if not speakerSpawnable then
        return nil, nil
    end

    local componentID = self:getPersistentComponentID(
        speakerSpawnable,
        soundSystemData.SPEAKER_CONTROLLER_CLASS,
        soundSystemData.SPEAKER_COMPONENT_ID
    )
    if not componentID then
        return nil, nil
    end

    local setup = self:getComponentPathValue(speakerSpawnable, componentID, soundSystemData.SPEAKER_SETUP_PATH)

    return soundSystemData.normalizeSpeakerSetup(setup), componentID
end

---@param speakerSpawnable entity
---@param componentID string
---@param setup table
---@return table
function device:updateSpeakerSetup(speakerSpawnable, componentID, setup)
    local normalized = soundSystemData.normalizeSpeakerSetup(setup)

    self:updateComponentPathValue(
        speakerSpawnable,
        componentID,
        soundSystemData.SPEAKER_SETUP_PATH,
        normalized
    )

    return normalized
end

---Finds devices that reference this sound system.
---@return table[]
function device:getSoundSystemMasters()
    local ownNodeRef = utils.sanitizeText(self.nodeRef)
    if ownNodeRef == "" or not self.object or not self.object.getRootParent then
        return {}
    end

    local ownHash = utils.nodeRefStringToHashString(ownNodeRef)
    local root = self.object:getRootParent()
    if not root or not root.getPathsRecursive then
        return {}
    end

    local entries = {}

    for _, path in ipairs(root:getPathsRecursive(true)) do
        local ref = path.ref
        local spawnable = utils.isA(ref, "spawnableElement") and ref.spawnable or nil

        if spawnable and spawnable ~= self and type(spawnable.deviceConnections) == "table" then
            for connectionIndex, connection in ipairs(spawnable.deviceConnections) do
                local className = utils.sanitizeText(connection.deviceClassName)
                local targetNodeRef = utils.sanitizeText(connection.nodeRef)

                if className == soundSystemData.SOUND_SYSTEM_CONTROLLER_CLASS
                    and targetNodeRef ~= ""
                    and (targetNodeRef == ownNodeRef or utils.nodeRefStringToHashString(targetNodeRef) == ownHash) then
                    local definition = soundSystemData.resolveMasterDefinition(spawnable.spawnData)

                    table.insert(entries, {
                        connection = connection,
                        connectionIndex = connectionIndex,
                        nodeRef = utils.sanitizeText(spawnable.nodeRef),
                        masterSpawnable = spawnable,
                        masterElement = ref,
                        definition = definition,
                        label = definition and definition.label or utils.sanitizeText(spawnable.deviceClassName),
                        isComputer = definition and definition.isComputer == true
                    })

                    break
                end
            end
        end
    end

    return entries
end

---Updates a master's NodeRef without changing its connection.
---@param masterEntry table
---@param newNodeRef string
function device:updateSoundSystemMasterNodeRef(masterEntry, newNodeRef)
    if not masterEntry or not masterEntry.masterSpawnable then
        return
    end

    self:updateNodeRefAndReferrers(masterEntry.masterSpawnable, masterEntry.masterElement, newNodeRef, {
        updateReferrers = false,
        onUpdated = function (updatedNodeRef)
            masterEntry.nodeRef = updatedNodeRef

            if self.soundSystemSelection and self.soundSystemSelection.kind == "master" then
                self.soundSystemSelection = { kind = "master", key = "nodeRef:" .. updatedNodeRef }
            end
        end
    })
end

---@param masterEntry table
function device:generateSoundSystemMasterNodeRef(masterEntry)
    if not masterEntry or not masterEntry.masterElement then
        return
    end

    self:updateSoundSystemMasterNodeRef(masterEntry, registry.generate(masterEntry.masterElement))
end

---Creates and configures a master for this sound system.
---@param masterType string Key from `soundSystemData.MASTER_DEFINITIONS`
function device:addSoundSystemMaster(masterType)
    if not self.object or not self.object.parent or self.object:isLocked() then
        return
    end

    local definition = soundSystemData.MASTER_DEFINITIONS[tostring(masterType or "")]
    if not definition then
        return
    end

    -- The connection is stored on the master and points here, so this system needs a NodeRef first.
    local ownNodeRef = utils.sanitizeText(self.nodeRef)
    if ownNodeRef == "" then
        return
    end

    local actions = {}
    local parent, wrapAction = self:getQuickSetupChildParent()
    if wrapAction then
        table.insert(actions, wrapAction)
    end

    if not parent then
        return
    end

    local position = Vector4.new(self.position.x, self.position.y, self.position.z, 0)
    local rotation = EulerAngles.new(self.rotation.roll, self.rotation.pitch, self.rotation.yaw)

    local masterElement, masterSpawnable = self:createChildDeviceNode(parent, {
        spawnData = definition.spawnData,
        app = definition.defaultApp,
        controllerClass = definition.controllerClass,
        namePrefix = definition.namePrefix,
        position = position,
        rotation = rotation,
        persistent = true,
        deviceConnections = {
            {
                deviceClassName = soundSystemData.SOUND_SYSTEM_CONTROLLER_CLASS,
                nodeRef = ownNodeRef
            }
        }
    })
    if not masterElement or not masterSpawnable then
        return
    end

    if definition.isComputer then
        self:applyComputerTerminalPreset(masterSpawnable)
    end

    table.insert(actions, history.getInsert({ masterElement }))

    self:refreshNodeRefCaches()

    if #actions > 1 then
        history.addAction(history.getComposite(actions))
    elseif #actions == 1 then
        history.addAction(actions[1])
    end
end

---@param masterEntry table
function device:removeSoundSystemMaster(masterEntry)
    if not masterEntry or not masterEntry.masterElement then
        return
    end

    local removeAction = history.getRemove({ masterEntry.masterElement })
    masterEntry.masterElement:remove()
    history.addAction(removeAction)

    self:refreshNodeRefCaches()
end

---@param masterSpawnable entity
---@return table?, string? setup, componentID
function device:getComputerSetup(masterSpawnable)
    if not masterSpawnable then
        return nil, nil
    end

    local componentID = self:getPersistentComponentID(
        masterSpawnable,
        soundSystemData.COMPUTER_CONTROLLER_CLASS,
        soundSystemData.COMPUTER_COMPONENT_ID
    )
    if not componentID then
        return nil, nil
    end

    local setup = self:getComponentPathValue(masterSpawnable, componentID, soundSystemData.COMPUTER_SETUP_PATH)

    return soundSystemData.normalizeComputerSetup(setup), componentID
end

---@param masterSpawnable entity
---@param componentID string
---@param setup table
---@return table
function device:updateComputerSetup(masterSpawnable, componentID, setup)
    local normalized = soundSystemData.normalizeComputerSetup(setup)

    self:updateComponentPathValue(
        masterSpawnable,
        componentID,
        soundSystemData.COMPUTER_SETUP_PATH,
        normalized
    )

    return normalized
end

---Writes terminal flags once the computer state is readable.
---@param masterSpawnable entity
function device:applyComputerTerminalPreset(masterSpawnable)
    if not masterSpawnable then
        return
    end

    local function applyNow(applyOptions)
        local setup, componentID = self:getComputerSetup(masterSpawnable)
        if not setup or not componentID then
            return false
        end

        self:updateComponentPathValue(
            masterSpawnable,
            componentID,
            soundSystemData.COMPUTER_SETUP_PATH,
            soundSystemData.applyComputerTerminalPreset(setup),
            { suppressRespawn = (applyOptions or {}).suppressRespawn == true }
        )

        return true
    end

    if applyNow() then
        return
    end

    if masterSpawnable._pendingComputerTerminalPreset then
        return
    end

    masterSpawnable._pendingComputerTerminalPreset = true
    if masterSpawnable.registerSpawnedAndAttachedCallback then
        masterSpawnable:registerSpawnedAndAttachedCallback(function ()
            -- Defer past attachment to avoid unsafe respawn timing.
            Cron.After(0.05, function ()
                masterSpawnable._pendingComputerTerminalPreset = nil
                if masterSpawnable.object then
                    applyNow({ suppressRespawn = true })
                end
            end)
        end)
    else
        masterSpawnable._pendingComputerTerminalPreset = nil
    end
end

quickElevatorSetupUI.install(device)

quickSoundSystemSetupUI.install(device)

-- Most scriptable devices expose `deviceOperationsSetup`.
quickDeviceOperationsSetupUI.install(device)

-- Show only when the entity has a transform animator component.
quickTransformAnimationSetupUI.install(device)

-- Quick Security opens from either a system or one of its areas.
quickSecuritySetupUI.install(device)

function device:draw()
    self:drawEntityBaseProperties()

    if not self.maxPropertyWidth then
        self.maxPropertyWidth = utils.getTextMaxWidth(propertyNames) + 4 * ImGui.GetStyle().ItemSpacing.x
    end

    if self.deviceClassName == LIFT_CONTROLLER_CLASS then
        if ImGui.Button("Quick Elevator Setup##openLiftSetupPopup") then
            ImGui.OpenPopup(quickElevatorSetupUI.POPUP_ID)
        end
        style.tooltip("Open quick setup for LiftControllerPS and connected elevator floor terminals.")
        self:drawLiftSetupPopup()
    end

    if self.deviceClassName == soundSystemData.SOUND_SYSTEM_CONTROLLER_CLASS then
        if ImGui.Button("Quick Sound System Setup##openSoundSystemSetupPopup") then
            ImGui.OpenPopup(quickSoundSystemSetupUI.POPUP_ID)
        end
        style.tooltip("Open quick setup for SoundSystemControllerPS entries and connected speakers.")
        self:drawSoundSystemSetupPopup()
    end

    if securitySystemData.supportsSecuritySetup(self.deviceClassName) then
        if ImGui.Button("Quick Security System Setup##openSecuritySetupPopup") then
            ImGui.OpenPopup(quickSecuritySetupUI.POPUP_ID)
        end
        style.tooltip("Faction, area types, access levels, event filters and minimap policy for this security network.")
        self:drawSecuritySetupPopup()
    end

    if deviceOperationsData.classDerivesFrom(self.deviceClassName, deviceOperationsData.BASE_PS_CLASS) then
        if ImGui.Button("Device Operations##openDeviceOperationsPopup") then
            ImGui.OpenPopup(quickDeviceOperationsSetupUI.POPUP_ID)
        end
        style.tooltip("Sound, VFX, animations and component toggles driven by device state, actions, quest facts or volumes, with no scripting.")
        self:drawDeviceOperationsSetupPopup()
    end

    if transformAnimationsData.supportsTransformAnimations(self) then
        if ImGui.Button("Transform Animations##openTransformAnimationsPopup") then
            ImGui.OpenPopup(quickTransformAnimationSetupUI.POPUP_ID)
        end
        style.tooltip("Swing angle, travel distance, duration and easing for the entity's motion clips.")
        self:drawTransformAnimationSetupPopup()
    end

    style.mutedText("Persistent")
    ImGui.SameLine()
    ImGui.SetCursorPosX(self.maxPropertyWidth)
    self.persistent, _, _ = style.trackedCheckbox(self.object, "##persistent", self.persistent)
    if self.nodeRef == "" then
        self.persistent = false
        style.tooltip("Requires NodeRef to be set.")
    else
        style.tooltip("If true, the device will get an entry in the .psrep file. Not all devices need this, still subject to more testing.")
    end
    ImGui.SameLine()
    style.pushButtonNoBG(true)
    if ImGui.Button(IconGlyphs.Reload) then
        Game.GetPersistencySystem():ForgetObject(PersistentID.ForComponent(entEntityID.new({ hash = loadstring("return " .. utils.nodeRefStringToHashString(self.nodeRef) .. "ULL", "")() }), self.controllerComponent), true)
    end
    style.pushButtonNoBG(false)
    style.tooltip("Reloads the devices persistent state.\nApplies to the actual device in the world (Imported), not the editor.")

    self.connectionsHeaderState = ImGui.TreeNodeEx("Device Connections")

    if self.connectionsHeaderState then
        for index, connection in ipairs(self.deviceConnections) do
            ImGui.PushID(index)

            connection.deviceClassName = utils.sanitizeText(connection.deviceClassName)
            connection.nodeRef = utils.sanitizeText(connection.nodeRef)

            connection.deviceClassName, _, _ = style.trackedTextField(self.object, "##className", connection.deviceClassName, "gameDeviceComponentPS", 150)
            style.tooltip("Device class name of the connected device. Name of the gameDeviceComponentPS used in the devices gameDeviceComponent")

            ImGui.SameLine()
            local searchKey = tostring(connection)
            local searchValue = utils.sanitizeText(self.connectionNodeRefSearch[searchKey] or "")
            local nodeRefOptions = self:getConnectionNodeRefOptions(connection.nodeRef)
            local nodeRefChanged
            connection.nodeRef, searchValue, nodeRefChanged = style.trackedSearchDropdown(
                "##nodeRef",
                "Search node ref...",
                connection.nodeRef,
                searchValue,
                nodeRefOptions,
                {
                    element = self.object,
                    width = style.getMaxWidth(250) - 30,
                    matchContentWidth = true,
                    allowCustom = true,
                    tooltip = "NodeRef of the connected device. Select one from this root group, or type and choose 'Use custom: ...'."
                }
            )
            connection.nodeRef = utils.sanitizeText(connection.nodeRef)
            self.connectionNodeRefSearch[searchKey] = searchValue
            if nodeRefChanged then
                local resolvedClassName = self:resolveConnectionClassName(connection.nodeRef)
                if resolvedClassName and resolvedClassName ~= connection.deviceClassName then
                    connection.deviceClassName = resolvedClassName
                end
            end

            ImGui.SameLine()
            if style.dangerButton(IconGlyphs.DeleteOutline .. "##deleteDeviceConnection") then
                history.addAction(history.getElementChange(self.object))
                self.connectionNodeRefSearch[searchKey] = nil
                table.remove(self.deviceConnections, index)
                ImGui.PopID()
                break
            end
            style.tooltip("Delete")

            ImGui.PopID()
        end

        if ImGui.Button("+") then
            history.addAction(history.getElementChange(self.object))
            table.insert(self.deviceConnections, { deviceClassName = "", nodeRef = "" })
        end

        ImGui.TreePop()
    end

    self:drawRescaleEntityAction()
end

function device:getPSData()
    for _, data in pairs(self.instanceDataChanges) do
        if data.persistentState and data.persistentState.Data then
            self:prepareInstanceData(data.persistentState.Data)
            return data.persistentState.Data
        end
    end
end

function device:getProperties()
    local properties = entity.getProperties(self)
    table.insert(properties, {
        id = self.node .. "Visualization",
        name = "Visualization",
        defaultHeader = false,
        draw = function()
            style.mutedText("Visualize position")
            ImGui.SameLine()
            local changed
            self.showPositionMarker, changed = style.toggleButton(IconGlyphs.HospitalMarker, self.showPositionMarker)
            if changed then
                self:setPositionMarkerVisible(self.showPositionMarker)
                self:respawn()
            end
            style.tooltip("Draw a sphere marker at the entity position.")

            if self.deviceClassName == "LiftControllerPS" then
                style.mutedText("Show doors helper")
                ImGui.SameLine()
                self.showDoorsHelper, _ = style.toggleButton(IconGlyphs.Door, self.showDoorsHelper)
                style.tooltip("Draw numbered door helper markers around the lift.")
            end

            if self.deviceClassName == soundSystemData.SOUND_SYSTEM_CONTROLLER_CLASS then
                style.mutedText("Show speaker helper")
                ImGui.SameLine()
                self.showSpeakerHelper, _ = style.toggleButton(IconGlyphs.Speaker, self.showSpeakerHelper)
                style.tooltip("Draw a link line and numbered badge for each connected speaker.\nEach speaker's audible range follows that speaker's own range toggle.")
            elseif self.deviceClassName == soundSystemData.SPEAKER_CONTROLLER_CLASS then
                -- Toggle both views of the audible radius together.
                style.mutedText("Show range")
                ImGui.SameLine()
                local newRangeSphere, rangeSphereToggled = style.toggleButton(IconGlyphs.HospitalMarker, self.showSpeakerRangeSphere)
                if rangeSphereToggled then
                    history.addAction(history.getElementChange(self.object))
                    self:setSpeakerRangeSphereVisible(newRangeSphere)
                end
                style.tooltip("Draw this speaker's audible radius: a solid sphere in the world, the way the light radius preview does, and a ring on screen.")
            end
        end
    })
    return properties
end

function device:export(index, length)
    local data = entity.export(self, index, length)

    data.type = "worldDeviceNode"
    data.data.deviceConnections = {}

    local connections = {}
    local classOrder = {}

    -- Group by deviceClassName
    for _, connection in ipairs(self.deviceConnections) do
        if not connections[connection.deviceClassName] then
            connections[connection.deviceClassName] = {}
            table.insert(classOrder, connection.deviceClassName)
        end

        table.insert(connections[connection.deviceClassName], connection.nodeRef)
    end

    for _, className in ipairs(classOrder) do
        local connection = connections[className] or {}
        local nodeRefs = {}

        for _, nodeRef in ipairs(connection) do
            table.insert(nodeRefs, {
                ["$type"] = "NodeRef",
                ["$storage"] = "string",
                ["$value"] = nodeRef
            })
        end

        table.insert(data.data.deviceConnections, {
            ["$type"] = "worldDeviceConnections",
            ["deviceClassName"] = {
                ["$type"] = "CName",
                ["$storage"] = "string",
                ["$value"] = className
            },
            ["nodeRefs"] = nodeRefs
        })
    end

    return data
end

return device
