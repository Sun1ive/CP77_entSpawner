local style = require("modules/ui/style")
local utils = require("modules/utils/core/utils")
local registry = require("modules/utils/game/nodeRefRegistry")
local history = require("modules/utils/project/history")
local securityData = require("modules/utils/data/securitySystem")
local redValue = require("modules/utils/data/redValue")
local outlineConsumer = require("modules/utils/game/outlineConsumer")
local element = require("modules/classes/editor/element")
local graph = require("modules/utils/ui/quickSetupGraph")

---Quick setup for security networks.
---
---It renders the same network from a system or area selection and exposes settings that are awkward
---or risky in raw instance data: faction, minimap policy, access tiers, area volumes and schedules.
local quickSecuritySetupUI = {
    POPUP_ID = "Quick Security System Setup##wb-Device-wui"
}

local ADD_AREA_TOOLTIP = "Spawn an area, outline markers, binding, and system link. Undo removes the whole set."
local ADD_COMMUNITY_TOOLTIP = "Spawn a community node and wire it to this system, so its NPCs get alerted."
local ADD_DEVICE_TOOLTIP = "Spawn a camera, turret, alarm or detector and wire it into this network."

---@param device table
function quickSecuritySetupUI.install(device)
    if not device then
        return
    end

    -- Component resolution -----------------------------------------------------------------------

    ---The `controller` component of a security system or area.
    ---@param targetSpawnable table
    ---@param isArea boolean
    ---@return string?
    function device:getSecurityControllerComponentID(targetSpawnable, isArea)
        if not targetSpawnable then
            return nil
        end

        return self:getPersistentComponentID(
            targetSpawnable,
            isArea and securityData.SECURITY_AREA_CONTROLLER_CLASS or securityData.SECURITY_SYSTEM_CONTROLLER_CLASS,
            isArea and securityData.SECURITY_AREA_COMPONENT_ID or securityData.SECURITY_SYSTEM_COMPONENT_ID
        )
    end

    -- Value access -------------------------------------------------------------------------------

    ---@param targetSpawnable table
    ---@param componentID string
    ---@param path table
    ---@param fallback any
    ---@return any
    function device:readSecurityValue(targetSpawnable, componentID, path, fallback)
        local value = self:getComponentPathValue(targetSpawnable, componentID, path)

        if value == nil then
            return fallback
        end

        return value
    end

    ---Writes one network property. Tracked widgets already own the history step.
    ---@param targetSpawnable table
    ---@param componentID string
    ---@param path table
    ---@param value any
    ---@param writeOptions table?
    function device:writeSecurityValue(targetSpawnable, componentID, path, value, writeOptions)
        if not targetSpawnable or not componentID then
            return
        end

        self:updateComponentPathValue(targetSpawnable, componentID, path, value, writeOptions)
    end

    -- Network resolution -------------------------------------------------------------------------

    ---Areas a security system points at, in connection order.
    ---@param systemSpawnable table
    ---@return table[]
    function device:getSecurityAreaEntries(systemSpawnable)
        return self:getResolvedDeviceConnections(systemSpawnable, {
            className = securityData.SECURITY_AREA_CONTROLLER_CLASS,
            requireNodeRef = true
        })
    end

    ---Connections of a given class on a device, resolved to their targets.
    ---@param sourceSpawnable table
    ---@param className string
    ---@return table[]
    function device:getSecurityConnectionsOfClass(sourceSpawnable, className)
        return self:getResolvedDeviceConnections(sourceSpawnable, {
            className = className,
            requireNodeRef = true
        })
    end

    ---All security systems whose area connection points at this area.
    ---@return table[]
    function device:getOwningSecuritySystems()
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

                    if className == securityData.SECURITY_AREA_CONTROLLER_CLASS
                        and targetNodeRef ~= ""
                        and (targetNodeRef == ownNodeRef or utils.nodeRefStringToHashString(targetNodeRef) == ownHash) then
                        table.insert(entries, {
                            connection = connection,
                            connectionIndex = connectionIndex,
                            nodeRef = utils.sanitizeText(spawnable.nodeRef),
                            spawnable = spawnable,
                            element = ref
                        })

                        break
                    end
                end
            end
        end

        return entries
    end

    ---The whole network the popup renders, resolved from whichever end it was opened on.
    ---@return table
    function device:resolveSecurityNetwork()
        local openedOnArea = securityData.isSecurityArea(self.deviceClassName)

        local systemSpawnable = nil
        local systemElement = nil
        local owners = {}

        if openedOnArea then
            owners = self:getOwningSecuritySystems()
            local owner = owners[1]
            systemSpawnable = owner and owner.spawnable or nil
            systemElement = owner and owner.element or nil
        else
            systemSpawnable = self
            systemElement = self.object
        end

        local areas = systemSpawnable and self:getSecurityAreaEntries(systemSpawnable) or {}

        -- Keep an orphan area editable when the popup was opened from it.
        if openedOnArea then
            local listed = false

            for _, entry in ipairs(areas) do
                if entry.spawnable == self then
                    entry.isSelf = true
                    listed = true
                end
            end

            if not listed then
                table.insert(areas, 1, {
                    nodeRef = utils.sanitizeText(self.nodeRef),
                    spawnable = self,
                    element = self.object,
                    isSelf = true,
                    isOrphan = true
                })
            end
        end

        return {
            openedOnArea = openedOnArea,
            systemSpawnable = systemSpawnable,
            systemElement = systemElement,
            ownerCount = #owners,
            areas = areas,
            communities = systemSpawnable
                and self:getSecurityConnectionsOfClass(systemSpawnable, securityData.COMMUNITY_PROXY_CLASS)
                or {},
            slaves = systemSpawnable and self:getSecuritySlaveEntries(systemSpawnable) or {}
        }
    end

    ---Non-area, non-community connections driven by the system.
    ---@param systemSpawnable table
    ---@return table[]
    function device:getSecuritySlaveEntries(systemSpawnable)
        return self:getResolvedDeviceConnections(systemSpawnable, {
            excludeClasses = {
                [securityData.SECURITY_AREA_CONTROLLER_CLASS] = true,
                [securityData.COMMUNITY_PROXY_CLASS] = true
            },
            decorate = function (entry)
                local definition = securityData.getSlaveDefinitionByClass(entry.className)

                entry.definition = definition
                entry.label = definition and definition.label or entry.className
                entry.icon = securityData.getSlaveIcon(entry.className)
            end
        })
    end

    -- Shared rows ----------------------------------------------------------------------------------

    local function drawSecurityFieldLabel(icon, label, labelX)
        if icon then
            style.drawIconLabelRow(icon, label)
        else
            style.mutedText(label)
        end

        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
    end

    ---Appearance picker for a driven device; writes the spawnable's normal `app` field.
    ---@param targetSpawnable table
    ---@param targetElement table? Element the change is recorded against, for undo
    ---@param stateKey string Keeps this row's dropdown search apart from the other pickers
    ---@param labelX number
    function device:drawSecurityAppearanceRow(targetSpawnable, targetElement, stateKey, labelX)
        -- Only entity-backed spawnables expose appearances.
        if not targetSpawnable or type(targetSpawnable.apps) ~= "table" or not targetSpawnable.setAppearance then
            return
        end

        local apps = targetSpawnable.apps

        drawSecurityFieldLabel(nil, "Appearance", labelX)

        -- The list arrives asynchronously.
        if #apps == 0 then
            style.mutedText(targetSpawnable.appsLoaded and "(none)" or "Loading...")
            style.tooltip(targetSpawnable.appsLoaded
                and "This entity defines no appearances, so there is no body to choose."
                or "Reading the appearance list off this entity.")

            return
        end

        local uiState = self:getSecurityUIState()
        local searchKey = "app:" .. stateKey
        local currentApp = tostring(targetSpawnable.app or "")

        if currentApp == "" then
            currentApp = apps[1]
        end

        local greyOut = #apps <= 1
        style.pushGreyedOut(greyOut)

        local newApp, newSearch, appChanged = style.trackedSearchDropdown(
            "##securityDeviceAppearance",
            "Search appearance...",
            currentApp,
            uiState[searchKey] or "",
            apps,
            {
                element = targetElement or self.object,
                width = style.getRowFieldWidth({ IconGlyphs.SkipNext, IconGlyphs.Reload }),
                matchContentWidth = true,
                tooltip = "Body this device is built with: which mount, housing or shape the entity spawns as.\nNot a security setting -- it changes the mesh, not what the network does with it."
            }
        )
        uiState[searchKey] = newSearch

        if appChanged then
            -- The tracked dropdown already pushed history.
            targetSpawnable:setAppearance(newApp)
        end

        ImGui.SameLine()
        style.pushButtonNoBG(true)

        ImGui.BeginDisabled(greyOut)
        if ImGui.Button(IconGlyphs.SkipNext .. "##securityDeviceAppearanceCycle") and not greyOut then
            targetSpawnable:cycleAppearance()
        end
        ImGui.EndDisabled()
        style.tooltip("Select the next appearance. Wraps at the end of the list.")

        ImGui.SameLine()
        if ImGui.Button(IconGlyphs.Reload .. "##securityDeviceAppearanceReload") then
            targetSpawnable:reloadAppearances()
        end
        style.tooltip("Re-read the appearance list from the entity file, in case the file changed since it was cached.")

        style.pushButtonNoBG(false)
        style.popGreyedOut(greyOut)
    end

    ---Transient per-field UI state, keyed by stable strings.
    ---@return table
    function device:getSecurityUIState()
        self.securityUIState = self.securityUIState or {}

        return self.securityUIState
    end

    ---Stable identity for one graph box.
    ---@param kind string
    ---@param entry table?
    ---@param index number
    ---@return string
    local function getSecuritySelectionKey(kind, entry, index)
        local nodeRef = utils.sanitizeText(entry and entry.nodeRef or "")

        if nodeRef ~= "" then
            return kind .. ":" .. nodeRef
        end

        return kind .. ":index:" .. tostring(index)
    end

    ---Selected graph box. Defaults to the system.
    ---@return table `{ kind: string, key: string? }`
    function device:getSecuritySelection()
        self.securitySelection = self.securitySelection or { kind = "system" }

        return self.securitySelection
    end

    ---@param selection table? Nil falls back to the system, which always exists
    function device:setSecuritySelection(selection)
        self.securitySelection = selection or { kind = "system" }
    end

    ---NodeRef field plus its generate button, for any device in the network.
    ---@param targetSpawnable table
    ---@param targetElement table?
    ---@param id string
    ---@param tooltip string
    function device:drawSecurityNodeRefRow(targetSpawnable, targetElement, id, tooltip)
        local canGenerate = targetElement ~= nil and targetElement.parent ~= nil

        local edited, _, finished = style.trackedTextField(
            targetElement or self.object,
            "##securityNodeRef" .. id,
            utils.sanitizeText(targetSpawnable.nodeRef),
            "NodeRef...",
            style.getRowFieldWidth({ IconGlyphs.ReloadAlert })
        )
        style.tooltip(tooltip)

        if finished then
            self:applySecurityNodeRef(targetSpawnable, targetElement, edited)
        end

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        ImGui.BeginDisabled(not canGenerate)
        if ImGui.Button(IconGlyphs.ReloadAlert .. "##securityNodeRefGenerate" .. id) and canGenerate then
            self:applySecurityNodeRef(targetSpawnable, targetElement, registry.generate(targetElement))
        end
        ImGui.EndDisabled()
        style.pushButtonNoBG(false)
        style.tooltip("Generate a unique NodeRef for this device.")
    end

    ---Renames a node and every connection row that points at it.
    ---@param targetSpawnable table
    ---@param targetElement table?
    ---@param newNodeRef string
    function device:applySecurityNodeRef(targetSpawnable, targetElement, newNodeRef)
        self:updateNodeRefAndReferrers(targetSpawnable, targetElement, newNodeRef)
    end

    ---Gives a network device a NodeRef and `.psrep` entry.
    ---@param targetSpawnable table
    ---@param targetElement table?
    ---@return boolean
    function device:ensureSecurityPersistent(targetSpawnable, targetElement)
        if not targetSpawnable or targetSpawnable.persistent then
            return true
        end

        local canGenerate = targetElement ~= nil and targetElement.parent ~= nil
        local needsNodeRef = utils.sanitizeText(targetSpawnable.nodeRef) == ""

        if needsNodeRef and not canGenerate then
            return false
        end

        history.addAction(history.getElementChange(targetElement or self.object))

        if needsNodeRef then
            local generated = utils.sanitizeText(registry.generate(targetElement))
            if generated == "" then
                return false
            end

            targetSpawnable.nodeRef = generated
            self:refreshNodeRefCaches()
        end

        targetSpawnable.persistent = true

        return true
    end

    ---Outline picker plus a live readout of the bound marker group.
    ---@param areaSpawnable table
    ---@param areaElement table?
    ---@param labelX number
    function device:drawSecurityOutlineRow(areaSpawnable, areaElement, labelX)
        if not areaSpawnable.loadOutlinePaths then
            return
        end

        local paths = areaSpawnable:loadOutlinePaths()
        table.insert(paths, 1, "None")

        local current = areaSpawnable.outlinePath
        if current == nil or current == "" then
            current = "None"
        end

        drawSecurityFieldLabel(IconGlyphs.VectorPolyline, "Outline", labelX)

        local index = math.max(1, utils.indexValue(paths, current))
        local newIndex, outlineChanged = style.trackedCombo(
            areaElement or self.object,
            "##securityOutlinePath",
            index - 1,
            paths,
            style.getRowFieldWidth({}, 200)
        )
        style.tooltip("Group of outline markers describing this area's volume.\nMust sit under the same root group as the device. The trigger volume follows the markers.")

        if outlineChanged then
            local picked = paths[newIndex + 1] or "None"
            areaSpawnable.outlinePath = picked == "None" and "" or picked

            if areaElement and element.bumpWireframeEpoch then
                element.bumpWireframeEpoch(areaElement)
            end

            outlineConsumer.invalidate()

            if areaSpawnable.onOutlineChanged then
                areaSpawnable:onOutlineChanged()
            end
        end

        if #paths <= 1 then
            ImGui.SetCursorPosX(labelX)
            style.mutedText(IconGlyphs.InformationOutline .. " No outline groups here. Add at least 3 Outline Markers to a group.")
            style.tooltip("Spawn Outline Markers (Area -> Outline Marker) into a group under the same root as this device.")

            return
        end

        local bound = areaSpawnable.outlinePath ~= nil
            and areaSpawnable.outlinePath ~= ""
            and areaSpawnable.outlinePath ~= "None"

        if not bound then
            ImGui.SetCursorPosX(labelX)
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " Not bound. The area keeps the entity's own 8x8 m box.",
                style.warnColor
            )

            return
        end

        local points, height = outlineConsumer.getLocalPoints(areaSpawnable)

        ImGui.SetCursorPosX(labelX)

        if #points < outlineConsumer.MIN_MARKERS then
            style.styledTextWrapped(
                string.format(
                    "%s Only %d marker%s. An outline needs at least %d.",
                    IconGlyphs.AlertOutline,
                    #points,
                    #points == 1 and "" or "s",
                    outlineConsumer.MIN_MARKERS
                ),
                style.warnColor
            )

            return
        end

        style.mutedText(string.format(
            "%s %d markers  |  %.2f m high",
            IconGlyphs.CheckCircleOutline,
            #points,
            height
        ))
        style.tooltip("Written to the area component's outline on every marker move.")

        if height <= 0 then
            ImGui.SetCursorPosX(labelX)
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " Height is 0, so the volume is flat and nothing can be inside it.",
                style.warnColor
            )
        end
    end

    -- Network graph ----------------------------------------------------------------------------------

    ---Whether this network can be edited.
    ---@param network table
    ---@return boolean
    local function canEditNetwork(network)
        return network.systemSpawnable ~= nil
            and network.systemElement ~= nil
            and network.systemElement.parent ~= nil
            and not network.systemElement:isLocked()
    end

    local GRAPH_NODE_HEIGHT = 34
    local GRAPH_ROW_GAP = 26
    local GRAPH_NODE_GAP = 8
    local GRAPH_PADDING = 10
    local GRAPH_NODE_PADDING_X = 9
    local GRAPH_MIN_NODE_WIDTH = 80
    local GRAPH_MAX_NODE_WIDTH = 170
    local GRAPH_SUBTITLE_RATIO = 0.82
    ---Left gutter for multi-row link routing.
    local GRAPH_TRUNK_GUTTER = 22
    ---Gap between the system and community column.
    local GRAPH_COLUMN_GAP = 46
    ---Max graph height before scrolling.
    local GRAPH_MAX_HEIGHT = 320
    ---Square add button size.
    local GRAPH_ADD_SIZE = 26

    local graphNodeOptions = {
        paddingX = GRAPH_NODE_PADDING_X,
        minWidth = GRAPH_MIN_NODE_WIDTH,
        maxWidth = GRAPH_MAX_NODE_WIDTH,
        subtitleRatio = GRAPH_SUBTITLE_RATIO
    }

    ---Network graph: areas above, communities right, driven devices below.
    ---@param network table
    function device:drawSecurityNetworkGraph(network)
        if not network.systemSpawnable then
            return
        end

        local nodeHeight = GRAPH_NODE_HEIGHT * style.viewSize
        local rowGap = GRAPH_ROW_GAP * style.viewSize
        local nodeGap = GRAPH_NODE_GAP * style.viewSize
        local padding = GRAPH_PADDING * style.viewSize
        local gutter = GRAPH_TRUNK_GUTTER * style.viewSize
        local columnGap = GRAPH_COLUMN_GAP * style.viewSize
        local addSize = GRAPH_ADD_SIZE * style.viewSize

        local systemSpawnable = network.systemSpawnable
        local selection = self:getSecuritySelection()
        local editable = canEditNetwork(network)

        local addSlavePopupId = "##securityGraphAddSlave"
        local canvasPopupId = "##securityGraphCanvasMenu"

        ---Selects the node that was just spawned.
        ---@param kind string
        ---@param element table? Whatever the `add` call returned
        local function selectCreated(kind, element)
            local newSpawnable = element and element.spawnable or nil
            local nodeRef = newSpawnable and utils.sanitizeText(newSpawnable.nodeRef) or ""

            -- No NodeRef means no stable key; fall back to the system.
            if nodeRef == "" then
                self:setSecuritySelection(nil)

                return
            end

            self:setSecuritySelection({
                kind = kind,
                key = getSecuritySelectionKey(kind, { nodeRef = nodeRef }, 0)
            })
        end

        ---Clears selection only when the selected node was removed.
        ---@param nodeSelect table? The removed box's `select` descriptor
        local function clearSelectionIfSelected(nodeSelect)
            local current = self:getSecuritySelection()

            if nodeSelect and current.kind == nodeSelect.kind and current.key == nodeSelect.key then
                self:setSecuritySelection(nil)
            end
        end

        -- Shared creation paths for menus and `+` boxes.
        local function addArea()
            selectCreated("area", systemSpawnable:addSecurityArea())
        end

        local function addCommunity()
            selectCreated("community", systemSpawnable:addSecurityCommunity())
        end

        ---Tooltip text for a spawnable driven-device entry.
        ---@param definition table
        ---@return string
        local function slaveTooltip(definition)
            return string.format(
                "%s\nSpawned wired to this system, with its own settings in the panel below.",
                definition.class
            )
        end

        local function drawSlaveMenuItems()
            for _, definition in ipairs(securityData.SLAVE_CLASSES) do
                if definition.spawnData then
                    local icon = securityData.getSlaveIcon(definition.class)
                    local label = string.format("%s  %s", icon, definition.label)

                    -- Variants are alternate bodies for the same controller class.
                    if definition.variants then
                        if ImGui.BeginMenu(label, true) then
                            for _, variant in ipairs(definition.variants) do
                                if ImGui.MenuItem(string.format("%s  %s", icon, variant.label)) then
                                    selectCreated("device", systemSpawnable:addSecuritySlave(definition.key, variant.spawnData))
                                    ImGui.CloseCurrentPopup()
                                end
                                style.tooltip(slaveTooltip(definition))
                            end
                            ImGui.EndMenu()
                        end
                    else
                        if ImGui.MenuItem(label) then
                            selectCreated("device", systemSpawnable:addSecuritySlave(definition.key))
                            ImGui.CloseCurrentPopup()
                        end
                        style.tooltip(slaveTooltip(definition))
                    end
                end
            end
        end

        -- Match the disabled-control pattern used elsewhere in this codebase.
        local function drawCreationMenu()
            ImGui.BeginDisabled(not editable)

            if ImGui.MenuItem(securityData.AREA_ICON .. "  Add Area") and editable then
                addArea()
                ImGui.CloseCurrentPopup()
            end
            style.tooltip(ADD_AREA_TOOLTIP)

            if ImGui.MenuItem(securityData.COMMUNITY_ICON .. "  Add Community") and editable then
                addCommunity()
                ImGui.CloseCurrentPopup()
            end
            style.tooltip(ADD_COMMUNITY_TOOLTIP)

            ImGui.EndDisabled()

            if ImGui.BeginMenu(IconGlyphs.Cctv .. "  Add Device", editable) then
                drawSlaveMenuItems()
                ImGui.EndMenu()
            end

            if not editable then
                style.tooltip("Requires the system to sit inside a group and be unlocked.")
            end
        end

        ---Context menu shared by every child box: unwire it, or take the node out with it.
        ---@param entry table
        ---@param label string
        ---@param nodeSelect table The box's own selection descriptor, so removal can tell whether
        ---the panel below is showing this node or another one
        ---@return function
        local function makeNodeContextMenu(entry, label, nodeSelect)
            return function ()
                if not editable then
                    return
                end

                if ImGui.MenuItem(IconGlyphs.LanDisconnect .. "  Unlink") then
                    systemSpawnable:removeSecurityNode(entry, false)
                    clearSelectionIfSelected(nodeSelect)
                    ImGui.CloseCurrentPopup()
                end
                style.tooltip(string.format("Remove the connection. The %s itself is left in the project.", label))

                -- Do not delete the device the popup is bound to mid-frame.
                local canDelete = entry.spawnable ~= nil and entry.spawnable ~= self

                ImGui.BeginDisabled(not canDelete)
                if ImGui.MenuItem(IconGlyphs.DeleteOutline .. "  Delete") and canDelete then
                    systemSpawnable:removeSecurityNode(entry, true)
                    clearSelectionIfSelected(nodeSelect)
                    ImGui.CloseCurrentPopup()
                end
                ImGui.EndDisabled()
                style.tooltip(entry.spawnable == self
                    and "This is the node the popup was opened on. Remove it from the hierarchy instead."
                    or string.format("Remove the connection and delete the %s node.", label))

                ImGui.Separator()
                drawCreationMenu()
            end
        end

        -- The three graph bands in connection order.
        local areaItems = {}
        local communityItems = {}
        local deviceItems = {}

        for index, entry in ipairs(network.areas) do
            local areaType = securityData.DEFAULT_AREA_TYPE
            local componentID = entry.spawnable and self:getSecurityControllerComponentID(entry.spawnable, true) or nil

            if componentID then
                areaType = tostring(self:readSecurityValue(
                    entry.spawnable,
                    componentID,
                    securityData.AREA_TYPE_PATH,
                    securityData.DEFAULT_AREA_TYPE
                ))
            end

            local nodeSelect = { kind = "area", key = getSecuritySelectionKey("area", entry, index) }

            table.insert(areaItems, {
                icon = securityData.AREA_ICON,
                title = entry.element and tostring(entry.element.name or "") or entry.nodeRef,
                subtitle = securityData.getAreaTypeLabel(areaType),
                color = securityData.getAreaTypeColor(areaType),
                tooltip = entry.nodeRef .. "\nClick to edit this area, right click for its menu.",
                select = nodeSelect,
                contextMenu = makeNodeContextMenu(entry, "area", nodeSelect),
                orphan = entry.spawnable == nil
            })
        end

        for index, entry in ipairs(network.communities) do
            local nodeSelect = { kind = "community", key = getSecuritySelectionKey("community", entry, index) }

            table.insert(communityItems, {
                icon = securityData.COMMUNITY_ICON,
                title = entry.element and tostring(entry.element.name or "") or entry.nodeRef,
                subtitle = "Community",
                color = securityData.getChainColor("community"),
                tooltip = entry.nodeRef .. "\nClick to edit this link, right click for its menu.",
                select = nodeSelect,
                contextMenu = makeNodeContextMenu(entry, "community", nodeSelect),
                orphan = entry.spawnable == nil
            })
        end

        for index, entry in ipairs(network.slaves) do
            local nodeSelect = { kind = "device", key = getSecuritySelectionKey("device", entry, index) }

            table.insert(deviceItems, {
                icon = entry.icon or IconGlyphs.Cctv,
                title = entry.element and tostring(entry.element.name or "") or entry.nodeRef,
                subtitle = entry.label,
                color = securityData.getChainColor("device"),
                tooltip = entry.className .. "\n" .. entry.nodeRef .. "\nClick to edit this device, right click for its menu.",
                select = nodeSelect,
                contextMenu = makeNodeContextMenu(entry, "device", nodeSelect),
                orphan = entry.spawnable == nil
            })
        end

        local systemItem = {
            icon = securityData.SYSTEM_ICON,
            title = network.systemElement and tostring(network.systemElement.name or "") or "Security System",
            subtitle = redValue.readTweakDBID(
                self:readSecurityValue(
                    systemSpawnable,
                    self:getSecurityControllerComponentID(systemSpawnable, false) or "",
                    securityData.ATTITUDE_GROUP_PATH,
                    nil
                )
            ):gsub("^Attitudes%.Group_", ""),
            color = securityData.getChainColor("system"),
            tooltip = "This security system.\nClick to edit it, right click to add to it.",
            select = { kind = "system" },
            contextMenu = drawCreationMenu
        }

        if systemItem.subtitle == "" then
            systemItem.subtitle = "no faction"
        end

        systemItem.width = graph.measureNode(systemItem, graphNodeOptions)

        -- Wrap long bands while keeping node boxes at natural size.
        local wrapWidth = math.max(
            GRAPH_MAX_NODE_WIDTH * style.viewSize * 2,
            ImGui.GetContentRegionAvail() - 2 * padding - gutter
        )

        ---Builds wrapped rows; empty bands still get a note and add box.
        ---@param items table[]
        ---@param emptyNote string
        ---@return table[] rows Each `{ width, items, note? }`
        local function buildRows(items, emptyNote)
            local rows = {}
            local currentRow = { width = 0, items = {} }

            for _, item in ipairs(items) do
                item.width = graph.measureNode(item, graphNodeOptions)

                local extra = (#currentRow.items > 0 and nodeGap or 0) + item.width

                if #currentRow.items > 0 and currentRow.width + extra > wrapWidth then
                    table.insert(rows, currentRow)
                    currentRow = { width = 0, items = {} }
                    extra = item.width
                end

                currentRow.width = currentRow.width + extra
                table.insert(currentRow.items, item)
            end

            if #currentRow.items > 0 then
                table.insert(rows, currentRow)
            end

            if #rows == 0 then
                table.insert(rows, {
                    width = ImGui.CalcTextSize(emptyNote) * GRAPH_SUBTITLE_RATIO,
                    items = {},
                    note = emptyNote
                })
            end

            -- The `+` goes on the row nearest the system.
            rows[#rows].hasAdd = true

            return rows
        end

        local areaRows = buildRows(areaItems, "No areas. This system drives nothing.")
        local deviceRows = buildRows(deviceItems, "No cameras, turrets, alarms or detectors.")

        -- Use one width for the whole community column.
        local communityWidth = 0
        for _, item in ipairs(communityItems) do
            communityWidth = math.max(communityWidth, graph.measureNode(item, graphNodeOptions))
        end
        for _, item in ipairs(communityItems) do
            item.width = communityWidth
        end

        -- Empty community columns need a note beside the add box.
        local communityNote = #communityItems == 0
            and "No communities. Nothing on this network alerts NPCs."
            or nil
        local communityNoteWidth = communityNote
            and ImGui.CalcTextSize(communityNote) * GRAPH_SUBTITLE_RATIO
            or 0

        ---@param rows table[]
        ---@return number
        local function bandHeight(rows)
            return #rows * nodeHeight + (#rows - 1) * rowGap
        end

        local areasHeight = bandHeight(areaRows)
        local devicesHeight = bandHeight(deviceRows)
        local communityHeight = #communityItems * (nodeHeight + nodeGap) + addSize
        local systemBandHeight = math.max(nodeHeight, communityHeight)

        local contentHeight = areasHeight
            + rowGap
            + systemBandHeight
            + rowGap
            + devicesHeight
            + 2 * padding

        -- Center the system over child rows so link buses meet it cleanly.
        local childBandWidth = 0
        for _, row in ipairs(areaRows) do
            childBandWidth = math.max(childBandWidth, row.width)
        end
        for _, row in ipairs(deviceRows) do
            childBandWidth = math.max(childBandWidth, row.width)
        end

        local centerOffset = math.max(childBandWidth, systemItem.width) / 2
        local rightExtent = centerOffset + systemItem.width / 2

        for _, rows in ipairs({ areaRows, deviceRows }) do
            for _, row in ipairs(rows) do
                local rowExtent = centerOffset + row.width / 2
                    + (row.hasAdd and (nodeGap + addSize) or 0)

                rightExtent = math.max(rightExtent, rowExtent)
            end
        end

        rightExtent = math.max(
            rightExtent,
            centerOffset + systemItem.width / 2 + columnGap + math.max(
                communityWidth,
                addSize + (communityNote and (nodeGap + communityNoteWidth) or 0)
            )
        )

        local contentWidth = gutter + rightExtent + 2 * padding

        -- Reserve scrollbar space up front to avoid frame-to-frame flicker.
        local styleData = ImGui.GetStyle()
        local availableWidth = ImGui.GetContentRegionAvail()
        local maxHeight = GRAPH_MAX_HEIGHT * style.viewSize
        local graphHeight = contentHeight + 2 * styleData.WindowPadding.y + 2 * style.viewSize
        local needsVerticalScrollbar = graphHeight > maxHeight
        local innerWidth = availableWidth
            - 2 * styleData.WindowPadding.x
            - 2 * style.viewSize
            - (needsVerticalScrollbar and styleData.ScrollbarSize or 0)
        local needsHorizontalScrollbar = contentWidth > innerWidth + style.viewSize

        if needsHorizontalScrollbar then
            graphHeight = graphHeight + styleData.ScrollbarSize
        end
        graphHeight = math.min(graphHeight, maxHeight)

        local graphFlags = needsHorizontalScrollbar and ImGuiWindowFlags.HorizontalScrollbar or 0

        -- `EndChild` is owed whether or not `BeginChild` returned true.
        local graphVisible = ImGui.BeginChild("##securityNetworkGraph", 0, graphHeight, true, graphFlags)

        if graphVisible then
            local drawList = ImGui.GetWindowDrawList()
            local startX, startY = ImGui.GetCursorPosX(), ImGui.GetCursorPosY()
            local visibleWidth, visibleHeight = ImGui.GetContentRegionAvail()
            local layoutWidth = math.max(visibleWidth, contentWidth)

            -- Reserve the child scroll extent for absolutely positioned graph items.
            ImGui.SetCursorPos(startX + math.max(1, layoutWidth) - 1, startY + math.max(1, contentHeight) - 1)
            ImGui.Dummy(1, 1)
            ImGui.SetCursorPos(startX, startY)

            local windowX, windowY = ImGui.GetWindowPos()
            local scrollX = (ImGui.GetScrollX and ImGui.GetScrollX()) or 0
            local scrollY = (ImGui.GetScrollY and ImGui.GetScrollY()) or 0
            local originX = windowX + startX - scrollX + padding
            local originY = windowY + startY - scrollY + padding

            -- Keep the gutter clear for multi-row link routing.
            local contentX = originX + gutter
            local trunkX = originX + gutter / 2
            local centerX = contentX + centerOffset

            local systemBandTop = originY + areasHeight + rowGap
            local systemX = centerX - systemItem.width / 2
            local systemY = systemBandTop + (systemBandHeight - nodeHeight) / 2
            local systemCenterX = centerX
            local devicesTop = systemBandTop + systemBandHeight + rowGap
            local communityX = systemX + systemItem.width + columnGap
            local communityTop = systemBandTop + (systemBandHeight - communityHeight) / 2

            ---@param rows table[]
            ---@param bandTop number
            local function placeRows(rows, bandTop)
                for rowIndex, row in ipairs(rows) do
                    local rowTop = bandTop + (rowIndex - 1) * (nodeHeight + rowGap)
                    local cursorX = centerX - row.width / 2

                    row.top = rowTop
                    row.left = cursorX

                    for _, item in ipairs(row.items) do
                        item.x, item.y = cursorX, rowTop
                        item.height = nodeHeight
                        cursorX = cursorX + item.width + nodeGap
                    end
                end
            end

            placeRows(areaRows, originY)
            placeRows(deviceRows, devicesTop)

            systemItem.x, systemItem.y = systemX, systemY
            systemItem.height = nodeHeight

            for index, item in ipairs(communityItems) do
                item.x = communityX
                item.y = communityTop + (index - 1) * (nodeHeight + nodeGap)
                item.height = nodeHeight
            end

            -- Draw links first so nodes cover wire ends.
            local busColor = securityData.getChainColor("system")

            ---Draws one band as row buses stepping outward from the system.
            ---@param rows table[] Ordered outward from the system, empty rows already dropped
            ---@param systemEdgeY number Edge of the system box the first bus hangs off
            ---@param busYOf fun(row: table): number Y of a row's bus, in the gap facing the system
            ---@param itemEdgeYOf fun(item: table): number Edge of a box its stub lands on
            local function drawBand(rows, systemEdgeY, busYOf, itemEdgeYOf)
                local previousLeft, previousBusY = nil, nil

                for rowIndex, row in ipairs(rows) do
                    local busY = busYOf(row)
                    local first = row.items[1]
                    local last = row.items[#row.items]
                    local left = first.x + first.width / 2
                    local right = last.x + last.width / 2

                    if rowIndex == 1 then
                        -- Nearest row reaches the system directly.
                        left = math.min(left, systemCenterX)
                        right = math.max(right, systemCenterX)

                        graph.drawLine(drawList, systemCenterX, systemEdgeY, systemCenterX, busY, busColor)
                    else
                        -- Further rows step around the row in front through the gutter.
                        local corridorX = math.max(trunkX, rows[rowIndex - 1].items[1].x - nodeGap)

                        left = math.min(left, corridorX)

                        graph.drawLine(drawList, corridorX, previousBusY, previousLeft, previousBusY, busColor)
                        graph.drawLine(drawList, corridorX, previousBusY, corridorX, busY, busColor)
                    end

                    graph.drawLine(drawList, left, busY, right, busY, busColor)

                    -- Only stubs use node colours; shared buses use the system colour.
                    for _, item in ipairs(row.items) do
                        local itemCenterX = item.x + item.width / 2

                        graph.drawLine(drawList, itemCenterX, busY, itemCenterX, itemEdgeYOf(item), item.color)
                    end

                    previousLeft, previousBusY = left, busY
                end
            end

            ---@param rows table[]
            ---@param nearestFirst boolean
            ---@return table[]
            local function wiredRows(rows, nearestFirst)
                local wired = {}

                for rowIndex = 1, #rows do
                    local row = rows[nearestFirst and (#rows - rowIndex + 1) or rowIndex]

                    if #row.items > 0 then
                        table.insert(wired, row)
                    end
                end

                return wired
            end

            -- Areas stack upward, so routing starts from the last row.
            local wiredAreaRows = wiredRows(areaRows, true)
            if #wiredAreaRows > 0 then
                drawBand(
                    wiredAreaRows,
                    systemY,
                    function (row) return row.top + nodeHeight + rowGap / 2 end,
                    function (item) return item.y + nodeHeight end
                )
            end

            local wiredDeviceRows = wiredRows(deviceRows, false)
            if #wiredDeviceRows > 0 then
                drawBand(
                    wiredDeviceRows,
                    systemY + nodeHeight,
                    function (row) return row.top - rowGap / 2 end,
                    function (item) return item.y end
                )
            end

            -- Community nodes hang from a vertical bus beside the system.
            if #communityItems > 0 then
                local systemRight = systemX + systemItem.width
                local systemMidY = systemY + nodeHeight / 2
                local busX = systemRight + columnGap / 2
                local busTop, busBottom = systemMidY, systemMidY

                for _, item in ipairs(communityItems) do
                    local itemMidY = item.y + nodeHeight / 2

                    busTop = math.min(busTop, itemMidY)
                    busBottom = math.max(busBottom, itemMidY)
                end

                graph.drawLine(drawList, systemRight, systemMidY, busX, systemMidY, busColor)
                graph.drawLine(drawList, busX, busTop, busX, busBottom, busColor)

                for _, item in ipairs(communityItems) do
                    local itemMidY = item.y + nodeHeight / 2

                    graph.drawLine(drawList, busX, itemMidY, item.x, itemMidY, item.color)
                end
            end

            -- Hovered boxes suppress the blank-canvas context menu.
            local itemHovered = false

            ---@param item table
            ---@param id string
            local function drawItem(item, id)
                item.id = id
                item.selected = item.select ~= nil
                    and selection.kind == item.select.kind
                    and selection.key == item.select.key

                if item.contextMenu then
                    local contextMenu = item.contextMenu
                    item.drawContextMenu = function ()
                        if ImGui.BeginPopupContextItem(id .. "Context", ImGuiPopupFlags.MouseButtonRight) then
                            contextMenu()
                            ImGui.EndPopup()
                        end
                    end
                end

                local clicked, hovered = graph.drawNode(drawList, item, graphNodeOptions)

                if hovered then
                    itemHovered = true
                end

                if clicked and item.select then
                    self:setSecuritySelection(item.select)
                end
            end

            drawItem(systemItem, "##securityGraphSystem")

            ---@param rows table[]
            ---@param idPrefix string
            local function drawRows(rows, idPrefix)
                for rowIndex, row in ipairs(rows) do
                    for itemIndex, item in ipairs(row.items) do
                        drawItem(item, string.format("##%s%d_%d", idPrefix, rowIndex, itemIndex))
                    end
                end
            end

            drawRows(areaRows, "securityGraphArea")
            drawRows(deviceRows, "securityGraphDevice")

            for index, item in ipairs(communityItems) do
                drawItem(item, string.format("##securityGraphCommunity%d", index))
            end

            -- Add boxes float after row content without shifting nodes.
            ---@param options table `{ id, x, y, tooltip, color, onClick }`
            local function drawAdd(options)
                local clicked, hovered = graph.drawAddButton(drawList, {
                    id = options.id,
                    x = options.x,
                    y = options.y,
                    size = addSize,
                    color = options.color,
                    disabled = not editable,
                    tooltip = editable and options.tooltip
                        or "Requires the system to sit inside a group and be unlocked."
                })

                if hovered then
                    itemHovered = true
                end

                if clicked then
                    options.onClick()
                end
            end

            local areaAddRow = areaRows[#areaRows]
            drawAdd({
                id = "##securityGraphAddArea",
                x = areaAddRow.left + areaAddRow.width + (areaAddRow.width > 0 and nodeGap or 0),
                y = areaAddRow.top + (nodeHeight - addSize) / 2,
                color = securityData.getAreaTypeColor(securityData.DEFAULT_AREA_TYPE),
                tooltip = ADD_AREA_TOOLTIP,
                onClick = addArea
            })

            local deviceAddRow = deviceRows[#deviceRows]
            drawAdd({
                id = "##securityGraphAddDevice",
                x = deviceAddRow.left + deviceAddRow.width + (deviceAddRow.width > 0 and nodeGap or 0),
                y = deviceAddRow.top + (nodeHeight - addSize) / 2,
                color = securityData.getChainColor("device"),
                tooltip = ADD_DEVICE_TOOLTIP,
                onClick = function () ImGui.OpenPopup(addSlavePopupId) end
            })

            local communityAddY = communityTop + communityHeight - addSize

            drawAdd({
                id = "##securityGraphAddCommunity",
                x = communityX,
                y = communityAddY,
                color = securityData.getChainColor("community"),
                tooltip = ADD_COMMUNITY_TOOLTIP,
                onClick = addCommunity
            })

            if communityNote then
                local noteSize = ImGui.GetFontSize() * GRAPH_SUBTITLE_RATIO

                ImGui.ImDrawListAddText(
                    drawList,
                    noteSize,
                    communityX + addSize + nodeGap,
                    communityAddY + (addSize - noteSize) / 2,
                    style.extraMutedColor,
                    communityNote
                )
            end

            ---@param row table
            local function drawRowNote(row)
                if not row.note then
                    return
                end

                local fontSize = ImGui.GetFontSize() * GRAPH_SUBTITLE_RATIO

                ImGui.ImDrawListAddText(
                    drawList,
                    fontSize,
                    row.left,
                    row.top + (nodeHeight - fontSize) / 2,
                    style.extraMutedColor,
                    row.note
                )
            end

            drawRowNote(areaRows[#areaRows])
            drawRowNote(deviceRows[#deviceRows])

            -- Right click on blank graph space opens the creation menu.
            local mouseX, mouseY = 0, 0
            if ImGui.GetMousePos then
                mouseX, mouseY = ImGui.GetMousePos()
            end

            local overGraph = ImGui.IsWindowHovered()
                and mouseX >= windowX + startX
                and mouseX <= windowX + startX + visibleWidth
                and mouseY >= windowY + startY
                and mouseY <= windowY + startY + visibleHeight

            if overGraph
                and not itemHovered
                and ImGui.IsMouseReleased
                and ImGui.IsMouseReleased(ImGuiMouseButton.Right) then
                ImGui.OpenPopup(canvasPopupId)
            end

            if ImGui.BeginPopup(canvasPopupId) then
                drawCreationMenu()
                ImGui.EndPopup()
            end

            if ImGui.BeginPopup(addSlavePopupId) then
                drawSlaveMenuItems()
                ImGui.EndPopup()
            end
        end

        ImGui.EndChild()
    end

    -- Wiring ------------------------------------------------------------------------------------

    ---Pickers for linking existing community or device nodes.
    ---@param network table
    function device:drawSecurityLinkExistingRows(network)
        if not canEditNetwork(network) then
            return
        end
        style.sectionHeaderStart("Add existing node to network")

        -- Hide already-wired refs so a pick always changes something.
        local linked = {}
        for _, entry in ipairs(network.communities) do
            linked[utils.sanitizeText(entry.nodeRef)] = true
        end
        for _, entry in ipairs(network.slaves) do
            linked[utils.sanitizeText(entry.nodeRef)] = true
        end

        local labelX = utils.getTextMaxWidth({ "Community", "Device" }) + ImGui.CalcTextSize(IconGlyphs.Square) + 4 * ImGui.GetStyle().ItemSpacing.x

        drawSecurityFieldLabel(securityData.COMMUNITY_ICON, "Community", labelX)
        self:drawSecurityLinkExisting(network, securityData.COMMUNITY_PROXY_CLASS, "Link Community##securityLinkCommunity", {
            modulePath = securityData.COMMUNITY_MODULE_PATH,
            filter = function (_, ref)
                return not linked[utils.sanitizeText(ref)]
            end,
            hint = "Link existing community...",
            empty = "No community areas in this project. Spawn one from the graph, or type a NodeRef from another sector.",
            tooltip = "Connect a community area that already exists in this project.\nOnly community nodes are listed -- a CommunityProxyPS row pointed at anything else does nothing."
        })

        drawSecurityFieldLabel(IconGlyphs.Cctv, "Device", labelX)
        self:drawSecurityLinkExisting(network, nil, "Link Device##securityLinkSlave", {
            filter = function (target, ref)
                if linked[utils.sanitizeText(ref)] then
                    return false
                end

                local targetClass = utils.sanitizeText(target.deviceClassName)

                -- Areas and communities have their own graph bands and connection classes.
                return targetClass ~= ""
                    and not securityData.supportsSecuritySetup(targetClass)
                    and targetClass ~= securityData.COMMUNITY_PROXY_CLASS
            end,
            resolveClassName = function (ref)
                return network.systemSpawnable:resolveConnectionClassName(ref)
            end,
            hint = "Link existing device...",
            empty = "No unlinked devices in this project. Spawn one from the graph.",
            tooltip = "Wire a device that already exists in this project into this network.\nThe connection is stored under the device's own controller class, read off the node,\nso only nodes this project can resolve are offered."
        })
        style.sectionHeaderEnd()
    end
    ---Links an existing node, optionally resolving the connection class from the picked target.
    ---@param network table
    ---@param className string? Connection class to write, or nil to resolve it from the pick
    ---@param label string
    ---@param options table? `{ modulePath, filter, resolveClassName, hint, empty, tooltip }`
    function device:drawSecurityLinkExisting(network, className, label, options)
        local systemSpawnable = network.systemSpawnable
        if not systemSpawnable then
            return
        end

        options = options or {}

        local uiState = self:getSecurityUIState()
        local key = "link:" .. (className or label)
        local searchValue = uiState[key] or ""

        local picked, finished = registry.drawNodeRefSelector(210, searchValue, systemSpawnable.object or self.object, false, {
            id = "##" .. label,
            searchId = "##" .. label .. "Search",
            listId = "##" .. label .. "List",
            modulePath = options.modulePath,
            filter = options.filter,
            hint = options.hint or "Link existing node...",
            allowCustom = className ~= nil,
            listHeight = 200,
            emptyListText = options.empty,
            tooltip = options.tooltip or "Connect a node that already exists in this project."
        })
        uiState[key] = picked

        if finished and utils.sanitizeText(picked) ~= "" then
            local connectionClass = className
                or (options.resolveClassName and options.resolveClassName(picked))
                or ""

            if utils.sanitizeText(connectionClass) ~= "" then
                history.addAction(history.getElementChange(network.systemElement or self.object))
                systemSpawnable:addSecurityConnection(connectionClass, picked)
            end

            uiState[key] = ""
        end
    end

    -- Schedule -------------------------------------------------------------------------------------

    local SCHEDULE_STRIP_HEIGHT = 13
    local SCHEDULE_TICK_STEP = 3
    local SCHEDULE_TICK_RATIO = 0.78

    ---One day of area types as a 24-segment bar.
    ---@param timeline string[] 24 type names, index 1 = 00:00
    ---@param note string Closes the hover tooltip, saying which day this strip is
    local function drawScheduleStrip(timeline, note)
        local height = SCHEDULE_STRIP_HEIGHT * style.viewSize
        local tickSize = ImGui.GetFontSize() * SCHEDULE_TICK_RATIO
        local availableX = ImGui.GetContentRegionAvail()
        local width = math.max(180 * style.viewSize, availableX - 4 * style.viewSize)
        local segment = width / securityData.HOURS_PER_DAY

        local startX, startY = ImGui.GetCursorPosX(), ImGui.GetCursorPosY()
        local originX, originY = ImGui.GetCursorScreenPos()
        local drawList = ImGui.GetWindowDrawList()

        for hour = 0, securityData.HOURS_PER_DAY - 1 do
            local left = originX + hour * segment
            -- Overdraw by one pixel to hide rounding gaps between segments.
            local fill = 0xCC000000 + (securityData.getAreaTypeColor(timeline[hour + 1]) % 0x1000000)

            ImGui.ImDrawListAddRectFilled(drawList, left, originY, left + segment + 1, originY + height, fill)
        end

        for hour = SCHEDULE_TICK_STEP, securityData.HOURS_PER_DAY - 1, SCHEDULE_TICK_STEP do
            local tickX = originX + hour * segment

            ImGui.ImDrawListAddLine(drawList, tickX, originY, tickX, originY + height, 0x55000000, 1 * style.viewSize)
            ImGui.ImDrawListAddText(
                drawList,
                tickSize,
                tickX + 2 * style.viewSize,
                originY + height,
                style.extraMutedColor,
                string.format("%02d", hour)
            )
        end

        ImGui.SetCursorPos(startX, startY)
        ImGui.Dummy(width, height + tickSize)

        if ImGui.IsItemHovered() then
            local mouseX = select(1, ImGui.GetMousePos())
            local hour = math.max(0, math.min(
                securityData.HOURS_PER_DAY - 1,
                math.floor((mouseX - originX) / math.max(1, segment))
            ))

            style.tooltip(string.format(
                "%s  %s\n\n%s",
                securityData.getHourLabel(hour),
                securityData.getAreaTypeLabel(timeline[hour + 1]),
                note
            ))
        end
    end

    ---Schedule preview: one strip when it loops, two when days differ.
    ---@param baseType string
    ---@param transitions table[]
    local function drawScheduleStrips(baseType, transitions)
        local firstDay, followingDays, loops = securityData.getScheduleTimelines(baseType, transitions)

        if loops then
            style.mutedText("Every day")
            style.tooltip("The schedule closes its own loop: the last transition leaves the area on the type it started the day with, so every day reads the same.")
            drawScheduleStrip(
                firstDay,
                "Every day, midnight to midnight.\nThe schedule loops: the last transition leaves the area back on its base type."
            )

            return
        end

        style.mutedText("First day")
        style.tooltip("From the moment the area attaches until the first midnight.\nStarts on the area's own type.")
        drawScheduleStrip(
            firstDay,
            string.format(
                "First day, midnight to midnight.\nStarts on the area's own type, %s.",
                securityData.getAreaTypeLabel(baseType)
            )
        )

        ImGui.Dummy(0, 2 * style.viewSize)

        style.styledText("Following days", style.warnColor)
        style.tooltip(string.format(
            "Nothing resets the type at midnight, so day two starts on whatever the last transition left behind -- %s, not %s.\nAdd a transition back to %s to make the two bars match.",
            securityData.getAreaTypeLabel(followingDays[1]),
            securityData.getAreaTypeLabel(baseType),
            securityData.getAreaTypeLabel(baseType)
        ))
        drawScheduleStrip(
            followingDays,
            string.format(
                "Every day after the first.\nCarries over %s from the last transition instead of resetting to %s.",
                securityData.getAreaTypeLabel(followingDays[1]),
                securityData.getAreaTypeLabel(baseType)
            )
        )
    end

    ---The area's `areaTransitions`: an hour, a type to become, and how hard the change lands.
    ---@param areaSpawnable table
    ---@param areaElement table?
    ---@param componentID string
    ---@param index number Position of the area in the network, for widget IDs
    ---@param baseType string
    function device:drawSecuritySchedule(areaSpawnable, areaElement, componentID, index, baseType)
        local transitions = self:getComponentPathArray(areaSpawnable, componentID, securityData.AREA_TRANSITIONS_PATH)
        local historyElement = areaElement or self.object

        ---Writes the transition array whole.
        ---@param settled boolean
        local function commit(settled)
            local normalized = {}

            for _, entry in ipairs(transitions) do
                table.insert(normalized, securityData.normalizeAreaTransition(entry))
            end

            self:updateComponentPathValue(
                areaSpawnable,
                componentID,
                securityData.AREA_TRANSITIONS_PATH,
                normalized,
                { suppressRespawn = settled == false }
            )
        end

        local uiState = self:getSecurityUIState()
        local openKey = "scheduleOpen:" .. tostring(index)
        if uiState[openKey] == nil then
            -- Open by default only when there is a schedule to read.
            uiState[openKey] = #transitions > 0
        end

        ImGui.SetNextItemOpen(uiState[openKey])
        local open = ImGui.TreeNodeEx(string.format("Schedule (%d)###securitySchedule", #transitions))
        uiState[openKey] = open
        style.tooltip("Times of day this area changes type on its own.\nEach row registers a time-system listener at attach, so nothing fires while the area has no system.")

        if not open then
            return
        end

        if #transitions == 0 then
            style.mutedText("Always " .. securityData.getAreaTypeLabel(baseType) .. ". Add a transition to make the area follow the clock.")
            style.tooltip("A common pattern is Disabled by day and Dangerous at night -- two rows, one at each end of the shift.")
        else
            drawScheduleStrips(baseType, transitions)
        end

        for row = 1, #transitions do
            -- Normalize in place because row edits write fields back to this array.
            transitions[row] = securityData.normalizeAreaTransition(transitions[row])

            local entry = transitions[row]
            local usedHours = securityData.getUsedTransitionHours(transitions, row)
            local isDuplicate = usedHours[entry.transitionHour] == true

            -- Key by row position; the array is rebuilt every frame.
            ImGui.PushID("securityTransition" .. tostring(row))

            style.mutedText("at")
            ImGui.SameLine()

            local disabledHours = {}
            for hour in pairs(usedHours) do
                disabledHours[hour + 1] = true
            end

            local newHour, hourChanged = style.trackedCombo(
                historyElement,
                "##securityTransitionHour",
                entry.transitionHour,
                securityData.HOUR_OPTIONS,
                90,
                {
                    disabledOptions = disabledHours,
                    disabledTooltip = "Another transition on this area already fires at this hour.",
                    maxPopupHeight = 240 * style.viewSize
                }
            )
            if hourChanged then
                transitions[row].transitionHour = newHour
                commit(true)
            end

            ImGui.SameLine()
            style.mutedText(IconGlyphs.ArrowRightThin)
            ImGui.SameLine()

            local newType, typeChanged = style.enumCombo(
                historyElement,
                "##securityTransitionType",
                securityData.AREA_TYPES,
                entry.transitionTo,
                nil,
                140
            )
            local typeInfo = securityData.AREA_TYPE_INFO[newType]
            style.tooltip(typeInfo and typeInfo.hint or "Type the area becomes at this hour.")
            if typeChanged then
                transitions[row].transitionTo = newType
                commit(true)
            end

            ImGui.SameLine()
            style.styledText(IconGlyphs.Square, securityData.getAreaTypeColor(newType))

            ImGui.SameLine()
            local newMode, modeChanged = style.enumCombo(
                historyElement,
                "##securityTransitionMode",
                securityData.TRANSITION_MODES,
                entry.transitionMode,
                securityData.TRANSITION_MODE_LABELS,
                100,
                "Gentle waits for the area to be quiet before switching; Forced switches regardless."
            )
            if modeChanged then
                transitions[row].transitionMode = newMode
                commit(true)
            end

            ImGui.SameLine()
            if style.dangerButton(IconGlyphs.DeleteOutline .. "##securityDeleteTransition") then
                history.addAction(history.getElementChange(historyElement))
                table.remove(transitions, row)
                commit(true)
                ImGui.PopID()
                break
            end
            style.tooltip("Remove this transition.")

            if isDuplicate then
                style.styledTextWrapped(
                    string.format(
                        "%s Another transition fires at %s too. Both listeners run and whichever lands last wins, which is not a choice you made.",
                        IconGlyphs.AlertOutline,
                        securityData.getHourLabel(entry.transitionHour)
                    ),
                    style.warnColor
                )
            end

            ImGui.PopID()
        end

        local freeHour = securityData.getFirstFreeTransitionHour(transitions)

        ImGui.BeginDisabled(freeHour == nil)
        if ImGui.Button(IconGlyphs.Plus .. " Add transition##securityAddTransition") and freeHour then
            history.addAction(history.getElementChange(historyElement))
            table.insert(transitions, securityData.newAreaTransition(baseType, freeHour, "GENTLE"))
            commit(true)
        end
        ImGui.EndDisabled()
        style.tooltip(freeHour
            and string.format("Add a transition at %s, the first free hour.", securityData.getHourLabel(freeHour))
            or "All 24 hours already carry a transition.")

        ImGui.TreePop()
    end

    -- Access codes ---------------------------------------------------------------------------------

    ---The system's five code tiers, annotated with areas that demand each tier.
    ---@param network table
    ---@param systemSpawnable table
    ---@param systemElement table?
    ---@param componentID string
    function device:drawSecurityAccessCodes(network, systemSpawnable, systemElement, componentID)
        local historyElement = systemElement or self.object

        -- Track which areas read each tier.
        local demandedBy = {}
        local anyDemand = false

        for _, entry in ipairs(network.areas) do
            local areaComponentID = entry.spawnable and self:getSecurityControllerComponentID(entry.spawnable, true) or nil

            if areaComponentID then
                local level = securityData.getAccessLevelIndex(
                    self:readSecurityValue(entry.spawnable, areaComponentID, securityData.AREA_ACCESS_LEVEL_PATH, "ESL_NONE")
                )

                if level then
                    demandedBy[level] = demandedBy[level] or {}
                    table.insert(demandedBy[level], entry.element and tostring(entry.element.name or "") or entry.nodeRef)
                    anyDemand = true
                end
            end
        end

        local totalEntries = 0

        for level = 0, securityData.ACCESS_LEVEL_COUNT - 1 do
            totalEntries = totalEntries
                + #self:getComponentPathArray(systemSpawnable, componentID, securityData.getAccessLevelPath(level))
        end

        local uiState = self:getSecurityUIState()
        local openKey = "accessCodesOpen"
        if uiState[openKey] == nil then
            -- Keep folded unless some code or demand exists.
            uiState[openKey] = totalEntries > 0 or anyDemand
        end

        ImGui.SetNextItemOpen(uiState[openKey])
        local open = ImGui.TreeNodeEx(string.format("Access Codes (%d)###securityAccessCodes", totalEntries))
        uiState[openKey] = open
        style.tooltip("Five tiers of passwords and keycards. An area picks one tier as its Access Level,\nand a code from that tier then authorizes anyone against it.")

        if not open then
            return
        end

        for level = 0, securityData.ACCESS_LEVEL_COUNT - 1 do
            local path = securityData.getAccessLevelPath(level)
            local entries = self:getComponentPathArray(systemSpawnable, componentID, path)
            local readers = demandedBy[level]

            local function commit(settled)
                local normalized = {}

                for _, entry in ipairs(entries) do
                    table.insert(normalized, securityData.normalizeAccessLevelEntry(entry))
                end

                self:updateComponentPathValue(
                    systemSpawnable,
                    componentID,
                    path,
                    normalized,
                    { suppressRespawn = settled == false }
                )
            end

            ImGui.PushID("securityLevel" .. tostring(level))

            local header = string.format(
                "%s (%d)",
                securityData.ACCESS_LEVEL_LABELS[securityData.accessLevelForIndex(level)],
                #entries
            )
            if readers then
                header = header .. "  -  " .. table.concat(readers, ", ")
            end

            local tierOpenKey = "accessTierOpen:" .. tostring(level)
            if uiState[tierOpenKey] == nil then
                uiState[tierOpenKey] = #entries > 0 or readers ~= nil
            end

            ImGui.SetNextItemOpen(uiState[tierOpenKey])
            local tierOpen = ImGui.TreeNodeEx(header .. "###securityAccessTier")
            uiState[tierOpenKey] = tierOpen

            if readers then
                style.tooltip(string.format(
                    "Demanded by %d area%s on this system.",
                    #readers,
                    #readers == 1 and "" or "s"
                ))
            else
                style.tooltip("No area on this system asks for this tier, so nothing reads these codes.")
            end

            if tierOpen then
                if readers and #entries == 0 then
                    style.styledTextWrapped(
                        string.format(
                            "%s %s ask%s for this tier but it holds no codes, so nothing can authorize against it.",
                            IconGlyphs.AlertOutline,
                            table.concat(readers, ", "),
                            #readers == 1 and "s" or ""
                        ),
                        style.warnColor
                    )
                end

                for row = 1, #entries do
                    entries[row] = securityData.normalizeAccessLevelEntry(entries[row])

                    local entry = entries[row]
                    local password = redValue.readCName(entry.password)
                    local keycard = redValue.readTweakDBID(entry.keycard)

                    ImGui.PushID("securityCode" .. tostring(row))

                    style.drawIconLabelRow(IconGlyphs.KeyOutline, "Code")
                    ImGui.SameLine()

                    local newPassword, _, passwordFinished = style.trackedTextField(
                        historyElement,
                        "##securityCodePassword",
                        password,
                        "e.g. 2077",
                        150
                    )
                    style.tooltip("The number the player types in, usually 3-6 digits.")

                    if passwordFinished and newPassword ~= password then
                        entries[row].password = redValue.cName(newPassword, { sanitize = true, emptyAsNone = true })
                        commit(true)
                    end

                    ImGui.SameLine()
                    style.mutedText("Keycard")
                    ImGui.SameLine()

                    local newKeycard, _, keycardFinished = style.trackedTextField(
                        historyElement,
                        "##securityCodeKeycard",
                        keycard,
                        "Items....",
                        style.getRowFieldWidth({ IconGlyphs.DeleteOutline }, 150)
                    )
                    style.tooltip("An item record the player must be carrying instead of typing a code.\nLeave empty unless your mod adds the item.")

                    if keycardFinished and newKeycard ~= keycard then
                        entries[row].keycard = redValue.tweakDBID(newKeycard, { sanitize = true, emptyAsZero = true })
                        commit(true)
                    end

                    ImGui.SameLine()
                    if style.dangerButton(IconGlyphs.DeleteOutline .. "##securityDeleteCode") then
                        history.addAction(history.getElementChange(historyElement))
                        table.remove(entries, row)
                        commit(true)
                        ImGui.PopID()
                        break
                    end
                    style.tooltip("Remove this code.")

                    if securityData.accessLevelEntryIsEmpty(entries[row]) then
                        style.styledTextWrapped(
                            IconGlyphs.AlertOutline .. " Empty on both halves, so this row authorizes nobody.",
                            style.warnColor
                        )
                    end

                    ImGui.PopID()
                end

                if ImGui.Button(IconGlyphs.Plus .. " Add code##securityAddCode") then
                    history.addAction(history.getElementChange(historyElement))
                    table.insert(entries, securityData.newAccessLevelEntry("", ""))
                    commit(true)
                end
                style.tooltip("Add a password/keycard pair to this tier.")

                ImGui.TreePop()
            end

            ImGui.PopID()
        end

        ImGui.TreePop()
    end

    -- Panels ---------------------------------------------------------------------------------------

    ---Fix banner shown when the popup opens on an orphan area.
    function device:drawSecurityCreateSystemBanner()
        style.styledTextWrapped(
            IconGlyphs.AlertOutline .. " " .. securityData.SECURITY_AREA_NEEDS_SYSTEM,
            style.warnColor
        )

        local canCreate = self.object ~= nil
            and self.object.parent ~= nil
            and not self.object:isLocked()

        ImGui.BeginDisabled(not canCreate)
        if ImGui.Button(IconGlyphs.Plus .. " Create Security System##securityCreateSystem") and canCreate then
            self:addSecuritySystemForArea()
        end
        ImGui.EndDisabled()
        style.tooltip(canCreate
            and "Spawn a security system next to this area and point it here.\nWithout one the area has no faction, no minimap policy, and no master to resolve."
            or "Requires the area to sit inside a group and be unlocked.")
    end

    ---Seeds `DEFAULT_ATTITUDE_MODE` on a system with no mode of its own, once per session.
    ---@param network table
    function device:applySecurityAttitudeDefault(network)
        local systemSpawnable = network.systemSpawnable

        if not systemSpawnable or systemSpawnable.securityAttitudeDefaultApplied then
            return
        end

        local componentID = self:getSecurityControllerComponentID(systemSpawnable, false)
        if not componentID then
            -- Still loading; retry on the next opening.
            return
        end

        systemSpawnable.securityAttitudeDefaultApplied = true

        local overrides = systemSpawnable.instanceDataChanges
            and systemSpawnable.instanceDataChanges[componentID]
            or nil

        -- An override is the author's own choice.
        if overrides and utils.getNestedValue(overrides, securityData.ATTITUDE_MODE_PATH) ~= nil then
            return
        end

        -- Absent means the RED default, which is already Persistent.
        local current = self:getComponentPathValue(systemSpawnable, componentID, securityData.ATTITUDE_MODE_PATH)
        if current == nil or tostring(current) == securityData.DEFAULT_ATTITUDE_MODE then
            return
        end

        history.addAction(history.getElementChange(network.systemElement or self.object))
        self:updateComponentPathValue(
            systemSpawnable,
            componentID,
            securityData.ATTITUDE_MODE_PATH,
            securityData.DEFAULT_ATTITUDE_MODE
        )
    end

    ---@param network table
    function device:drawSecuritySystemPanel(network)
        local systemSpawnable = network.systemSpawnable
        local systemElement = network.systemElement

        if not systemSpawnable then
            -- The banner already carries the fix.
            style.mutedText("No security system claims this area. Create one above to configure it.")

            return
        end

        local systemName = systemElement and tostring(systemElement.name or "") or ""
        local componentID = self:getSecurityControllerComponentID(systemSpawnable, false)

        style.drawDetailTitle(
            securityData.SYSTEM_ICON,
            systemName ~= "" and systemName or "Security System",
            string.format(
                "%d area%s, %d communit%s, %d device%s",
                #network.areas, #network.areas == 1 and "" or "s",
                #network.communities, #network.communities == 1 and "y" or "ies",
                #network.slaves, #network.slaves == 1 and "" or "s"
            )
        )

        if not componentID then
            style.mutedText("Security system state is not available yet. It loads once the node is assembled.")

            return
        end

        local labelX = utils.getTextMaxWidth({
            "Node Ref",
            "Faction",
            "Attitude",
            "Minimap",
            "Auto Reset",
            "Breach",
            "Device State",
            "Community"
        }) + 4 * ImGui.GetStyle().ItemSpacing.x

        style.mutedText("Node Ref")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        self:drawSecurityNodeRefRow(
            systemSpawnable,
            systemElement,
            "System",
            "Areas, communities and devices connect to this NodeRef, and the .psrep entry is keyed on it."
        )

        if network.ownerCount > 1 then
            style.styledTextWrapped(
                string.format(
                    "%s %d security systems connect to this area. Only the master that attaches first drives it.",
                    IconGlyphs.AlertOutline,
                    network.ownerCount
                ),
                style.warnColor
            )
        end

        -- Faction ---------------------------------------------------------------------------------

        local groups = securityData.getAttitudeGroups()
        local currentGroup = redValue.readTweakDBID(
            self:readSecurityValue(systemSpawnable, componentID, securityData.ATTITUDE_GROUP_PATH, nil)
        )

        local uiState = self:getSecurityUIState()
        local searchKey = "attitude:" .. tostring(systemElement and systemElement.id or "self")
        local searchValue = uiState[searchKey] or ""

        drawSecurityFieldLabel(IconGlyphs.ShieldAccount, "Faction", labelX)

        local newGroup, newSearch, groupChanged = style.trackedSearchDropdown(
            "##securityAttitudeGroup",
            "Search attitude group...",
            currentGroup,
            searchValue,
            groups,
            {
                element = systemElement or self.object,
                width = style.getRowFieldWidth({}, 220),
                matchContentWidth = true,
                allowCustom = true,
                clearable = true,
                -- Taller list for the large attitude-group catalogue.
                listHeight = 220,
                tooltip = "The faction this system fights for: it decides who counts as an intruder and who gets alerted.\nGroup_Neutral, Group_Hostile and Group_Friendly are branched on by name in script; the rest are read as records.\nRight-click to clear."
            }
        )
        uiState[searchKey] = newSearch

        if groupChanged then
            self:writeSecurityValue(
                systemSpawnable,
                componentID,
                securityData.ATTITUDE_GROUP_PATH,
                redValue.tweakDBID(newGroup, { sanitize = true, emptyAsZero = true })
            )
        end

        local trimmedGroup = utils.sanitizeText(newGroup)
        if trimmedGroup == "" then
            style.mutedText(IconGlyphs.InformationOutline .. " No faction. The system tracks areas but never changes anyone's attitude.")
            style.tooltip("Legal, but a DANGEROUS area under a factionless system has nobody to turn hostile.")
        elseif not securityData.isKnownAttitudeGroup(trimmedGroup) then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " Not a known Attitudes.Group_* record. Fine if your mod adds it, otherwise it resolves to nothing.",
                style.warnColor
            )
        end

        -- Attitude mode ---------------------------------------------------------------------------

        drawSecurityFieldLabel(nil, "Attitude", labelX)

        local attitudeMode, attitudeChanged = style.enumCombo(
            systemElement or self.object,
            "##securityAttitudeMode",
            securityData.ATTITUDE_MODES,
            self:readSecurityValue(systemSpawnable, componentID, securityData.ATTITUDE_MODE_PATH, securityData.DEFAULT_ATTITUDE_MODE),
            securityData.ATTITUDE_MODE_LABELS,
            160,
            "Whether a faction provoked here stays hostile after the fight.\nPersistent keeps the change once combat ends; Temporary lets the faction settle back."
        )
        if attitudeChanged then
            self:updateComponentPathValue(systemSpawnable, componentID, securityData.ATTITUDE_MODE_PATH, attitudeMode)
        end

        ImGui.SameLine()
        local suppressAttitude = redValue.readBool(
            self:readSecurityValue(systemSpawnable, componentID, securityData.SUPPRESS_ATTITUDE_PATH, 0)
        )
        local newSuppress, suppressChanged = style.trackedCheckbox(
            systemElement or self.object,
            "Lock##securitySuppressAttitude",
            suppressAttitude
        )
        style.tooltip("Locks the faction so combat cannot flip it.")
        if suppressChanged then
            self:updateComponentPathValue(
                systemSpawnable,
                componentID,
                securityData.SUPPRESS_ATTITUDE_PATH,
                redValue.boolToInt(newSuppress, false)
            )
        end

        -- Minimap ---------------------------------------------------------------------------------

        drawSecurityFieldLabel(IconGlyphs.MapMarkerOffOutline, "Minimap", labelX)

        local hideOnMinimap = redValue.readBool(
            self:readSecurityValue(systemSpawnable, componentID, securityData.HIDE_ON_MINIMAP_PATH, 0)
        )
        local newHide, hideChanged = style.trackedCheckbox(
            systemElement or self.object,
            "Hide areas on minimap##securityHideOnMinimap",
            hideOnMinimap
        )
        style.tooltip("Suppresses the Safe/Restricted/Hostile overlay for every area on this system.\nUpdateMiniMapRepresentation() then reports DISABLED regardless of the type set below.")
        if hideChanged then
            self:updateComponentPathValue(
                systemSpawnable,
                componentID,
                securityData.HIDE_ON_MINIMAP_PATH,
                redValue.boolToInt(newHide, false)
            )
        end

        if newHide then
            ImGui.SetCursorPosX(labelX)
            style.mutedText(IconGlyphs.InformationOutline .. " Area types below still drive gameplay, just not the minimap.")
        end

        -- Auto reset ------------------------------------------------------------------------------

        local resetTime = securityData.normalizeTime(
            self:readSecurityValue(systemSpawnable, componentID, securityData.AUTO_RESET_PATH, nil)
        )

        drawSecurityFieldLabel(IconGlyphs.ClockOutline, "Auto Reset", labelX)

        local function drawTimePart(id, value, max, suffix)
            local newValue, changed, finished = style.trackedDragInt(
                systemElement or self.object,
                id,
                value,
                0,
                max,
                46
            )
            ImGui.SameLine()
            style.mutedText(suffix)

            return newValue, changed, finished
        end

        local days, daysChanged, daysFinished = drawTimePart("##securityResetDays", resetTime.days, 365, "d")
        ImGui.SameLine()
        local hours, hoursChanged, hoursFinished = drawTimePart("##securityResetHours", resetTime.hours, 23, "h")
        ImGui.SameLine()
        local minutes, minutesChanged, minutesFinished = drawTimePart("##securityResetMinutes", resetTime.minutes, 59, "m")

        -- Write during drag so the displayed value does not snap back; respawn only on release.
        local settled = daysFinished or hoursFinished or minutesFinished

        if daysChanged or hoursChanged or minutesChanged or settled then
            self:updateComponentPathValue(
                systemSpawnable,
                componentID,
                securityData.AUTO_RESET_PATH,
                securityData.newTime(days, hours, minutes),
                { suppressRespawn = not settled }
            )
        end

        ImGui.SameLine()
        style.mutedText(IconGlyphs.InformationOutline)
        style.tooltip("How long an alerted system waits before resetting itself.\nAll zero means never.")

        -- Breach / state --------------------------------------------------------------------------

        drawSecurityFieldLabel(nil, "Breach", labelX)

        local breach, breachChanged = style.enumCombo(
            systemElement or self.object,
            "##securitySystemBreach",
            securityData.BREACH_DIFFICULTIES,
            self:readSecurityValue(systemSpawnable, componentID, securityData.BREACH_DIFFICULTY_PATH, "EASY"),
            nil,
            120,
            "Breach protocol difficulty for this network."
        )
        if breachChanged then
            self:updateComponentPathValue(systemSpawnable, componentID, securityData.BREACH_DIFFICULTY_PATH, breach)
        end

        ImGui.SameLine()
        local selfDisable = redValue.readBool(
            self:readSecurityValue(systemSpawnable, componentID, securityData.ALLOW_SELF_DISABLE_PATH, 1)
        )
        local newSelfDisable, selfDisableChanged = style.trackedCheckbox(
            systemElement or self.object,
            "Can stand down##securitySelfDisable",
            selfDisable
        )
        style.tooltip("Lets the system disable itself once its areas go Disabled.")
        if selfDisableChanged then
            self:updateComponentPathValue(
                systemSpawnable,
                componentID,
                securityData.ALLOW_SELF_DISABLE_PATH,
                redValue.boolToInt(newSelfDisable, true)
            )
        end

        drawSecurityFieldLabel(nil, "Device State", labelX)

        local systemState, systemStateChanged = style.enumCombo(
            systemElement or self.object,
            "##securitySystemDeviceState",
            securityData.DEVICE_STATES,
            self:readSecurityValue(systemSpawnable, componentID, securityData.DEVICE_STATE_PATH, "ON"),
            nil,
            120,
            "State the system starts in."
        )
        if systemStateChanged then
            self:updateComponentPathValue(systemSpawnable, componentID, securityData.DEVICE_STATE_PATH, systemState)
        end

        -- Access codes -----------------------------------------------------------------------------

        self:drawSecurityAccessCodes(network, systemSpawnable, systemElement, componentID)

        if not systemSpawnable.persistent then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " Persistent is off, so this system's state is not written to the .psrep file.",
                style.warnColor
            )

            if ImGui.Button("Enable Persistent##securitySystemPersistent") then
                self:ensureSecurityPersistent(systemSpawnable, systemElement)
            end
        end

        -- Wiring -----------------------------------------------------------------------------------

        ImGui.Dummy(0, 8 * style.viewSize)
        self:drawSecurityLinkExistingRows(network)
    end

    ---@param entry table
    ---@param index number
    ---@param network table
    ---@param options table? `{ titleAction = table }`
    function device:drawSecurityAreaPanel(entry, index, network, options)
        options = options or {}

        local areaSpawnable = entry.spawnable
        local areaElement = entry.element

        local headerName = areaElement and tostring(areaElement.name or "") or ""
        if headerName == "" then
            headerName = entry.nodeRef ~= "" and entry.nodeRef or ("Area " .. tostring(index))
        end

        ImGui.PushID("securityArea" .. tostring(index))

        if not areaSpawnable then
            style.drawDetailTitle(securityData.AREA_ICON, headerName, "unresolved", options.titleAction)
            style.styledTextWrapped(
                string.format(
                    "%s %s -- no node in this project carries that NodeRef. The link resolves only if the area lives in another sector.",
                    IconGlyphs.AlertOutline,
                    entry.nodeRef ~= "" and entry.nodeRef or "(empty NodeRef)"
                ),
                style.warnColor
            )
            ImGui.PopID()

            return
        end

        local componentID = self:getSecurityControllerComponentID(areaSpawnable, true)
        if not componentID then
            style.drawDetailTitle(securityData.AREA_ICON, headerName, "loading", options.titleAction)
            style.mutedText("Area state is not available yet. It loads once the node is assembled.")
            ImGui.PopID()

            return
        end

        local areaType = tostring(
            self:readSecurityValue(areaSpawnable, componentID, securityData.AREA_TYPE_PATH, securityData.DEFAULT_AREA_TYPE)
        )

        style.drawDetailTitle(
            securityData.AREA_ICON,
            headerName,
            securityData.getAreaTypeLabel(areaType) .. (entry.isSelf and "  (opened on)" or ""),
            options.titleAction
        )

        if entry.isOrphan then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " " .. securityData.SECURITY_AREA_NEEDS_SYSTEM,
                style.warnColor
            )
        end

        local labelX = utils.getTextMaxWidth({
            "Node Ref",
            "Type",
            "Zone Name",
            "Access Level",
            "Events",
            "Device State"
        }) + 4 * ImGui.GetStyle().ItemSpacing.x

        drawSecurityFieldLabel(nil, "Node Ref", labelX)
        self:drawSecurityNodeRefRow(
            areaSpawnable,
            areaElement,
            "Area" .. tostring(index),
            "The security system's connection row points at this NodeRef."
        )

        -- Type ------------------------------------------------------------------------------------

        drawSecurityFieldLabel(securityData.AREA_ICON, "Type", labelX)

        local newType, typeChanged = style.enumCombo(
            areaElement or self.object,
            "##securityAreaType",
            securityData.AREA_TYPES,
            areaType,
            nil,
            150
        )
        local typeInfo = securityData.AREA_TYPE_INFO[newType]
        style.tooltip(typeInfo and typeInfo.hint or "What the area does to anyone inside it.")

        if typeChanged then
            self:writeSecurityValue(areaSpawnable, componentID, securityData.AREA_TYPE_PATH, newType)
        end

        -- The swatch makes area lists scannable without repeating the type label.
        if typeInfo then
            ImGui.SameLine()
            style.styledText(IconGlyphs.Square, securityData.getAreaTypeColor(newType))
            style.tooltip(typeInfo.hint)
        end

        -- Outline ---------------------------------------------------------------------------------

        self:drawSecurityOutlineRow(areaSpawnable, areaElement, labelX)

        -- Zone name -------------------------------------------------------------------------------

        drawSecurityFieldLabel(nil, "Zone Name", labelX)

        local zoneName = tostring(
            self:readSecurityValue(areaSpawnable, componentID, securityData.DEVICE_NAME_PATH, "") or ""
        )
        local newZoneName, _, zoneFinished = style.trackedTextField(
            areaElement or self.object,
            "##securityZoneName",
            zoneName,
            "Unnamed zone...",
            style.getRowFieldWidth({}, 200)
        )
        style.tooltip("GetSecurityAreaData() reads this as the zone name.")

        if zoneFinished and newZoneName ~= zoneName then
            self:writeSecurityValue(areaSpawnable, componentID, securityData.DEVICE_NAME_PATH, newZoneName)
        end

        -- Access level ----------------------------------------------------------------------------

        drawSecurityFieldLabel(nil, "Access Level", labelX)

        local accessLevel, accessChanged = style.enumCombo(
            areaElement or self.object,
            "##securityAccessLevel",
            securityData.ACCESS_LEVELS,
            self:readSecurityValue(areaSpawnable, componentID, securityData.AREA_ACCESS_LEVEL_PATH, "ESL_NONE"),
            securityData.ACCESS_LEVEL_LABELS,
            190,
            "Which of the system's five code tiers this area demands."
        )
        if accessChanged then
            self:writeSecurityValue(areaSpawnable, componentID, securityData.AREA_ACCESS_LEVEL_PATH, accessLevel)
        end

        -- Events ----------------------------------------------------------------------------------

        local filters = securityData.normalizeEventsFilters(
            self:readSecurityValue(areaSpawnable, componentID, securityData.EVENTS_FILTERS_PATH, nil)
        )

        drawSecurityFieldLabel(nil, "Events", labelX)
        style.mutedText("in")
        ImGui.SameLine()

        local incoming, incomingChanged = style.enumCombo(
            areaElement or self.object,
            "##securityIncomingFilter",
            securityData.FILTER_TYPES,
            filters.incomingEventsFilter,
            securityData.FILTER_LABELS,
            130,
            "What this area accepts from the rest of the network."
        )

        ImGui.SameLine()
        style.mutedText("out")
        ImGui.SameLine()

        local outgoing, outgoingChanged = style.enumCombo(
            areaElement or self.object,
            "##securityOutgoingFilter",
            securityData.FILTER_TYPES,
            filters.outgoingEventsFilter,
            securityData.FILTER_LABELS,
            130,
            "What this area reports back.\nAllow none makes an area that sees everything and tells nobody."
        )

        if incomingChanged or outgoingChanged then
            self:writeSecurityValue(
                areaSpawnable,
                componentID,
                securityData.EVENTS_FILTERS_PATH,
                securityData.newEventsFilters(incoming, outgoing)
            )
        end

        -- State -----------------------------------------------------------------------------------

        drawSecurityFieldLabel(nil, "Device State", labelX)

        local areaState, areaStateChanged = style.enumCombo(
            areaElement or self.object,
            "##securityAreaDeviceState",
            securityData.DEVICE_STATES,
            self:readSecurityValue(areaSpawnable, componentID, securityData.DEVICE_STATE_PATH, "ON"),
            nil,
            120,
            "State the area starts in."
        )
        if areaStateChanged then
            self:writeSecurityValue(areaSpawnable, componentID, securityData.DEVICE_STATE_PATH, areaState)
        end

        -- Schedule ---------------------------------------------------------------------------------

        -- Schedule is the only area list, so keep it folded under scalar rows.
        self:drawSecuritySchedule(areaSpawnable, areaElement, componentID, index, newType)

        if not areaSpawnable.persistent then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " Persistent is off, so this area's type is not written to the .psrep file.",
                style.warnColor
            )

            if ImGui.Button("Enable Persistent##securityAreaPersistent") then
                self:ensureSecurityPersistent(areaSpawnable, areaElement)
            end
        end

        ImGui.PopID()
    end

    ---Draws `DEVICE_SETTING_GROUPS` for one driven device, against its own controller component.
    ---@param entry table Network entry `{ spawnable, element, className }`
    ---@param labelX number Label column shared with the rows above
    function device:drawSecurityDeviceSettings(entry, labelX)
        local targetSpawnable = entry.spawnable
        if not targetSpawnable then
            return
        end

        local groups = securityData.getDeviceSettingGroups(entry.className)
        if #groups == 0 then
            return
        end

        local componentID = self:getPersistentComponentID(targetSpawnable, entry.className)
        if not componentID then
            ImGui.Dummy(0, 4 * style.viewSize)
            style.mutedText("Device settings are not available yet. They load once the node is assembled.")

            return
        end

        local targetElement = entry.element or self.object

        ---Value to show when the entity leaves the property unwritten.
        ---@param field table
        ---@return any
        local function fieldDefault(field)
            if field.classDefaults then
                local perClass = field.classDefaults[utils.sanitizeText(entry.className)]

                if perClass ~= nil then
                    return perClass
                end
            end

            return field.default
        end

        ---@param field table
        ---@return any
        local function readField(field)
            local value

            if field.struct then
                local structDef = securityData.DEVICE_STRUCTS[field.struct]
                local struct = self:getComponentPathValue(targetSpawnable, componentID, structDef.path)
                value = type(struct) == "table" and struct[field.field] or nil
            else
                value = self:getComponentPathValue(targetSpawnable, componentID, field.path)
            end

            if value == nil then
                return fieldDefault(field)
            end

            return value
        end

        ---@param field table
        ---@param value any
        ---@param writeOptions table?
        local function writeField(field, value, writeOptions)
            if not field.struct then
                self:updateComponentPathValue(targetSpawnable, componentID, field.path, value, writeOptions)

                return
            end

            -- A member cannot be written alone; the whole struct goes back.
            local structDef = securityData.DEVICE_STRUCTS[field.struct]
            local struct = securityData.normalizeDeviceStruct(
                self:getComponentPathValue(targetSpawnable, componentID, structDef.path),
                structDef.type
            )
            struct[field.field] = value

            self:updateComponentPathValue(targetSpawnable, componentID, structDef.path, struct, writeOptions)
        end

        ---@param field table
        local function drawField(field)
            local id = "##securityDeviceField" .. field.key

            if field.kind == "bool" then
                local newValue, changed = style.trackedCheckbox(
                    targetElement,
                    (field.checkbox or field.label or "") .. id,
                    redValue.readBool(readField(field))
                )

                if field.tooltip then
                    style.tooltip(field.tooltip)
                end

                if changed then
                    writeField(field, redValue.boolToInt(newValue, fieldDefault(field) == true))
                end
            elseif field.kind == "enum" then
                local newValue, changed = style.enumCombo(
                    targetElement,
                    id,
                    field.values,
                    tostring(readField(field) or ""),
                    field.labels,
                    field.width or 140,
                    field.tooltip
                )

                if changed then
                    writeField(field, newValue)
                end
            elseif field.kind == "float" then
                local newValue, changed, finished = style.trackedDragFloat(
                    targetElement,
                    id,
                    utils.toNumber(readField(field), 0),
                    field.step or 0.1,
                    field.min or 0,
                    field.max or 100,
                    field.format or "%.1f",
                    field.width or 56
                )

                if field.tooltip then
                    style.tooltip(field.tooltip)
                end

                -- Write during the drag so the field does not snap back; respawn only on release.
                if changed or finished then
                    writeField(field, newValue, { suppressRespawn = not finished })
                end
            end
        end

        for _, group in ipairs(groups) do
            style.sectionHeaderStart(group.label)

            for _, field in ipairs(group.fields) do
                if field.inline then
                    ImGui.SameLine()
                else
                    drawSecurityFieldLabel(field.icon, field.label, labelX)
                end

                if field.prefix then
                    style.mutedText(field.prefix)
                    ImGui.SameLine()
                end

                drawField(field)

                if field.suffix then
                    ImGui.SameLine()
                    style.mutedText(field.suffix)
                end
            end

            style.sectionHeaderEnd()
        end

        if not targetSpawnable.persistent then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " Persistent is off, so these settings are not written to the .psrep file.",
                style.warnColor
            )

            if ImGui.Button("Enable Persistent##securityDevicePersistent") then
                self:ensureSecurityPersistent(targetSpawnable, entry.element)
            end
        end
    end

    ---Panel for a selected community or driven-device link.
    ---@param network table
    ---@param entry table
    ---@param index number
    ---@param options table? `{ icon, label, className, titleAction, showAppearance, showSettings, note }`
    function device:drawSecurityLinkPanel(network, entry, index, options)
        options = options or {}

        local targetSpawnable = entry.spawnable
        local targetElement = entry.element
        local name = targetElement and tostring(targetElement.name or "") or ""

        if name == "" then
            name = entry.nodeRef ~= "" and entry.nodeRef or "Unresolved"
        end

        ImGui.PushID("securityLinkPanel" .. tostring(index))

        style.drawDetailTitle(
            options.icon or IconGlyphs.Chip,
            name,
            targetSpawnable and (options.label or "") or "unresolved",
            options.titleAction
        )

        local labels = { "Node Ref", "Class", "Appearance" }

        if options.showSettings then
            for _, group in ipairs(securityData.getDeviceSettingGroups(entry.className)) do
                for _, field in ipairs(group.fields) do
                    if field.label then
                        table.insert(labels, field.label)
                    end
                end
            end
        end

        local labelX = utils.getTextMaxWidth(labels) + 4 * ImGui.GetStyle().ItemSpacing.x

        drawSecurityFieldLabel(nil, "Node Ref", labelX)

        if targetSpawnable then
            self:drawSecurityNodeRefRow(
                targetSpawnable,
                targetElement,
                "Link" .. tostring(index),
                "This system's connection row points at this NodeRef. Renaming it here carries the connection with it."
            )
        else
            style.mutedText(entry.nodeRef ~= "" and entry.nodeRef or "(empty NodeRef)")
        end

        style.mutedText("Class")
        ImGui.SameLine()
        ImGui.SetCursorPosX(labelX)
        style.mutedText(entry.className or options.className or "")
        style.tooltip("Controller class the connection row is stored under.\nThe game resolves the link through it, so it has to match the node's own class.")

        if options.showAppearance and targetSpawnable then
            -- Key appearance search by NodeRef so reorderings keep the right draft.
            self:drawSecurityAppearanceRow(
                targetSpawnable,
                targetElement,
                utils.sanitizeText(entry.nodeRef) ~= "" and tostring(entry.nodeRef) or ("index" .. tostring(index)),
                labelX
            )
        end

        if not targetSpawnable then
            style.styledTextWrapped(
                IconGlyphs.AlertOutline .. " No node in this project carries that NodeRef. The link resolves only if the node lives in another sector.",
                style.warnColor
            )
        end

        if options.note then
            style.mutedText(options.note)
            style.tooltip(options.noteTooltip)
        end

        if options.showSettings then
            self:drawSecurityDeviceSettings(entry, labelX)
        end

        ImGui.PopID()
    end

    ---Detail panel for the selected graph node.
    ---@param childHeight number
    ---@param network table
    function device:drawSecuritySelectionPanel(childHeight, network)
        local panelHeight = math.max(0, tonumber(childHeight) or (280 * style.viewSize))
        local selection = self:getSecuritySelection()
        local editable = canEditNetwork(network)

        ---Finds the selected entry, or nil after deletion.
        ---@param list table[]
        ---@param kind string
        ---@return table?, number?
        local function findSelected(list, kind)
            for index, entry in ipairs(list) do
                if getSecuritySelectionKey(kind, entry, index) == selection.key then
                    return entry, index
                end
            end

            return nil, nil
        end

        ---Delete the target node, or unlink unresolved refs.
        ---@param entry table
        ---@param label string
        ---@return table
        local function titleAction(entry, label)
            local hasNode = entry.spawnable ~= nil
            -- Do not delete the device the popup is bound to mid-frame.
            local isSelf = entry.spawnable == self

            return {
                label = (hasNode and IconGlyphs.DeleteOutline or IconGlyphs.LanDisconnect)
                    .. "##securitySelectedRemove",
                tooltip = isSelf
                    and "This is the node the popup was opened on. Remove it from the hierarchy instead."
                    or (hasNode
                        and string.format("Delete this %s and remove its connection.\nRight click its box in the graph to unlink it without deleting it.", label)
                        or string.format("Remove the connection. There is no %s in this project to delete.", label)),
                danger = true,
                disabled = not editable or isSelf,
                onClick = function ()
                    network.systemSpawnable:removeSecurityNode(entry, hasNode)
                    self:setSecuritySelection(nil)
                end
            }
        end

        -- `endCard` is owed even when the card contents are clipped.
        local visible = style.beginCard("##securitySelectionPanel", {
            height = panelHeight,
            flags = ImGuiWindowFlags.HorizontalScrollbar
        })

        if visible then
            if selection.kind == "area" then
                local entry, index = findSelected(network.areas, "area")

                if entry and index then
                    self:drawSecurityAreaPanel(entry, index, network, {
                        titleAction = titleAction(entry, "area")
                    })
                else
                    style.mutedText("That area is gone. Pick another box in the graph.")
                end
            elseif selection.kind == "community" then
                local entry, index = findSelected(network.communities, "community")

                if entry and index then
                    self:drawSecurityLinkPanel(network, entry, index, {
                        icon = securityData.COMMUNITY_ICON,
                        label = "Community",
                        className = securityData.COMMUNITY_PROXY_CLASS,
                        titleAction = titleAction(entry, "community"),
                        note = "NPCs in this community are alerted by everything on this network.",
                        noteTooltip = "Linking the community to the system rather than to a single area is what scales to several areas sharing a squad."
                    })
                else
                    style.mutedText("That community is gone. Pick another box in the graph.")
                end
            elseif selection.kind == "device" then
                local entry, index = findSelected(network.slaves, "device")

                if entry and index then
                    self:drawSecurityLinkPanel(network, entry, index, {
                        icon = entry.icon or IconGlyphs.Cctv,
                        label = entry.label or entry.className,
                        titleAction = titleAction(entry, "device"),
                        showAppearance = true,
                        showSettings = true,
                        note = "This device reports into the system and reacts to its state."
                    })
                else
                    style.mutedText("That device is gone. Pick another box in the graph.")
                end
            else
                self:drawSecuritySystemPanel(network)
            end

            ImGui.Dummy(0, 8 * style.viewSize)
        end

        style.endCard()
    end
    -- Validation -----------------------------------------------------------------------------------

    ---Network validation issues, ordered with blocking errors first.
    ---@param network table
    ---@return table[] issues Each `{ level, text, fix, fixLabel, fixTooltip }`
    function device:collectSecurityIssues(network)
        local issues = {}

        ---@param level string "error" or "warn"
        ---@param text string
        ---@param fix function?
        ---@param fixLabel string?
        ---@param fixTooltip string?
        local function add(level, text, fix, fixLabel, fixTooltip)
            table.insert(issues, {
                level = level,
                text = text,
                fix = fix,
                fixLabel = fixLabel,
                fixTooltip = fixTooltip
            })
        end

        local function persistentFix(targetSpawnable, targetElement)
            return function()
                self:ensureSecurityPersistent(targetSpawnable, targetElement)
            end
        end

        local function writeValueFix(ownerElement, targetSpawnable, componentID, path, value)
            return function()
                history.addAction(history.getElementChange(ownerElement or self.object))
                self:writeSecurityValue(targetSpawnable, componentID, path, value)
            end
        end

        local systemSpawnable = network.systemSpawnable
        local systemElement = network.systemElement
        local systemComponentID = systemSpawnable and self:getSecurityControllerComponentID(systemSpawnable, false) or nil

        -- Resolve area names once for validation messages.
        local function areaName(entry, index)
            local name = entry.element and tostring(entry.element.name or "") or ""

            if name ~= "" then
                return name
            end

            return entry.nodeRef ~= "" and entry.nodeRef or ("Area " .. tostring(index))
        end

        -- System-level ------------------------------------------------------------------------------

        if not systemSpawnable then
            local canCreate = self.object ~= nil and self.object.parent ~= nil and not self.object:isLocked()

            add(
                "error",
                securityData.SECURITY_AREA_NEEDS_SYSTEM,
                canCreate and function() self:addSecuritySystemForArea() end or nil,
                "Create system",
                "Spawn a security system beside this area and point it here."
            )
        elseif network.ownerCount > 1 then
            add("warn", string.format(
                "%d security systems connect to this area. Only the master that attaches first drives it; the rest are dead links.",
                network.ownerCount
            ))
        end

        if systemSpawnable and systemComponentID then
            if not systemSpawnable.persistent then
                add(
                    "error",
                    "The security system is not persistent, so none of its state reaches the .psrep file and the network resets on load.",
                    persistentFix(systemSpawnable, systemElement),
                    "Make persistent",
                    "Give the system a NodeRef and mark it persistent."
                )
            end

            local group = redValue.readTweakDBID(
                self:readSecurityValue(systemSpawnable, systemComponentID, securityData.ATTITUDE_GROUP_PATH, nil)
            )

            if group ~= "" and not securityData.isKnownAttitudeGroup(group) then
                add("warn", string.format(
                    "Faction '%s' is not a known Attitudes.Group_* record. Fine if your mod adds it, otherwise it resolves to nothing.",
                    group
                ))
            end
        end

        -- Per area ----------------------------------------------------------------------------------

        local dangerousWithoutFaction = false

        for index, entry in ipairs(network.areas) do
            local name = areaName(entry, index)
            local areaSpawnable = entry.spawnable

            repeat
            if not areaSpawnable then
                add("warn", string.format(
                    "%s: no node in this project carries that NodeRef. The link resolves only if the area lives in another sector.",
                    entry.nodeRef ~= "" and entry.nodeRef or "(empty NodeRef)"
                ))
                break
            end

            local componentID = self:getSecurityControllerComponentID(areaSpawnable, true)
            if not componentID then
                break
            end

            local areaType = tostring(self:readSecurityValue(
                areaSpawnable,
                componentID,
                securityData.AREA_TYPE_PATH,
                securityData.DEFAULT_AREA_TYPE
            ))

            if areaType == "DANGEROUS" or areaType == "SAFE" then
                dangerousWithoutFaction = true
            end

            if not areaSpawnable.persistent then
                add(
                    "error",
                    string.format("%s is not persistent, so its type is not written to the .psrep file.", name),
                    persistentFix(areaSpawnable, entry.element),
                    "Make persistent",
                    "Give the area a NodeRef and mark it persistent."
                )
            end

            -- Volume --------------------------------------------------------------------------------

            local bound = areaSpawnable.outlinePath ~= nil
                and areaSpawnable.outlinePath ~= ""
                and areaSpawnable.outlinePath ~= "None"
            local points, height = 0, 0

            if bound then
                local localPoints, outlineHeight = outlineConsumer.getLocalPoints(areaSpawnable)
                points, height = #localPoints, outlineHeight
            end

            local canBuildOutline = areaSpawnable.addSecurityOutline ~= nil
                and entry.element ~= nil
                and entry.element.parent ~= nil
                and not entry.element:isLocked()

            local function buildOutline()
                local changes = { history.getElementChange(entry.element) }
                local outlineGroup = areaSpawnable:addSecurityOutline()

                if not outlineGroup then
                    return
                end

                table.insert(changes, history.getInsert({ outlineGroup }))
                history.addAction(history.getComposite(changes))
            end

            if not bound then
                add(
                    "warn",
                    string.format("%s has no outline bound, so it keeps the entity's own 8x8 m box wherever you put it.", name),
                    canBuildOutline and buildOutline or nil,
                    "Add outline",
                    "Spawn a group of four markers around the area and bind it."
                )
            elseif points < outlineConsumer.MIN_MARKERS then
                add(
                    "error",
                    string.format(
                        "%s: its outline group holds %d marker%s, and a volume needs at least %d.",
                        name,
                        points,
                        points == 1 and "" or "s",
                        outlineConsumer.MIN_MARKERS
                    ),
                    canBuildOutline and buildOutline or nil,
                    "Rebuild outline",
                    "Spawn a fresh group of four markers around the area and bind to it instead."
                )
            elseif height <= 0 then
                add("error", string.format(
                    "%s: its outline is %.2f m high, so the volume is flat and nothing can ever be inside it.",
                    name,
                    height
                ))
            end

            -- Schedule ------------------------------------------------------------------------------

            local transitions = self:getComponentPathArray(areaSpawnable, componentID, securityData.AREA_TRANSITIONS_PATH)
            local seenHours = {}
            local clashHour = nil

            for _, transition in ipairs(transitions) do
                local hour = math.floor(utils.toNumber(transition.transitionHour, 0)) % securityData.HOURS_PER_DAY

                if seenHours[hour] then
                    clashHour = clashHour or hour
                end
                seenHours[hour] = true
            end

            if clashHour then
                add(
                    "warn",
                    string.format(
                        "%s has two transitions at %s. Both listeners fire and whichever lands last wins.",
                        name,
                        securityData.getHourLabel(clashHour)
                    ),
                    function()
                        history.addAction(history.getElementChange(entry.element or self.object))

                        local used = {}
                        local rewritten = {}

                        for _, transition in ipairs(transitions) do
                            local normalized = securityData.normalizeAreaTransition(transition)

                            if used[normalized.transitionHour] then
                                local free = securityData.getFirstFreeTransitionHour(rewritten)

                                -- Leave a 25th clashing row untouched; there is no free hour.
                                if free then
                                    normalized.transitionHour = free
                                end
                            end

                            used[normalized.transitionHour] = true
                            table.insert(rewritten, normalized)
                        end

                        self:updateComponentPathValue(
                            areaSpawnable,
                            componentID,
                            securityData.AREA_TRANSITIONS_PATH,
                            rewritten
                        )
                    end,
                    "Spread out",
                    "Move each clashing transition to the first free hour, keeping the first one where it is."
                )
            end

            -- Access level --------------------------------------------------------------------------

            local accessLevel = tostring(self:readSecurityValue(
                areaSpawnable,
                componentID,
                securityData.AREA_ACCESS_LEVEL_PATH,
                "ESL_NONE"
            ))
            local tier = securityData.getAccessLevelIndex(accessLevel)

            if tier and systemSpawnable and systemComponentID then
                local codes = self:getComponentPathArray(
                    systemSpawnable,
                    systemComponentID,
                    securityData.getAccessLevelPath(tier)
                )
                local usable = 0

                for _, code in ipairs(codes) do
                    if not securityData.accessLevelEntryIsEmpty(code) then
                        usable = usable + 1
                    end
                end

                if usable == 0 then
                    add(
                        "warn",
                        string.format(
                            "%s demands %s, but that tier holds no usable code on the system, so nothing can authorize against it.",
                            name,
                            securityData.ACCESS_LEVEL_LABELS[accessLevel] or accessLevel
                        ),
                        writeValueFix(entry.element, areaSpawnable, componentID, securityData.AREA_ACCESS_LEVEL_PATH, "ESL_NONE"),
                        "Clear demand",
                        "Set this area's access level back to None.\nThe other way out is to fill the tier under Access Codes on the system."
                    )
                end
            end

            until true
        end

        -- Cross-cutting -----------------------------------------------------------------------------

        if systemSpawnable and systemComponentID and dangerousWithoutFaction then
            local group = redValue.readTweakDBID(
                self:readSecurityValue(systemSpawnable, systemComponentID, securityData.ATTITUDE_GROUP_PATH, nil)
            )

            if group == "" then
                add(
                    "warn",
                    "An area on this system is Dangerous or Safe, but the system has no faction -- so there is nobody for it to turn hostile or protective.",
                    writeValueFix(
                        systemElement,
                        systemSpawnable,
                        systemComponentID,
                        securityData.ATTITUDE_GROUP_PATH,
                        redValue.tweakDBID("Attitudes.Group_Hostile", { sanitize = true, emptyAsZero = true })
                    ),
                    "Set Hostile",
                    "Group_Hostile is one of the three groups the controller branches on by name, and the safe default for a hostile zone."
                )
            end
        end

        if systemSpawnable and #network.areas == 0 then
            add("warn", "This system owns no areas, so it has nothing to watch.")
        end

        -- Blocking errors first.
        local ordered = {}

        for _, issue in ipairs(issues) do
            if issue.level == "error" then
                table.insert(ordered, issue)
            end
        end

        for _, issue in ipairs(issues) do
            if issue.level ~= "error" then
                table.insert(ordered, issue)
            end
        end

        return ordered
    end

    ---Findings past this many scroll instead of growing the strip.
    local ISSUE_LIST_MAX_ROWS = 4

    ---The validation strip: one line per issue, with its fix button where there is one.
    ---@param network table
    function device:drawSecurityIssues(network)
        local issues = self:collectSecurityIssues(network)

        if #issues == 0 then
            self:getSecurityUIState().issuesOpen = nil
            return
        end

        local errors = 0
        for _, issue in ipairs(issues) do
            if issue.level == "error" then
                errors = errors + 1
            end
        end

        local header = string.format("Issues (%d)", #issues)
        if errors > 0 then
            header = string.format("Issues (%d, %d blocking)", #issues, errors)
        end

        local uiState = self:getSecurityUIState()

        -- Auto-open only for blocking errors.
        if uiState.issuesOpen == nil then
            uiState.issuesOpen = errors > 0
        end

        ImGui.SetNextItemOpen(uiState.issuesOpen)
        local issuesOpen = ImGui.TreeNodeEx(header .. "###securityIssues")
        uiState.issuesOpen = issuesOpen
        style.tooltip("Checks links, outlines, persistence, transition hours and access tiers across the whole network.")

        if not issuesOpen then
            return
        end

        -- Scroll long issue lists so the graph and selected panel stay visible.
        local scrolled = #issues > ISSUE_LIST_MAX_ROWS
        local listVisible = true

        if scrolled then
            listVisible = ImGui.BeginChild(
                "##securityIssueList",
                0,
                ISSUE_LIST_MAX_ROWS * ImGui.GetFrameHeightWithSpacing(),
                false
            )
        end

        local styleData = ImGui.GetStyle()
        local contentWidth = ImGui.GetWindowContentRegionWidth()

        for index, issue in ipairs(listVisible and issues or {}) do
            ImGui.PushID("securityIssue" .. tostring(index))

            local isError = issue.level == "error"
            local fixLabel = issue.fix and (IconGlyphs.AutoFix .. " " .. (issue.fixLabel or "Fix")) or nil
            local buttonWidth = fixLabel
                and (ImGui.CalcTextSize(fixLabel) + 2 * styleData.FramePadding.x)
                or 0

            style.styledText(isError and IconGlyphs.AlertCircleOutline or IconGlyphs.AlertOutline, style.warnColor)
            ImGui.SameLine()

            -- Wrap issue text before the fix-button column.
            ImGui.PushTextWrapPos(contentWidth - buttonWidth - (fixLabel and 2 * styleData.ItemSpacing.x or 0))
            style.styledTextWrapped(issue.text, isError and style.warnColor or style.mutedColor)
            ImGui.PopTextWrapPos()

            if fixLabel then
                -- Right-align fixes into one column.
                ImGui.SameLine()
                ImGui.SetCursorPosX(contentWidth - buttonWidth)

                if style.warnButton(fixLabel, { tooltip = issue.fixTooltip or "Apply this fix." }) then
                    issue.fix()
                    self:refreshNodeRefCaches()
                end
            end

            ImGui.PopID()
        end

        if scrolled then
            ImGui.EndChild()
        end

        ImGui.TreePop()
    end

    -- Popup ------------------------------------------------------------------------------------------

    function device:drawSecuritySetupPopup()
        -- Sized for the graph plus the selected-node detail panel.
        local defaultWidth = 660 * style.viewSize
        local defaultHeight = 700 * style.viewSize
        local minWidth = 600 * style.viewSize
        local minHeight = 560 * style.viewSize
        local screenWidth, screenHeight = GetDisplayResolution()
        local maxWidth = math.max(minWidth, screenWidth - 40 * style.viewSize)
        local maxHeight = math.max(minHeight, screenHeight - 40 * style.viewSize)

        ImGui.SetNextWindowSize(defaultWidth, defaultHeight, ImGuiCond.FirstUseEver)
        ImGui.SetNextWindowSizeConstraints(minWidth, minHeight, maxWidth, maxHeight)

        local popupIsOpen = ImGui.BeginPopupModal(quickSecuritySetupUI.POPUP_ID, true)
        if not popupIsOpen then
            self.securityPopupWasOpen = false

            return
        end

        local popupJustOpened = not self.securityPopupWasOpen
        self.securityPopupWasOpen = true

        -- Ensure the opened device can be linked and exported.
        if popupJustOpened then
            self:ensureSecurityPersistent(self, self.object)
        end

        registry.update()
        local network = self:resolveSecurityNetwork()

        if popupJustOpened then
            self:applySecurityAttitudeDefault(network)
        end

        -- Load area trigger components once per popup opening.
        if popupJustOpened then
            for _, entry in ipairs(network.areas) do
                if entry.spawnable and entry.spawnable.ensureAreaShapeLoaded then
                    entry.spawnable:ensureAreaShapeLoaded()
                end
            end
        end

        -- Start on the opened area when applicable; otherwise start on the system.
        if popupJustOpened then
            self:setSecuritySelection(nil)

            if network.openedOnArea then
                for index, entry in ipairs(network.areas) do
                    if entry.spawnable == self then
                        self:setSecuritySelection({
                            kind = "area",
                            key = getSecuritySelectionKey("area", entry, index)
                        })
                        break
                    end
                end
            end
        end

        -- Graph, validation, then selected-node details.
        if network.systemSpawnable then
            self:drawSecurityNetworkGraph(network)
        else
            self:drawSecurityCreateSystemBanner()
        end

        self:drawSecurityIssues(network)

        ImGui.Dummy(0, 4 * style.viewSize)

        local _, availableY = ImGui.GetContentRegionAvail()
        local footerHeight = ImGui.GetFrameHeightWithSpacing() + 14 * style.viewSize

        self:drawSecuritySelectionPanel(math.max(0, availableY - footerHeight), network)

        ImGui.Separator()
        if ImGui.Button("Close##securitySetupPopupClose") then
            ImGui.CloseCurrentPopup()
        end

        ImGui.EndPopup()
    end
end

return quickSecuritySetupUI
