local spawnable = require("modules/classes/spawn/spawnable")
local entity = setmetatable({}, { __index = spawnable })

function entity:new()
	local o = spawnable.new(self)

    o.boxColor = {255, 255, 0}
    o.spawnListType = "list"
    o.dataType = "entity"

    setmetatable(o, { __index = self })
   	return o
end

function entity:despawn()

end

function entity:updatePosition()

end

function entity:drawUI()
    -- Copy path / recordID
end

return entity