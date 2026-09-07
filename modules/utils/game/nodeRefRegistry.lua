local utils = require("modules/utils/core/utils")
local settings = require("modules/utils/core/settings")
local style = require("modules/ui/style")
local history = require("modules/utils/project/history")

---@class nodeRefRegistryEntry
---@field ref string Full NodeRef string (for example `$/mod/group/#root_name`).
---@field path string Hierarchy path of the owning spawned UI entry.
---@field duplicate boolean True when the same NodeRef exists on multiple entries under the same root.
---@field spawnable spawnable? Spawnable owning this NodeRef (first seen in case of duplicates).

---@class nodeRefRegistry
---@field spawnedUI spawnedUI? Cached reference to the spawned hierarchy used for indexing.
---@field refs table<string, table<string, nodeRefRegistryEntry>> Indexed as `refs[rootName][nodeRef]`.
---@field dirty boolean Whether `refs` must be rebuilt before use.
local registry = {
    spawnedUI = nil,
    refs = {},
    dirty = true
}

---@param candidateHash string
---@param normalizedHash string
---@param rawNumber number?
---@return boolean
local function hashMatches(candidateHash, normalizedHash, rawNumber)
    if candidateHash == normalizedHash then
        return true
    end

    return rawNumber ~= nil and tonumber(candidateHash) == rawNumber
end

---Bind the registry to the active spawned UI tree.
---This should be called once after the main spawner UI is initialized.
---@param spawner spawner Root spawner object containing `baseUI.spawnedUI`.
function registry.init(spawner)
    registry.spawnedUI = spawner.baseUI.spawnedUI
    registry.dirty = true
end

---Mark cached NodeRef index data as outdated.
---Call this whenever an entry's NodeRef, name, parent, or path can change.
function registry.invalidate()
    registry.dirty = true
end

---Rebuild `refs` from the current spawned hierarchy if needed.
---No-op when the registry is clean or the spawned UI is not initialized yet.
function registry.update()
    if not registry.spawnedUI then
        return
    end

    if not registry.dirty then
        return
    end

    registry.refs = {}

    for _, node in pairs(registry.spawnedUI.paths) do
        if utils.isA(node.ref, "spawnableElement") and node.ref.spawnable.nodeRef ~= "" then
            local root = node.ref:getRootParent()

            if not registry.refs[root.name] then
                registry.refs[root.name] = {}
            end
            if registry.refs[root.name][node.ref.spawnable.nodeRef] then
                registry.refs[root.name][node.ref.spawnable.nodeRef].duplicate = true
            else
                registry.refs[root.name][node.ref.spawnable.nodeRef] = {
                    ref = node.ref.spawnable.nodeRef,
                    path = node.path,
                    duplicate = false,
                    spawnable = node.ref.spawnable
                }
            end
        end
    end

    registry.dirty = false
end

---Resolve a spawnable by NodeRef in the same root group as `object`.
---@param object positionable
---@param ref string
---@return spawnable?
function registry.getSpawnableByNodeRef(object, ref)
    if not object or not object.getRootParent then
        return nil
    end

    if not ref or ref == "" then
        return nil
    end

    registry.update()

    local root = object:getRootParent()
    if not root or not root.name then
        return nil
    end

    local rootRefs = registry.refs[root.name]
    local entry = rootRefs and rootRefs[ref]
    return entry and entry.spawnable or nil
end

