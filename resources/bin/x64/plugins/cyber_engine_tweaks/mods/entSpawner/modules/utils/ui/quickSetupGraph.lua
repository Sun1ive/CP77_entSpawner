local style = require("modules/ui/style")

local graph = {}

---@param label string?
---@param maxWidth number
---@param fontRatio number?
---@return string
local function fitLabel(label, maxWidth, fontRatio)
    local text = tostring(label or "")
    local ratio = tonumber(fontRatio) or 1

    if text == "" then
        return ""
    end

    local function widthOf(value)
        return ImGui.CalcTextSize(value) * ratio
    end

    if widthOf(text) <= maxWidth then
        return text
    end

    while #text > 1 and widthOf(text .. "...") > maxWidth do
        text = text:sub(1, #text - 1)
    end

    return text .. "..."
end

---@param item table
---@param options table? `{ paddingX, minWidth, maxWidth, subtitleRatio, titleFn }`
---@return number
function graph.measureNode(item, options)
    local opts = options or {}
    local subtitleRatio = opts.subtitleRatio or 0.82
    local paddingX = opts.paddingX or 10
    local minWidth = opts.minWidth or 80
    local maxWidth = opts.maxWidth or 200
    local icon = tostring(item.icon or "")
    local iconWidth = icon ~= "" and ImGui.CalcTextSize(icon) or 0
    local spacing = icon ~= "" and ImGui.GetStyle().ItemSpacing.x or 0
    local title = opts.titleFn and opts.titleFn(item) or item.title
    local titleWidth = ImGui.CalcTextSize(tostring(title or ""))
    local subtitleWidth = item.subtitle and (ImGui.CalcTextSize(tostring(item.subtitle)) * subtitleRatio) or 0
    local contentWidth = iconWidth + spacing + math.max(titleWidth, subtitleWidth) + 2 * paddingX * style.viewSize

    return math.max(
        minWidth * style.viewSize,
        math.min(maxWidth * style.viewSize, contentWidth)
    )
end

---@param drawList table
---@param item table
---@param options table? `{ paddingX, subtitleRatio, centerTextWhenNoIcon, showOrphanBadge }`
---@return boolean clicked
---@return boolean hovered
function graph.drawNode(drawList, item, options)
    local opts = options or {}
    local x, y, width, height = item.x, item.y, item.width, item.height
    local color = item.color
    local paddingX = opts.paddingX or 10
    local subtitleRatio = opts.subtitleRatio or 0.82

    ImGui.SetCursorScreenPos(x, y)
    local clicked = ImGui.InvisibleButton(item.id, width, height) and item.suppressClick ~= true
    local hovered = ImGui.IsItemHovered()

    if item.drawContextMenu then
        item.drawContextMenu()
    end

    if item.tooltip then
        style.tooltipHovered(hovered, item.tooltip)
    end

    local alpha = item.selected and 0x77000000 or (hovered and 0x55000000 or 0x26000000)
    local rounding = 3 * style.viewSize
    local borderWidth = ((item.selected or hovered) and 2 or 1) * style.viewSize

    ImGui.ImDrawListAddRectFilled(drawList, x, y, x + width, y + height, alpha + (color % 0x1000000), rounding)
    ImGui.ImDrawListAddRect(drawList, x, y, x + width, y + height, color, rounding, 0, borderWidth)

    local fontSize = ImGui.GetFontSize()
    local styleData = ImGui.GetStyle()
    local innerPaddingX = paddingX * style.viewSize
    local icon = tostring(item.icon or "")
    local hasIcon = icon ~= ""
    local iconWidth, iconHeight = 0, fontSize

    if hasIcon then
        iconWidth, iconHeight = ImGui.CalcTextSize(icon)
        ImGui.ImDrawListAddText(drawList, fontSize, x + innerPaddingX, y + (height - iconHeight) / 2, style.highlightColor, icon)
    end

    local iconSpacing = hasIcon and styleData.ItemSpacing.x or 0
    local textLeft = x + innerPaddingX + iconWidth + iconSpacing
    local textWidth = math.max(1, width - 2 * innerPaddingX - iconWidth - iconSpacing)
    local titleText = fitLabel(item.title, textWidth, 1)
    local titleWidth = ImGui.CalcTextSize(titleText)
    local subtitle = item.subtitle
    local center = opts.centerTextWhenNoIcon == true and not hasIcon

    if subtitle and subtitle ~= "" then
        local subtitleText = fitLabel(subtitle, textWidth, subtitleRatio)
        local subtitleWidth = ImGui.CalcTextSize(subtitleText) * subtitleRatio
        local blockHeight = fontSize + fontSize * subtitleRatio
        local top = y + (height - blockHeight) / 2
        local titleX = center and (x + (width - titleWidth) / 2) or textLeft
        local subtitleX = center and (x + (width - subtitleWidth) / 2) or textLeft

        ImGui.ImDrawListAddText(drawList, fontSize, titleX, top, style.highlightColor, titleText)
        ImGui.ImDrawListAddText(drawList, fontSize * subtitleRatio, subtitleX, top + fontSize, style.mutedColor, subtitleText)
    else
        local titleX = center and (x + (width - titleWidth) / 2) or textLeft
        ImGui.ImDrawListAddText(drawList, fontSize, titleX, y + (height - fontSize) / 2, style.highlightColor, titleText)
    end

    if item.orphan and opts.showOrphanBadge ~= false then
        ImGui.ImDrawListAddText(
            drawList,
            fontSize * subtitleRatio,
            x + width - 14 * style.viewSize,
            y + 2 * style.viewSize,
            style.warnColor,
            IconGlyphs.AlertOutline
        )
    end

    return clicked, hovered
end

---@param drawList table
---@param options table `{ id, x, y, size, color, tooltip, disabled, suppressClick }`
---@return boolean clicked
---@return boolean hovered
function graph.drawAddButton(drawList, options)
    local x, y, size = options.x, options.y, options.size
    local disabled = options.disabled == true

    ImGui.SetCursorScreenPos(x, y)
    local clicked = ImGui.InvisibleButton(options.id, size, size) and not disabled and options.suppressClick ~= true
    local hovered = ImGui.IsItemHovered()

    if options.tooltip then
        style.tooltip(options.tooltip)
    end

    local accent = disabled and style.greyedColor or options.color
    local rounding = 3 * style.viewSize

    if hovered and not disabled then
        ImGui.ImDrawListAddRectFilled(drawList, x, y, x + size, y + size, 0x40000000 + (accent % 0x1000000), rounding)
    end

    ImGui.ImDrawListAddRect(drawList, x, y, x + size, y + size, accent, rounding, 0, 1 * style.viewSize)

    local glyph = options.glyph or IconGlyphs.Plus
    local glyphWidth, glyphHeight = ImGui.CalcTextSize(glyph)
    ImGui.ImDrawListAddText(
        drawList,
        ImGui.GetFontSize(),
        x + (size - glyphWidth) / 2,
        y + (size - glyphHeight) / 2,
        disabled and style.greyedColor or style.highlightColor,
        glyph
    )

    return clicked, hovered
end

---@param drawList table
function graph.drawLine(drawList, fromX, fromY, toX, toY, color, thickness)
    ImGui.ImDrawListAddLine(drawList, fromX, fromY, toX, toY, color, thickness or (1.5 * style.viewSize))
end

---@param drawList table
function graph.drawElbowLink(drawList, fromX, fromY, toX, toY, color, thickness)
    local midY = (fromY + toY) / 2

    graph.drawLine(drawList, fromX, fromY, fromX, midY, color, thickness)
    graph.drawLine(drawList, fromX, midY, toX, midY, color, thickness)
    graph.drawLine(drawList, toX, midY, toX, toY, color, thickness)
end

return graph
