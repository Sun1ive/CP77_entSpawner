local config = require("modules/utils/core/config")
local utils = require("modules/utils/core/utils")

---Synced-workspot pairs: which .workspot completes a given one, and where its spot goes.
---Data comes from data/static/workspot_sync.json, see script/extract_workspot_sync.wscript.
local workspotSync = {}

local storePath = "data/static/workspot_sync.json"
local store = {}
local storeLoaded = false

local function normalizePath(path)
    return utils.normalizePath(path, {
        separator = "backslash",
        lowercase = true,
        emptyAsNil = true
    })
end

local function isOffset(offset)
    return type(offset) == "table" and #offset >= 4
        and type(offset[1]) == "number" and type(offset[2]) == "number"
        and type(offset[3]) == "number" and type(offset[4]) == "number"
end

local function loadStore()
    if storeLoaded then return end
    storeLoaded = true

    local data = config.loadFile(storePath)
    if type(data) ~= "table" or type(data.workspots) ~= "table" then return end

    for path, entry in pairs(data.workspots) do
        local key = normalizePath(path)
        if key and type(entry) == "table" and type(entry.partners) == "table" then
            local partners = {}

            for _, partner in ipairs(entry.partners) do
                local arrangements = {}

                for _, arrangement in ipairs(partner.arrangements or {}) do
                    if isOffset(arrangement.o) then
                        table.insert(arrangements, {
                            offset = arrangement.o,
                            slots = arrangement.slots or {},
                            source = arrangement.src or "authored",
                            vanilla = arrangement.n or 0
                        })
                    end
                end

                if type(partner.path) == "string" and #arrangements > 0 then
                    local master = type(partner.master) == "table" and partner.master or {}

                    table.insert(partners, {
                        path = partner.path,
                        vanilla = partner.vanilla or 0,
                        -- How often each half of the pair led in shipped placements.
                        masterSelf = master[1] or 0,
                        masterPartner = master[2] or 0,
                        arrangements = arrangements
                    })
                end
            end

            if #partners > 0 then
                store[key] = { path = entry.path or path, partners = partners }
            end
        end
    end
end

---Complementary workspots for a synced workspot, best-documented pair first.
---@param workspotPath string
---@return { path: string, vanilla: integer, masterSelf: integer, masterPartner: integer, arrangements: { offset: number[], slots: string[], source: string, vanilla: integer }[] }[]
function workspotSync.getPartners(workspotPath)
    loadStore()

    local key = normalizePath(workspotPath)
    local entry = key and store[key]

    return entry and entry.partners or {}
end

---@param workspotPath string
---@return boolean
function workspotSync.isSynced(workspotPath)
    return #workspotSync.getPartners(workspotPath) > 0
end

---Places the complementary spot: the offset is the partner's transform in this spot's local frame.
---@param position vec4Like|Vector4
---@param rotation eulerLike|EulerAngles
---@param offset number[] {x, y, z, yaw}, yaw in degrees
---@return vec4Like position
---@return eulerLike rotation
function workspotSync.getPartnerTransform(position, rotation, offset)
    local euler = EulerAngles.new(rotation.roll, rotation.pitch, rotation.yaw)
    local world = euler:ToQuat():Transform(Vector4.new(offset[1], offset[2], offset[3], 0))
    local rotated = utils.addEulerRelative(euler, { roll = 0, pitch = 0, yaw = offset[4] })

    return
        { x = position.x + world.x, y = position.y + world.y, z = position.z + world.z, w = 0 },
        { roll = rotated.roll, pitch = rotated.pitch, yaw = rotated.yaw }
end

---Which half of the pair the shipped game points the other at. Nothing in the workspot says it, so
---this is only the majority of what was measured, and `false` when nothing was measured at all.
---@param partner { masterSelf: integer, masterPartner: integer }
---@return boolean selfLeads True when the spot owning this partner entry is the master.
---@return integer observed Shipped couples backing the answer, 0 when it is only the default.
function workspotSync.doesSelfLead(partner)
    local selfCount = partner.masterSelf or 0
    local partnerCount = partner.masterPartner or 0

    if selfCount == 0 and partnerCount == 0 then
        return true, 0
    end

    if selfCount >= partnerCount then
        return true, selfCount
    end

    return false, partnerCount
end

---Short label for an arrangement: the tail of its slot name, e.g. "dancing 01" out of
---"synced__stand_chilling_with_phone__01__dancing__01".
---@param arrangement { slots: string[], source: string, vanilla: integer }
---@param index integer Position in the arrangement list, used when there is no slot to name it by.
---@return string
function workspotSync.getArrangementLabel(arrangement, index)
    local slot = arrangement.slots and arrangement.slots[1]

    if type(slot) == "string" and slot ~= "" then
        local parts = {}
        for part in (slot .. "__"):gmatch("(.-)__") do
            if part ~= "" then
                table.insert(parts, part)
            end
        end

        if #parts >= 2 then
            return parts[#parts - 1] .. " " .. parts[#parts]
        end

        return slot
    end

    if arrangement.source == "measured" then
        return "As shipped"
    end

    return string.format("Arrangement %d", index)
end

return workspotSync
