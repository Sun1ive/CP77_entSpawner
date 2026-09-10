-- TEMPORARY DIAGNOSTIC - delete with its Debug-section button once the question is answered.
--
-- Question: can a shipped placeholder worldSplineNode be given new splineData at runtime, and
-- does the native spline query then see it?
--
-- The RedHotTools lookup and the AIScriptUtils query are INDEPENDENT paths to the same node, so
-- neither gates the other: RHT is how we reach the definition to write it, AIScriptUtils is the
-- game's own resolution and the only thing that says whether the AI can see the spline at all.
-- Writes every step to wb_spline_probe.log in the mod folder.
--
-- CET runs LuaJIT: 5.1 syntax only, no `~` / `//` / integer literals wider than a double.
-- Hashing goes through CET's own FNV1a64 global, same as modules/utils/core/utils.lua.

local logger = require("modules/utils/core/logger")
local settings = require("modules/utils/core/settings")
local builder = require("modules/utils/game/entityBuilder")
local utils = require("modules/utils/core/utils")

local probe = {}

-- Entity id of the NPC the command test spawned, so a re-run replaces it rather than littering.
probe.testNpcID = nil

local REF = "$/mods/entSpawner/preview_placeholder/#wb_preview_spline_0"
-- Node transform baked into world_builder\sectors\wb_-_preview_placeholders.streamingsector.
-- Spline points are node-local, so local = world - ORIGIN.
local ORIGIN = { x = 1062.79944, y = 1488.93982, z = 218.655472 }
-- Local position of the 2-point spline baked into every placeholder node. The "before" query
-- landing here is the control: it proves the native query resolves these nodes at all.
local BAKED = { x = 0.903808594, y = 3.29101562, z = 0 }
local LOG_PATH = "wb_spline_probe.log"

-- Precomputed off-line so the log can be read without a calculator.
local EXPECTED_WITH_HASH = "11530035107852353291"
local EXPECTED_WITHOUT_HASH = "15579343823052436502"

local lines = {}