---Resolve a hash-like NodeRef value to a readable NodeRef string under the same root.
---If `ref` is already textual (contains non-digits), it is returned unchanged.
---@param object positionable?
---@param ref string?
---@return string
function registry.resolveDisplayRef(object, ref)
    local raw = utils.trimString(ref)
    if raw == "" then
        return raw
    end

    local rawNumber = tonumber(raw)
    local normalizedHash = raw
    if rawNumber then
        normalizedHash = string.format("%.0f", rawNumber)
    elseif raw:find("%D") then
        return raw
    end

    if not object or not object.getRootParent then
        return raw
    end

    registry.update()

    local root = object:getRootParent()
    if not root then
        return raw
    end

    local rootRefs = root.name and registry.refs[root.name] or nil
    if rootRefs then
        for nodeRef, _ in pairs(rootRefs) do
            local candidateHash = utils.nodeRefStringToHashString(nodeRef)
            if hashMatches(candidateHash, normalizedHash, rawNumber) then
                return nodeRef
            end
        end
    end

    if root.getPathsRecursive then
        for _, path in ipairs(root:getPathsRecursive(true) or {}) do
            local pathRef = path and path.ref or nil
            if utils.isA(pathRef, "spawnableElement") and pathRef.spawnable then
                local candidate = utils.trimString(pathRef.spawnable.nodeRef)
                if candidate ~= "" then
                    local candidateHash = utils.nodeRefStringToHashString(candidate)
                    if hashMatches(candidateHash, normalizedHash, rawNumber) then
                        return candidate
                    end
                end
            end
        end
    end

    return raw
end

---Generate a unique NodeRef for one object under its root group.
---Format: `$/<settings.nodeRefPrefix>/<parent>/#<root>_<name>` (prefix omitted when empty).
---When a collision exists in the same root group, a copy suffix is appended until unique.
---@param object positionable Object owning the NodeRef (must provide `name`, `parent`, and `getRootParent()`).
---@return string generated Unique NodeRef candidate.
function registry.generate(object)
    registry.update()

    local generated = "$/"
    if #settings.nodeRefPrefix > 0 then
        generated = generated .. settings.nodeRefPrefix .. "/"
    end
    local rootName = object:getRootParent().name
    local parent = utils.createFileName(string.lower(object.parent.name))
    local root = utils.createFileName(string.lower(rootName))
    local name = utils.createFileName(string.lower(object.name))

    generated = generated .. parent .. "/#" .. root .. "_" .. name

    while registry.refs[rootName] and registry.refs[rootName][generated] do
        generated = utils.generateCopyName(generated)
    end

    return generated
end

---@param query string
---@param candidate string
---@return boolean
local function nodeRefMatchesSearch(query, candidate)
    if query == "" or query == "0" then
        return true
    end

    local ok, matched = pcall(string.match, candidate, query)

    return ok and matched ~= nil
end

