local entity = require("modules/classes/spawn/entity/entity")

---Class for AMM imported props, just here for the different spawnDataPath
local amm = setmetatable({}, { __index = entity })

function amm:new()
	local o = entity.new(self)

    o.dataType = "Entity Template (AMM)"
    o.spawnDataPath = "data/spawnables/entity/amm/"
    o.spawnListType = "files"

    o.modulePath = "entity/ammEntity"

    setmetatable(o, { __index = self })
   	return o
end

return amm