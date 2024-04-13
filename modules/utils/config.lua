config = {}

function config.fileExists(filename)
    local f=io.open(filename,"r")
    if (f~=nil) then io.close(f) return true else return false end
end

function config.tryCreateConfig(path, data)
	if not config.fileExists(path) then
        local file = io.open(path, "w")
        local jconfig = json.encode(data)
        file:write(jconfig)
        file:close()
    end
end

function config.loadFile(path)
    local file = io.open(path, "r")
    local config = json.decode(file:read("*a"))
    file:close()
    return config
end

function config.saveFile(path, data)
    local file = io.open(path, "w")
    local jconfig = json.encode(data)
    file:write(jconfig)
    file:close()
end

function config.loadPaths(path)
    local paths = {}
    file = io.open(path)
    for line in file:lines() do

        local n = line
        if string.find(n, "\\") then
            n = n:match("\\[^\\]*$") -- Everything after last \
        end
        n = n:gsub(".ent", ""):gsub("\\", "_") -- Remove .ent, replace \ by _
        n = n:sub(2)

    for _, file in pairs(dir(path)) do
        if file.name:match("^.+(%..+)$") == ".txt" then
            local data = config.loadFile(path .. file.name)

    end
    file:close()
    return paths
end

function config.backwardComp(path, data)
    local f = config.loadFile(path)

    for k, e in pairs(data) do
        if f[k] == nil then
            f[k] = e
        end
    end

    config.saveFile(path, f)
end

return config