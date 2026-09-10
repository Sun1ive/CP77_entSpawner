local utils = require("modules/utils/core/utils")

local redValue = {}

---@param value any
---@param defaultValue any?
---@return number
function redValue.boolToInt(value, defaultValue)
    if value == nil then
        value = defaultValue
    end

    return (value == true or value == 1) and 1 or 0
end

---@param value any
---@return boolean
function redValue.readBool(value)
    return value == 1 or value == true
end

---@param value any
---@param options table?
---@return string
local function normalizeText(value, options)
    local opts = options or {}

    if opts.sanitize then
        return utils.sanitizeText(value)
    end

    return tostring(value or "")
end

---@param typeName string
---@param value any
---@param options table?
---@return table
local function wrappedValue(typeName, value, options)
    local opts = options or {}

    return {
        ["$type"] = typeName,
        ["$storage"] = opts.storage or "string",
        ["$value"] = value
    }
end

---@param value string?
---@param options table? `{ sanitize: boolean?, emptyAsNone: boolean? }`
---@return table
function redValue.cName(value, options)
    local opts = options or {}
    local text = normalizeText(value, opts)

    if opts.emptyAsNone and text == "" then
        text = "None"
    end

    return wrappedValue("CName", text, opts)
end

---@param data any
---@param options table? `{ emptyValues: table<string, boolean>? }`
---@return string
function redValue.readCName(data, options)
    if type(data) ~= "table" then
        return ""
    end

    local value = tostring(data["$value"] or "")
    local emptyValues = options and options.emptyValues or { None = true }

    return emptyValues[value] and "" or value
end

---@param value string?
---@param options table? `{ sanitize: boolean?, emptyAsZero: boolean? }`
---@return table
function redValue.tweakDBID(value, options)
    local opts = options or {}
    local text = normalizeText(value, opts)

    if opts.emptyAsZero and (text == "" or text == "None") then
        return wrappedValue("TweakDBID", "0", { storage = "uint64" })
    end

    return wrappedValue("TweakDBID", text, opts)
end

---@param data any
---@param options table? `{ emptyValues: table<string, boolean>? }`
---@return string
function redValue.readTweakDBID(data, options)
    if type(data) ~= "table" then
        return ""
    end

    local value = tostring(data["$value"] or "")
    local emptyValues = options and options.emptyValues or { None = true, ["0"] = true }

    return emptyValues[value] and "" or value
end

---@param value string?
---@param options table?
---@return table
function redValue.nodeRef(value, options)
    return wrappedValue("NodeRef", normalizeText(value, options), options)
end

---@param data any
---@return string
function redValue.readRawValue(data)
    if type(data) ~= "table" then
        return ""
    end

    return tostring(data["$value"] or "")
end

---@param x number?
---@param y number?
---@param z number?
---@return table
function redValue.vector3(x, y, z)
    return { ["$type"] = "Vector3", X = x or 0, Y = y or 0, Z = z or 0 }
end

return redValue