---Draw a combo-based NodeRef picker with inline text search/filter.
---Search uses Lua pattern matching (`string.match`) against indexed refs.
---Special case: entering `"0"` shows all refs from the current root group.
---@param width number Control width in unscaled style units (`style.viewSize` is applied internally).
---@param ref string Current NodeRef value and search text.
---@param object positionable Context object used for root scoping and self-ref exclusion.
---@param record boolean? When true, push a history action before user-driven changes (selection/clear).
---@param excluded table<string, boolean>|table? Refs hidden from the list, or selector options.
---@return string ref Updated NodeRef/search value.
---@return boolean finished True when user commits a value (selects, clears, or finishes text edit).
function registry.drawNodeRefSelector(width, ref, object, record, excluded)
    local finished = false
    ref = registry.resolveDisplayRef(object, ref)
    local selectorOptions = {}

    if type(excluded) == "table" and (
        excluded.excluded ~= nil
        or excluded.filter ~= nil
        or excluded.modulePath ~= nil
        or excluded.allowCustom ~= nil
        or excluded.hint ~= nil
        or excluded.id ~= nil
        or excluded.emptyListText ~= nil
        or excluded.tooltip ~= nil
        or excluded.optionDisplayFn ~= nil
        or excluded.optionTooltipFn ~= nil
        or excluded.optionAnnotationFn ~= nil
    ) then
        selectorOptions = excluded
        excluded = selectorOptions.excluded or {}
    else
        excluded = excluded or {}
    end

    local pickerId = selectorOptions.id or "##nodeRefSelector"
    local searchId = selectorOptions.searchId or (pickerId .. "Search")
    local listId = selectorOptions.listId or (pickerId .. "List")
    local hint = selectorOptions.hint or "$/#foobar"
    local listHeight = tonumber(selectorOptions.listHeight) or 100
    local allowCustom = selectorOptions.allowCustom ~= false

    ImGui.SetNextItemWidth(width * style.viewSize)
    if (ImGui.BeginCombo(pickerId, ref)) then
        local interiorWidth = width - (2 * ImGui.GetStyle().FramePadding.x) - 30
        local textFieldFinished
        ref, _, textFieldFinished = style.trackedTextField(object, searchId, ref, hint, interiorWidth)
        local x, _ = ImGui.GetItemRectSize()

        ImGui.SameLine()
        style.pushButtonNoBG(true)
        if ImGui.Button(IconGlyphs.Close) then
            if record then
                history.addAction(history.getElementChange(object))
            end
            ref = ""
            finished = true
        end
        style.pushButtonNoBG(false)

        local entryHovered = false
        local xButton, _ = ImGui.GetItemRectSize()
        if ImGui.BeginChild(listId, x + xButton + ImGui.GetStyle().ItemSpacing.x, listHeight * style.viewSize) then
            local root = object and object.getRootParent and object:getRootParent() or nil
            local ownRef = object and object.spawnable and object.spawnable.nodeRef or nil
            local nodes = {}

            for _, node in pairs(root and registry.refs[root.name] or {}) do
                local keep = node.ref ~= ownRef and not excluded[node.ref]

                if keep and selectorOptions.modulePath then
                    keep = node.spawnable and node.spawnable.modulePath == selectorOptions.modulePath
                end

                if keep and selectorOptions.filter then
                    keep = selectorOptions.filter(node.spawnable, node.ref, node) == true
                end

                if keep and nodeRefMatchesSearch(ref, node.ref) then
                    table.insert(nodes, node)
                end
            end

            table.sort(nodes, function (left, right)
                return tostring(left.ref) < tostring(right.ref)
            end)

            local rowWidth = ((width - 2 * ImGui.GetStyle().FramePadding.x) * style.viewSize)
                - (ImGui.GetScrollMaxY() > 0 and ImGui.GetStyle().ScrollbarSize or 0)

            for _, node in ipairs(nodes) do
                local label = selectorOptions.optionDisplayFn and selectorOptions.optionDisplayFn(node.ref, node) or nil
                label = label or utils.shortenPath(node.ref, rowWidth, false)

                if ImGui.Selectable(label, false) then
                    if record then
                        history.addAction(history.getElementChange(object))
                    end
                    ref = node.ref
                    finished = true
                    ImGui.CloseCurrentPopup()
                end

                if selectorOptions.optionAnnotationFn then
                    local annotation = selectorOptions.optionAnnotationFn(node.ref, node)
                    if annotation and annotation ~= "" then
                        ImGui.SameLine()
                        style.mutedText(annotation)
                    end
                end

                if selectorOptions.optionTooltipFn then
                    local tooltip = selectorOptions.optionTooltipFn(node.ref, node)
                    if tooltip and tooltip ~= "" then
                        style.tooltip(tooltip)
                    end
                end

                entryHovered = entryHovered or ImGui.IsItemHovered()
            end

            if #nodes == 0 and selectorOptions.emptyListText then
                style.mutedText(selectorOptions.emptyListText)
            end

            ImGui.EndChild()
        end

        ImGui.EndCombo()

        -- Make sure that if text input is used as search, and entry is clicked, that we do not count the finish event from text input, but wait for the selectable to be clicked on the next frame
        if entryHovered and textFieldFinished then
            finished = false
        else
            finished = finished or (allowCustom and textFieldFinished)
        end
    end

    if selectorOptions.tooltip then
        style.tooltip(selectorOptions.tooltip)
    end

    return ref, finished
end

return registry
