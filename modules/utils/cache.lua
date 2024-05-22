local config = require("modules/utils/config")

local data = {}
local cache = {}

function cache.load()
    config.tryCreateConfig("data/cache.json", {})
    data = config.loadFile("data/cache.json")
end

function cache.addValue(key, value)
    data[key] = value
    config.saveFile("data/cache.json", data)
end

function cache.getValue(key)
    return nil
end

function cache.generateRecordsList()
    if config.fileExists("data/spawnables/entity/records/records.txt") then return end

    local records = {
        "gamedataAttachableObject_Record",
        "gamedataCarriableObject_Record",
        "gamedataCharacter_Record",
        "gamedataProp_Record",
        "gamedataSpawnableObject_Record",
        "gamedataSubCharacter_Record",
        "gamedataVehicle_Record",
    }

    local file = io.open("data/spawnables/entity/records/records.txt", "w")

    for _, record in pairs(records) do
        for _, entry in pairs(TweakDB:GetRecords(record)) do
            file:write(entry:GetID().value .. "\n")
        end
    end

    file:close()
end

return cache