local function out(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end

    local line = table.concat(parts, "  ")
    lines[#lines + 1] = line
    print("[splineProbe] " .. line)
end

---pcall wrapper that records the failure instead of aborting, so one pass reports every broken
---assumption rather than only the first.
local function try(label, fn)
    local ok, a, b = pcall(fn)
    if not ok then
        out("FAIL  " .. label .. "  ->  " .. tostring(a))
        return nil
    end
    return a, b
end

local function describe(value)
    if value == nil then return "nil" end

    local className = nil
    pcall(function() className = value:GetClassName().value end)

    if className then
        return tostring(value) .. " <" .. className .. ">"
    end

    return tostring(value)
end

local function vecString(v)
    if not v then return "nil" end
    return string.format("%.3f %.3f %.3f", v.x or 0, v.y or 0, v.z or 0)
end

local function hashString(value)
    if value == nil then return "nil" end
    local text, _ = tostring(value):gsub("ULL", "")
    return text
end

---Reads one entry of a SplinePoint's fixed-size `tangents` array. The Lua index base for a
---CArrayFixedSize is not documented, so try both and report which one answered.
---@param point userdata SplinePoint
---@param slot number 1 = tangentIn, 2 = tangentOut
---@return table? value
---@return string base
local function readTangent(point, slot)
    local value, base = nil, "none"

    pcall(function()
        local array = point.tangents
        if array == nil then return end

        local oneBased = array[slot]
        if oneBased ~= nil and oneBased.x ~= nil then
            value, base = oneBased, "1-based"
            return
        end

        local zeroBased = array[slot - 1]
        if zeroBased ~= nil and zeroBased.x ~= nil then
            value, base = zeroBased, "0-based"
        end
    end)

    return value, base
end

---Writes tangentIn/tangentOut onto a SplinePoint, trying each assignment shape and verifying by
---read-back. A silent no-op here is what made the first run walk straight lines.
---@return string strategy Which shape stuck, or "FAILED".
local function writeTangents(point, tangentIn, tangentOut)
    local inVec = Vector3.new(tangentIn.x or 0, tangentIn.y or 0, tangentIn.z or 0)
    local outVec = Vector3.new(tangentOut.x or 0, tangentOut.y or 0, tangentOut.z or 0)

    local function stuck()
        local readIn = readTangent(point, 1)
        local readOut = readTangent(point, 2)
        if not readIn or not readOut then return false end

        return math.abs(readIn.x - inVec.x) < 0.0001
            and math.abs(readIn.y - inVec.y) < 0.0001
            and math.abs(readOut.x - outVec.x) < 0.0001
            and math.abs(readOut.y - outVec.y) < 0.0001
    end

    local strategies = {
        { label = "table assign", apply = function()
            point.tangents = { inVec, outVec }
        end },
        { label = "element 1..2", apply = function()
            local array = point.tangents
            array[1] = inVec
            array[2] = outVec
            point.tangents = array
        end },
        { label = "element 0..1", apply = function()
            local array = point.tangents
            array[0] = inVec
            array[1] = outVec
            point.tangents = array
        end },
    }

    for i = 1, #strategies do
        local applied = pcall(strategies[i].apply)
        if applied and stuck() then
            return strategies[i].label
        end
    end

    return "FAILED"
end

---The point defs the exporter would serialise: live marker data first, then the saved copy, then
---bare positions. Mirrors `spline:save()` / `spline:export()` so the preview and the exported node
---describe the same curve - including `automaticTangents`, which must stay as authored.
local function exportStylePointDefs(sp)
    local defs = sp:getSplineMarkerDefs()

    if #defs == 0 and sp.pointDefs and #sp.pointDefs > 0 then
        defs = utils.deepcopy(sp.pointDefs)
    end

    if #defs == 0 and sp.points and #sp.points > 0 then
        for i = 1, #sp.points do
            defs[#defs + 1] = {
                position = sp.points[i],
                tangentIn = { x = 0, y = 0, z = 0 },
                tangentOut = { x = 0, y = 0, z = 0 },
                automaticTangents = true
            }
        end
    end

    return defs
end

local function flush()
    local file = io.open(LOG_PATH, "w")
    if not file then
        logger.error("Spline probe could not write " .. LOG_PATH)
        return false
    end

    file:write(table.concat(lines, "\n") .. "\n")
    file:close()
    return true
end

---@return boolean written
---@return number count
function probe.run()
    lines = {}

    out("==== WB spline node probe ====")
    out("ref =", REF)

    -- ------------------------------------------------------------ 1. bindings
    out("---- step 1: bindings ----")
    local hasUtils = try("AIScriptUtils global", function()
        return AIScriptUtils ~= nil and AIScriptUtils.GetStartPointOfSpline ~= nil
    end)
    out("AIScriptUtils.GetStartPointOfSpline reachable =", hasUtils)

    local inspector = try("Game.GetWorldInspector()", function() return Game.GetWorldInspector() end)
    out("WorldInspector =", describe(inspector))

    -- -------------------------------------------------------------- 2. resolve
    out("---- step 2: resolve ----")
    local nodeRef = try("CreateEntityReference", function()
        return CreateEntityReference(REF, {}).reference
    end)
    local globalRef = try("ResolveNodeRef", function()
        return ResolveNodeRef(nodeRef, GlobalNodeID.GetRoot())
    end)

    local strippedRef, _ = REF:gsub("#", "")
    local hashWith = try("FNV1a64 with #", function() return FNV1a64(REF) end)
    local hashWithout = try("FNV1a64 without #", function() return FNV1a64(strippedRef) end)

    out("nodeRef        =", describe(nodeRef))
    out("globalRef.hash =", hashString(globalRef and globalRef.hash))
    out("fnv1a64 with '#'    =", hashString(hashWith), " expected", EXPECTED_WITH_HASH)
    out("fnv1a64 without '#' =", hashString(hashWithout), " expected", EXPECTED_WITHOUT_HASH)

    -- ------------------------------- 3. RHT lookup, both hash forms, non-fatal
    out("---- step 3: RedHotTools lookup (informational) ----")
    local definition = nil

    if inspector then
        local candidates = {
            { label = "resolved globalRef.hash", value = globalRef and globalRef.hash },
            { label = "fnv1a64 without '#'", value = hashWithout },
            { label = "fnv1a64 with '#'", value = hashWith },
        }

        for i = 1, #candidates do
            local candidate = candidates[i]
            if candidate.value ~= nil then
                local streamed = try("FindStreamedNode " .. candidate.label, function()
                    return inspector:FindStreamedNode(candidate.value)
                end)
                local instance = streamed and streamed.nodeInstance
                local found = streamed and streamed.nodeDefinition
                out(candidate.label, "->  instance =", describe(instance), " definition =", describe(found))

                if found and not definition then
                    definition = found
                    out("  ^ using this one for the write")
                end
            end
        end
    else
        out("RedHotTools not loaded, skipping")
    end

    if definition then
        out("class =", try("GetClassName", function() return definition:GetClassName().value end))
        out("splineData (before) =", describe(definition.splineData))
        out("point count (before) =", try("count", function() return #definition.splineData.points end))
    else
        out("no definition reachable -> the write step will be skipped, but the query below")
        out("still tells us whether the game itself can see this spline.")
    end

    -- ----------------- 4. the game's own query, ALWAYS, independent of RHT
    -- CET auto-fills the leading GameInstance and turns `out` params into extra return values,
    -- so the Lua arity is not the redscript one: the game reported "requires 1 parameter(s)".
    -- Shapes are tried shortest-first and the winner is logged.
    local function callNative(name, attempts)
        if not hasUtils then
            out(name, "skipped, AIScriptUtils unreachable")
            return nil, nil
        end

        for i = 1, #attempts do
            local attempt = attempts[i]
            local ok, value = try(name .. " " .. attempt.label, attempt.call)

            if ok ~= nil then
                out("  arity that worked:", attempt.label)
                return ok, value
            end
        end

        return nil, nil
    end

    local function queryStart(tag)
        local ok, point = callNative("GetStartPointOfSpline", {
            { label = "(ref)", call = function()
                return AIScriptUtils.GetStartPointOfSpline(nodeRef)
            end },
            { label = "(game, ref)", call = function()
                return AIScriptUtils.GetStartPointOfSpline(GetGameInstance(), nodeRef)
            end },
            { label = "(ref, out)", call = function()
                return AIScriptUtils.GetStartPointOfSpline(nodeRef, Vector4.new(0, 0, 0, 1))
            end },
        })

        out(tag, "ok =", ok, " start =", vecString(point))
        return ok, point
    end

    out("---- step 4: native query BEFORE write ----")
    out("expecting baked start ~", vecString({
        x = ORIGIN.x + BAKED.x, y = ORIGIN.y + BAKED.y, z = ORIGIN.z + BAKED.z
    }))
    local beforeOk, beforePoint = queryStart("before:")

    -- ------------------------------------------------------- 5. build + write
    local afterPoint = nil

    if definition then
        out("---- step 5: build and assign splineData ----")

        local spline = try("NewObject handle:Spline", function() return NewObject("handle:Spline") end)
        if not spline then
            spline = try("NewObject Spline", function() return NewObject("Spline") end)
        end

        if spline then
            out("spline =", describe(spline))

            -- A 20 m straight run along +X, in node-local space.
            local points = {}
            for i = 1, 5 do
                local point = try("NewObject SplinePoint " .. i, function() return NewObject("SplinePoint") end)
                if not point then break end

                try("set point " .. i, function()
                    point.position = Vector3.new((i - 1) * 5, 0, 0)
                    point.automaticTangents = true
                    point.continuousTangents = true
                    point.id = i
                end)
                points[i] = point
            end

            if #points > 0 then
                try("assign points", function() spline.points = points end)
                try("assign flags", function()
                    spline.looped = false
                    spline.reversed = false
                    spline.hasDirection = true
                end)
                try("assign splineData", function() definition.splineData = spline end)
                out("splineData (after) =", describe(definition.splineData))
                out("point count (after) =", try("count after", function() return #definition.splineData.points end))
            else
                out("could not build any SplinePoint, skipping the write")
            end
        end

        out("---- step 6: native query AFTER write ----")
        local _, queried = queryStart("after: ")
        afterPoint = queried

        local okEnd, endPoint = callNative("GetEndPointOfSpline", {
            { label = "(ref)", call = function()
                return AIScriptUtils.GetEndPointOfSpline(nodeRef)
            end },
            { label = "(game, ref)", call = function()
                return AIScriptUtils.GetEndPointOfSpline(GetGameInstance(), nodeRef)
            end },
        })
        out("end:  ok =", okEnd, " end =", vecString(endPoint))
    else
        out("---- steps 5-6 skipped: no reachable node definition ----")
    end

    -- ------------------------------------------------------------- verdict
    out("---- verdict ----")
    out("baked start   ~", vecString({
        x = ORIGIN.x + BAKED.x, y = ORIGIN.y + BAKED.y, z = ORIGIN.z + BAKED.z
    }))
    out("written start ~", vecString(ORIGIN))

    local function near(point, x, y)
        return point ~= nil
            and math.abs((point.x or 0) - x) < 0.5
            and math.abs((point.y or 0) - y) < 0.5
    end

    if not beforeOk or not beforePoint then
        out("CONTROL FAILED: the game cannot read even the spline baked into the sector.")
        out("  Either the sector is not streaming, or the NodeRef hash the sector baked is not")
        out("  the one the game resolves from the ref string. Compare the hashes in step 2.")
    elseif near(beforePoint, ORIGIN.x + BAKED.x, ORIGIN.y + BAKED.y) then
        out("CONTROL PASSED: the game resolves this node and reads its baked spline.")
        if not definition then
            out("  But RedHotTools could not hand over the definition, so the write was untested.")
            out("  Need another route to the node object before the real question can be answered.")
        elseif near(afterPoint, ORIGIN.x, ORIGIN.y) then
            out("  PASS: the query now returns the runtime write. splineData is read live ->")
            out("        AIMoveOnSplineCommand is viable.")
        elseif near(afterPoint, ORIGIN.x + BAKED.x, ORIGIN.y + BAKED.y) then
            out("  FAIL (clean): the answer did not move after the write. The spline is snapshotted")
            out("        when the node attaches; only forcing a re-attach (an ASI) could drive it.")
        else
            out("  UNCLEAR: after =", vecString(afterPoint), " matches neither expectation.")
        end
    else
        out("UNCLEAR: the control returned", vecString(beforePoint), "which is neither the baked")
        out("  start nor a failure. Read the step 4 values by hand.")
    end

    local written = flush()
    return written, #lines
end

---Writes the geometry of the currently selected WB spline into placeholder node 0, then walks an
---NPC along it with a real AIMoveOnSplineCommand. Answers the two questions the read-only probe
---could not: does the movement follow a runtime-written spline, and does it still work when the
---spline sits far from the placeholder node's own origin.
---@param spawner table entSpawner root, for `spawner.baseUI.spawnedUI`.
---@return boolean written
---@return number count
function probe.runSplineCommand(spawner)
    lines = {}

    out("==== node 0 AIMoveOnSplineCommand test ====")

    -- --------------------------------------------------------- 1. selection
    local spawnedUI = spawner and spawner.baseUI and spawner.baseUI.spawnedUI
    if not spawnedUI then
        out("STOP: spawnedUI unavailable")
        flush()
        return true, #lines
    end

    try("ensureCache", function() spawnedUI.ensureCache() end)

    if #spawnedUI.selectedPaths ~= 1 then
        out("STOP: select exactly one spline in the Spawned hierarchy. Selected:", #spawnedUI.selectedPaths)
        flush()
        return true, #lines
    end

    local element = spawnedUI.selectedPaths[1].ref
    local sp = element and element.spawnable
    if not sp or not sp.isSplineNode then
        out("STOP: the selection is not a spline node.")
        flush()
        return true, #lines
    end

    out("selected =", element.name, " node =", tostring(sp.node))
    out("looped =", tostring(sp.looped), " reverse =", tostring(sp.reverse))

    local defs = try("exportStylePointDefs", function()
        return exportStylePointDefs(sp)
    end)
    if not defs or #defs < 2 then
        out("STOP: need at least 2 spline markers, got", defs and #defs or "nil")
        flush()
        return true, #lines
    end
    out("marker count =", #defs)

    local first = defs[1].position
    local last = defs[#defs].position
    out("first marker (world) =", vecString(first))
    out("last  marker (world) =", vecString(last))
    -- The whole point of this test: how far the real spline sits from the placeholder node.
    local offset = math.sqrt((first.x - ORIGIN.x) ^ 2 + (first.y - ORIGIN.y) ^ 2 + (first.z - ORIGIN.z) ^ 2)
    out("distance from placeholder origin =", string.format("%.1f m", offset))

    -- ---------------------------------------------------- 2. reach the node
    local nodeRef = try("CreateEntityReference", function()
        return CreateEntityReference(REF, {}).reference
    end)
    local globalRef = try("ResolveNodeRef", function()
        return ResolveNodeRef(nodeRef, GlobalNodeID.GetRoot())
    end)
    local inspector = try("GetWorldInspector", function() return Game.GetWorldInspector() end)
    local streamed = inspector and globalRef and try("FindStreamedNode", function()
        return inspector:FindStreamedNode(globalRef.hash)
    end)
    local definition = streamed and streamed.nodeDefinition

    if not definition then
        out("STOP: placeholder node 0 is not reachable. Did the game restart since the .xl changed?")
        flush()
        return true, #lines
    end
    out("node definition =", describe(definition))

    -- ------------------------------------- 3. write the real spline geometry
    local spline = try("NewObject handle:Spline", function() return NewObject("handle:Spline") end)
    if not spline then
        out("STOP: cannot construct a Spline")
        flush()
        return true, #lines
    end

    local points = {}
    for i = 1, #defs do
        local def = defs[i]
        local point = try("NewObject SplinePoint " .. i, function() return NewObject("SplinePoint") end)
        if not point then break end

        local tangentIn = def.tangentIn or { x = 0, y = 0, z = 0 }
        local tangentOut = def.tangentOut or { x = 0, y = 0, z = 0 }
        -- Same rule as the exporter: nil means automatic.
        local automatic = def.automaticTangents == nil and true or def.automaticTangents

        try("set point " .. i, function()
            -- Spline points are node-local, so subtract the placeholder node's world transform.
            -- (The exporter subtracts the spline's own position; here the placeholder is the host.)
            point.position = Vector3.new(
                def.position.x - ORIGIN.x,
                def.position.y - ORIGIN.y,
                def.position.z - ORIGIN.z)
            point.automaticTangents = automatic
            point.continuousTangents = def.continuousTangents == nil and true or def.continuousTangents
            point.id = i
        end)

        -- Exporter order: tangents[0] = tangentIn, tangents[1] = tangentOut.
        local strategy = writeTangents(point, tangentIn, tangentOut)
        local readIn, base = readTangent(point, 1)
        local readOut = readTangent(point, 2)
        out(string.format("  point %d  auto=%s  in=(%.3f %.3f %.3f) out=(%.3f %.3f %.3f)  write=%s %s",
            i, tostring(automatic),
            tangentIn.x or 0, tangentIn.y or 0, tangentIn.z or 0,
            tangentOut.x or 0, tangentOut.y or 0, tangentOut.z or 0,
            strategy, base))
        out(string.format("           read back  in=%s out=%s",
            readIn and vecString(readIn) or "nil",
            readOut and vecString(readOut) or "nil"))

        points[i] = point
    end
    out("built points =", #points)

    try("assign points", function() spline.points = points end)
    try("assign flags", function()
        spline.looped = sp.looped and true or false
        spline.reversed = sp.reverse and true or false
        spline.hasDirection = true
    end)
    try("assign splineData", function() definition.splineData = spline end)
    out("point count on node =", try("count", function() return #definition.splineData.points end))

    -- Assignment goes through two handles (point -> spline.points -> node.splineData), so confirm
    -- the tangents survived the trip rather than trusting the per-point read-back above.
    try("verify tangents on node", function()
        local stored = definition.splineData.points
        for i = 1, #stored do
            local readIn = readTangent(stored[i], 1)
            local readOut = readTangent(stored[i], 2)
            out(string.format("  on node %d  auto=%s  in=%s  out=%s",
                i, tostring(stored[i].automaticTangents),
                readIn and vecString(readIn) or "nil",
                readOut and vecString(readOut) or "nil"))
        end
    end)

    -- --------------------------------------------- 4. confirm via the query
    local okStart, startPoint = try("GetStartPointOfSpline", function()
        return AIScriptUtils.GetStartPointOfSpline(nodeRef)
    end)
    local okEnd, endPoint = try("GetEndPointOfSpline", function()
        return AIScriptUtils.GetEndPointOfSpline(nodeRef)
    end)
    out("query start ok =", okStart, " ", vecString(startPoint), " expected", vecString(first))
    out("query end   ok =", okEnd, " ", vecString(endPoint), " expected", vecString(last))

    local function near(a, b)
        return a and b and math.abs(a.x - b.x) < 0.5 and math.abs(a.y - b.y) < 0.5
    end
    if near(startPoint, first) and near(endPoint, last) then
        out("GEOMETRY OK: the node now describes the selected spline, at its real world location.")
    else
        out("GEOMETRY MISMATCH: the query does not agree with the markers. Movement below is moot.")
    end

    -- ------------------------------------------------- 5. spawn and command
    if probe.testNpcID then
        try("delete previous test NPC", function()
            Game.GetDynamicEntitySystem():DeleteEntity(probe.testNpcID)
        end)
        probe.testNpcID = nil
    end

    local character = sp.previewCharacter
    if not character or not tostring(character):match("^Character%.") then
        character = settings.defaultAISpotNPC or ""
    end
    out("character record =", tostring(character))
    if not tostring(character):match("^Character%.") then
        out("STOP: no valid Character record, cannot spawn a follower.")
        flush()
        return true, #lines
    end

    local spec = try("DynamicEntitySpec", function() return DynamicEntitySpec.new() end)
    if not spec then
        flush()
        return true, #lines
    end

    try("fill spec", function()
        spec.recordID = character
        spec.position = Vector4.new(first.x, first.y, first.z, 1)
        spec.orientation = EulerAngles.new(0, 0, 0):ToQuat()
        spec.alwaysSpawned = true
    end)

    probe.testNpcID = try("CreateEntity", function()
        return Game.GetDynamicEntitySystem():CreateEntity(spec)
    end)
    out("spawned NPC id =", tostring(probe.testNpcID))

    if probe.testNpcID then
        -- The command has to wait for the puppet to attach; the log is already flushed by then,
        -- so its outcome goes to the CET console only.
        builder.registerAttachCallback(probe.testNpcID, function(entity)
            local ok, err = pcall(function()
                local controller = entity:GetAIControllerComponent()
                if not controller then
                    print("[splineProbe] no AIControllerComponent on the spawned NPC")
                    return
                end

                local moveType = NewObject("AIMovementTypeSpec")
                moveType.useNPCMovementParams = false
                moveType.movementType = "Walk"

                local cmd = NewObject("handle:AIMoveOnSplineCommand")
                cmd.spline = nodeRef
                cmd.movementType = moveType
                cmd.startFromClosestPoint = true
                cmd.splineRecalculation = true
                cmd.ignoreNavigation = false
                cmd.snapToTerrain = true
                cmd.useStart = true
                cmd.useStop = true
                cmd.reverse = false
                cmd.rotateEntityTowardsFacingTarget = false

                controller:SendCommand(cmd)
                print("[splineProbe] AIMoveOnSplineCommand sent, watch the NPC")
            end)

            if not ok then
                print("[splineProbe] command failed: " .. tostring(err))
            end
        end)
    end

    out("---- next ----")
    out("Watch the NPC. The command is sent on attach, a moment after this log is written,")
    out("so its result is in the CET console, not here.")
    out("Then drag a spline marker and see whether the walk path follows (splineRecalculation).")

    local written = flush()
    return written, #lines
end

---Removes the NPC the command test spawned.
function probe.clearTestNpc()
    if not probe.testNpcID then return false end

    local ok = pcall(function()
        Game.GetDynamicEntitySystem():DeleteEntity(probe.testNpcID)
    end)
    probe.testNpcID = nil

    return ok
end

return probe
