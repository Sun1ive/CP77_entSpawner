local CPS = require("CPStyling")
local utils = require("modules/utils/utils")
local object = require("modules/classes/spawn/object")
local group = require("modules/classes/spawn/group")

spawnedUI = {
    elements = {},
    filter = "",
    newGroupName = "New Group",
    groups = {},
    spawner = nil
}

function spawnedUI.init(spawner)
    spawnedUI.spawner = spawner
end

function spawnedUI.loadFile(path)

end

function spawnedUI.spawnNewObject(path, parent)
    local new = object:new(spawnedUI)
    new.path = path
    new.name = path
    new.rot = GetSingleton('Quaternion'):ToEulerAngles(Game.GetPlayer():GetWorldOrientation())
    new.pos = Game.GetPlayer():GetWorldPosition()
    new.parent = parent

    if parent ~= nil then
        table.insert(new.parent.childs, new)
    end

    if spawnedUI.spawner.settings.spawnPos == 2 then
        local vec = Game.GetPlayer():GetWorldForward()
        new.pos.x = new.pos.x + vec.x * spawnedUI.spawner.settings.spawnDist
        new.pos.y = new.pos.y + vec.y * spawnedUI.spawner.settings.spawnDist
    end

    new:generateName()
    new:spawn()
    table.insert(spawnedUI.elements, new)

    return new
end

function spawnedUI.getGroups()
    spawnedUI.groups = {}
    spawnedUI.groups[1] = {name = "-- No group --"}
    for _, f in pairs(spawnedUI.elements) do
        if f.type == "group" then
            if f.parent == nil then
                local ps = f:getPath()
                for _, p in pairs(ps) do
                    table.insert(spawnedUI.groups, p)
                end
            end
        end
    end
end

function spawnedUI.draw(spawner)
    if spawnedUI.spawer == nil then spawnedUI.init(spawner) end

    spawnedUI.getGroups()

    ImGui.PushItemWidth(250)
    spawnedUI.filter = ImGui.InputTextWithHint('##Filter', 'Search for object...', spawnedUI.filter, 100)
    ImGui.PopItemWidth()

    if spawnedUI.filter ~= '' then
        ImGui.SameLine()
        if ImGui.Button('X') then
            spawnedUI.filter = ''
        end
    end

    ImGui.PushItemWidth(250)
    spawnedUI.newGroupName = ImGui.InputTextWithHint('##newG', 'New group name...', spawnedUI.newGroupName, 100)
    ImGui.PopItemWidth()

    ImGui.SameLine()
    if ImGui.Button("Add group") then
        local g = group:new(spawnedUI)
        g.name =utils.createFileName(spawnedUI.newGroupName)
        table.insert(spawnedUI.elements, g)
    end
    ImGui.Separator()

    for _, f in pairs(spawnedUI.elements) do
        if spawnedUI.filter == "" then
            f:tryMainDraw()
        else
            if (f.name:lower():match(spawnedUI.filter:lower())) ~= nil then
                if f.type == "object" then
                    if f.parent ~= nil then
                        ImGui.Unindent(35)
                    end
                    f:draw()
                    if f.parent ~= nil then
                        ImGui.Indent(35)
                    end
                end
            end
        end
    end
end

function spawnedUI.despawnAll()
    for _, e in pairs(spawnedUI.elements) do
        e:despawn()
    end
end

return spawnedUI