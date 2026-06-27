--[[
    Premium Roblox UI Library - Redesign V5 (Ultimate Edition)
    Features:
    - CanvasGroup-based MainFrame with smooth fade/scale toggle animations (default key: Insert)
    - Sub-Tabs (Vertical navigation on the left of tab pages)
    - Dynamic Theme Engine (Real-time accent color updates using weak-keyed registries)
    - Multi-Select Dropdowns
    - Draggable Active Keybinds List
    - Built-in Config Manager UI utilizing Roblox File APIs (writefile, readfile, listfiles, delfile)
    - Integrated Lucide icons from icons.rest
--]]

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")

local Library = {
    Active = true,
    Visible = true,
    ToggleKey = Enum.KeyCode.Insert,
    DisableAnimations = false,
    Connections = {},
    CurrentTab = nil,
    Registry = {},     -- Stores raw states
    Controllers = {},  -- Stores controller objects
    ConfigFolder = "PremiumUI_Configs",
    Theme = {
        Background = Color3.fromRGB(12, 12, 14),
        Card = Color3.fromRGB(18, 18, 22),
        Border = Color3.fromRGB(28, 28, 32),
        Text = Color3.fromRGB(240, 240, 245),
        TextMuted = Color3.fromRGB(140, 140, 150),
        Accent = Color3.fromRGB(160, 140, 255), -- Pastel Purple
        Hover = Color3.fromRGB(25, 25, 30),
        Active = Color3.fromRGB(22, 22, 26),    -- Darker active state
        Element = Color3.fromRGB(20, 20, 24),   -- Inputs / dropdowns
        Element2 = Color3.fromRGB(24, 24, 28)   -- Buttons / tracks
    },
    
    -- Internals
    ScreenGui = nil,
    MainFrame = nil,
    WatermarkFrame = nil,
    NotificationContainer = nil,
    KeybindListFrame = nil,
    ActiveBinds = {},
    InMemoryConfigs = {},
    
    -- Theme Engine Registry (Weak-keyed to prevent memory leaks)
    ThemeRegistry = setmetatable({}, {__mode = "k"}),
    ThemeBindings = setmetatable({}, {__mode = "k"})
}

-- Utility: Create a Tween
local function tween(object, info, properties)
    local t = TweenService:Create(object, info, properties)
    t:Play()
    return t
end

-- Shared input dispatch
-- A single set of global UserInputService connections services every slider drag
-- and every "click outside to close" dropdown. This avoids creating N global
-- connections (one per component) which previously leaked on :Unload().
local SharedInput = { dragUpdate = nil }   -- dragUpdate = function(input) while a slider is held
local dropdownClosers = {}                 -- list of function(input) that close open dropdowns
local sharedInputReady = false

-- Returns true if an absolute screen position falls inside a GUI object's bounds
local function pointInside(guiObject, position)
    local ap = guiObject.AbsolutePosition
    local az = guiObject.AbsoluteSize
    return position.X >= ap.X and position.X <= ap.X + az.X
        and position.Y >= ap.Y and position.Y <= ap.Y + az.Y
end

local function ensureSharedInput()
    if sharedInputReady then return end
    sharedInputReady = true

    local moveConn = UserInputService.InputChanged:Connect(function(input)
        if SharedInput.dragUpdate and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            SharedInput.dragUpdate(input)
        end
    end)
    table.insert(Library.Connections, moveConn)

    local endConn = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            SharedInput.dragUpdate = nil
        end
    end)
    table.insert(Library.Connections, endConn)

    local beganConn = UserInputService.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            for _, closer in ipairs(dropdownClosers) do
                pcall(closer, input)
            end
        end
    end)
    table.insert(Library.Connections, beganConn)
end

-- Bind an instance's color property to a Theme key so it updates live when that color changes.
function Library:RegisterTheme(instance, property, key)
    local map = self.ThemeBindings[instance]
    if not map then
        map = {}
        self.ThemeBindings[instance] = map
    end
    map[property] = key

    if instance:IsA("UIGradient") then
        instance.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, self.Theme[key]),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 40, 45))
        })
    else
        instance[property] = self.Theme[key]
    end
end

-- Backwards-compatible accent helper (binds the property to the Accent theme key)
function Library:RegisterAccent(instance, property)
    self:RegisterTheme(instance, property, "Accent")
end

-- Change a single theme color and tween every bound element to it.
function Library:SetThemeColor(key, newColor)
    self.Theme[key] = newColor
    for instance, map in pairs(self.ThemeBindings) do
        for property, boundKey in pairs(map) do
            if boundKey == key then
                pcall(function()
                    if instance:IsA("UIGradient") then
                        instance.Color = ColorSequence.new({
                            ColorSequenceKeypoint.new(0, newColor),
                            ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 40, 45))
                        })
                    else
                        tween(instance, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                            [property] = newColor
                        })
                    end
                end)
            end
        end
    end
end

-- Backwards-compatible accent updater
function Library:UpdateAccentColor(newColor)
    self:SetThemeColor("Accent", newColor)
end

-- Walk the whole UI and auto-bind any element whose current color matches a Theme color,
-- so changing a theme color recolors everything that was built statically (not just the accent).
function Library:RefreshThemeBindings()
    if not self.ScreenGui then return end

    local function packColor(c)
        return math.round(c.R * 255) .. "," .. math.round(c.G * 255) .. "," .. math.round(c.B * 255)
    end

    local colorToKey = {}
    for key, c in pairs(self.Theme) do
        if typeof(c) == "Color3" then
            colorToKey[packColor(c)] = key
        end
    end

    local colorProps = { "BackgroundColor3", "TextColor3", "ImageColor3", "ScrollBarImageColor3" }

    for _, inst in ipairs(self.ScreenGui:GetDescendants()) do
        if inst:IsA("UIStroke") then
            local key = colorToKey[packColor(inst.Color)]
            if key then self:RegisterTheme(inst, "Color", key) end
        else
            for _, property in ipairs(colorProps) do
                local ok, val = pcall(function() return inst[property] end)
                if ok and typeof(val) == "Color3" then
                    local key = colorToKey[packColor(val)]
                    if key then self:RegisterTheme(inst, property, key) end
                end
            end
        end
    end
end

-- Unload Library and clean up all resources
function Library:Unload()
    for _, conn in ipairs(self.Connections) do
        pcall(function()
            conn:Disconnect()
        end)
    end
    self.Connections = {}

    if self.ScreenGui then
        self.ScreenGui:Destroy()
        self.ScreenGui = nil
    end

    self.Active = false
end

-- Utility: Make UI Draggable
local function makeDraggable(dragFrame, parentFrame)
    local dragging = false
    local dragInput, dragStart, startPos

    dragFrame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = parentFrame.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    dragFrame.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    local conn = UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragging then
            local delta = input.Position - dragStart
            local targetPos = UDim2.new(
                startPos.X.Scale,
                startPos.X.Offset + delta.X,
                startPos.Y.Scale,
                startPos.Y.Offset + delta.Y
            )
            tween(parentFrame, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = targetPos
            })
        end
    end)
    table.insert(Library.Connections, conn)
end

-- Determine UI Parent
local function getUiParent()
    local success, hasCore = pcall(function()
        return CoreGui:IsA("Instance")
    end)
    if success and hasCore then
        return CoreGui
    else
        local localPlayer = Players.LocalPlayer
        if localPlayer then
            return localPlayer:WaitForChild("PlayerGui")
        end
    end
    return game:GetService("StarterGui")
end

-- Config Management
local function ensureConfigFolder()
    if makefolder then
        pcall(function()
            makefolder(Library.ConfigFolder)
        end)
    end
end

function Library:SaveConfig(name)
    ensureConfigFolder()
    local filePath = self.ConfigFolder .. "/" .. name .. ".json"
    local success, encoded = pcall(function()
        return HttpService:JSONEncode(self.Registry)
    end)
    if success then
        if writefile then
            pcall(function()
                writefile(filePath, encoded)
            end)
        else
            self.InMemoryConfigs[name] = encoded
            print("[Library] Config Saved (In-Memory):", encoded)
        end
    end
end

function Library:LoadConfig(name)
    local filePath = self.ConfigFolder .. "/" .. name .. ".json"
    local data
    if readfile then
        local success, content = pcall(function()
            return readfile(filePath)
        end)
        if success and content then
            pcall(function()
                data = HttpService:JSONDecode(content)
            end)
        end
    else
        local content = self.InMemoryConfigs[name]
        if content then
            pcall(function()
                data = HttpService:JSONDecode(content)
            end)
        end
    end
    
    if data then
        for k, v in pairs(data) do
            local controller = self.Controllers[k]
            if controller then
                if type(v) == "table" then
                    if #v == 3 then
                        controller:Set(Color3.new(v[1], v[2], v[3]))
                    elseif #v == 4 then
                        controller:Set(Color3.new(v[1], v[2], v[3]), v[4])
                    end
                else
                    controller:Set(v)
                end
            end
        end
        return true
    end
    return false
end

-- Global Notification System
function Library:Notify(options)
    options = options or {}
    local title = options.Title or "Notification"
    local content = options.Content or ""
    local duration = options.Duration or 5

    if not self.ScreenGui then return end

    if not self.NotificationContainer then
        local container = Instance.new("Frame")
        container.Name = "NotificationContainer"
        container.Size = UDim2.new(0, 260, 1, -40)
        container.Position = UDim2.new(1, -280, 0, 20)
        container.BackgroundTransparency = 1
        container.Parent = self.ScreenGui

        local layout = Instance.new("UIListLayout")
        layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
        layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
        layout.Padding = UDim.new(0, 8)
        layout.Parent = container

        self.NotificationContainer = container
    end

    local wrapper = Instance.new("Frame")
    wrapper.Size = UDim2.new(1, 0, 0, 54)
    wrapper.BackgroundTransparency = 1
    wrapper.Parent = self.NotificationContainer

    local card = Instance.new("Frame")
    card.Size = UDim2.new(1, 0, 1, 0)
    card.Position = UDim2.new(1, 20, 0, 0)
    card.BackgroundColor3 = self.Theme.Card
    card.Parent = wrapper

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Color = self.Theme.Border
    stroke.Thickness = 1
    stroke.Parent = card

    local accentBar = Instance.new("Frame")
    accentBar.Size = UDim2.new(0, 3, 1, 0)
    accentBar.BorderSizePixel = 0
    accentBar.Parent = card
    self:RegisterAccent(accentBar, "BackgroundColor3")
    
    local abc = Instance.new("UICorner")
    abc.CornerRadius = UDim.new(0, 4)
    abc.Parent = accentBar

    local iconLabel = Instance.new("ImageLabel")
    iconLabel.Size = UDim2.new(0, 16, 0, 16)
    iconLabel.Position = UDim2.new(0, 12, 0.5, -8)
    iconLabel.BackgroundTransparency = 1
    iconLabel.Image = "rbxassetid://127234874352422" -- Lucide eye / info
    self:RegisterAccent(iconLabel, "ImageColor3")
    iconLabel.Parent = card

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -45, 0, 18)
    titleLabel.Position = UDim2.new(0, 36, 0, 8)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = title
    titleLabel.TextColor3 = self.Theme.Text
    titleLabel.TextSize = 11
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = card

    local contentLabel = Instance.new("TextLabel")
    contentLabel.Size = UDim2.new(1, -45, 0, 18)
    contentLabel.Position = UDim2.new(0, 36, 0, 24)
    contentLabel.BackgroundTransparency = 1
    contentLabel.Text = content
    contentLabel.TextColor3 = self.Theme.TextMuted
    contentLabel.TextSize = 10
    contentLabel.Font = Enum.Font.Gotham
    contentLabel.TextXAlignment = Enum.TextXAlignment.Left
    contentLabel.Parent = card

    tween(card, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Position = UDim2.new(0, 0, 0, 0)
    })

    task.delay(duration, function()
        local t = tween(card, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            Position = UDim2.new(1, 20, 0, 0),
            BackgroundTransparency = 1
        })
        t.Completed:Connect(function()
            wrapper:Destroy()
        end)
    end)
end

-- Global Watermark System
function Library:SetWatermark(text)
    if not self.ScreenGui then return end

    if text == nil or text == false or text == "" then
        if self.WatermarkFrame then
            self.WatermarkFrame.Visible = false
        end
        if self.WatermarkConnection then
            self.WatermarkConnection:Disconnect()
            self.WatermarkConnection = nil
        end
        return
    end

    self.WatermarkText = tostring(text)

    if not self.WatermarkFrame then
        local wm = Instance.new("Frame")
        wm.Name = "Watermark"
        wm.Position = UDim2.new(0, 15, 0, 15)
        wm.Size = UDim2.new(0, 0, 0, 22)
        wm.AutomaticSize = Enum.AutomaticSize.X
        wm.BackgroundColor3 = self.Theme.Card
        wm.Parent = self.ScreenGui

        local wmc = Instance.new("UICorner")
        wmc.CornerRadius = UDim.new(0, 4)
        wmc.Parent = wm

        local wms = Instance.new("UIStroke")
        wms.Thickness = 1
        wms.Parent = wm

        local grad = Instance.new("UIGradient")
        grad.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, self.Theme.Accent),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 40, 45))
        })
        grad.Parent = wms
        self:RegisterAccent(grad, "Color")

        local padding = Instance.new("UIPadding")
        padding.PaddingLeft = UDim.new(0, 10)
        padding.PaddingRight = UDim.new(0, 10)
        padding.Parent = wm

        local label = Instance.new("TextLabel")
        label.Name = "Label"
        label.Size = UDim2.new(0, 0, 1, 0)
        label.AutomaticSize = Enum.AutomaticSize.X
        label.BackgroundTransparency = 1
        label.Text = ""
        label.TextColor3 = self.Theme.Text
        label.TextSize = 10
        label.Font = Enum.Font.GothamMedium
        label.Parent = wm

        self.WatermarkFrame = wm
    end

    self.WatermarkFrame.Visible = true

    -- Start the dynamic update loop if not already running
    if not self.WatermarkConnection then
        local lastTime = os.clock()
        local frameCount = 0
        local fps = 60

        self.WatermarkConnection = RunService.RenderStepped:Connect(function()
            frameCount = frameCount + 1
            local now = os.clock()
            local delta = now - lastTime
            if delta >= 0.5 then
                fps = math.round(frameCount / delta)
                frameCount = 0
                lastTime = now

                local localPlayer = Players.LocalPlayer
                local displayName = localPlayer and localPlayer.DisplayName or "Joao"
                local ping = 0
                pcall(function()
                    ping = math.round(game:GetService("Stats").Network:GetPing())
                end)

                if self.WatermarkFrame and self.WatermarkFrame.Visible then
                    self.WatermarkFrame.Label.Text = string.format("%s | %s | FPS: %d | Ping: %dms", self.WatermarkText, displayName, fps, ping)
                end
            end
        end)
        table.insert(Library.Connections, self.WatermarkConnection)
    end
end

-- Floating Keybinds List
function Library:SetKeybindListVisible(visible)
    if not self.ScreenGui then return end
    
    if not visible then
        if self.KeybindListFrame then
            self.KeybindListFrame.Visible = false
        end
        return
    end

    if not self.KeybindListFrame then
        local kbl = Instance.new("Frame")
        kbl.Name = "KeybindList"
        kbl.Size = UDim2.new(0, 160, 0, 200)
        kbl.Position = UDim2.new(0, 20, 0, 220)
        kbl.BackgroundColor3 = self.Theme.Card
        kbl.Parent = self.ScreenGui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 5)
        corner.Parent = kbl

        local stroke = Instance.new("UIStroke")
        stroke.Color = self.Theme.Border
        stroke.Thickness = 1
        stroke.Parent = kbl

        local header = Instance.new("Frame")
        header.Size = UDim2.new(1, 0, 0, 25)
        header.BackgroundTransparency = 1
        header.Parent = kbl
        makeDraggable(header, kbl)

        local title = Instance.new("TextLabel")
        title.Size = UDim2.new(1, -10, 1, 0)
        title.Position = UDim2.new(0, 10, 0, 0)
        title.BackgroundTransparency = 1
        title.Text = "Active Binds"
        title.TextColor3 = self.Theme.Text
        title.TextSize = 10
        title.Font = Enum.Font.GothamBold
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = header

        local content = Instance.new("Frame")
        content.Name = "Content"
        content.Size = UDim2.new(1, 0, 1, -25)
        content.Position = UDim2.new(0, 0, 0, 25)
        content.BackgroundTransparency = 1
        content.Parent = kbl

        local layout = Instance.new("UIListLayout")
        layout.SortOrder = Enum.SortOrder.LayoutOrder
        layout.Padding = UDim.new(0, 4)
        layout.Parent = content

        local padding = Instance.new("UIPadding")
        padding.PaddingLeft = UDim.new(0, 10)
        padding.PaddingRight = UDim.new(0, 10)
        padding.PaddingTop = UDim.new(0, 4)
        padding.Parent = content

        self.KeybindListFrame = kbl
    end

    self.KeybindListFrame.Visible = true
end

function Library:UpdateKeybindList(name, active, stateText)
    if not self.KeybindListFrame then return end
    local content = self.KeybindListFrame.Content
    
    local existing = content:FindFirstChild(name)
    if not active then
        if existing then
            existing:Destroy()
        end
        return
    end

    if not existing then
        local row = Instance.new("Frame")
        row.Name = name
        row.Size = UDim2.new(1, 0, 0, 16)
        row.BackgroundTransparency = 1
        row.Parent = content

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -50, 1, 0)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = name
        nameLabel.TextColor3 = self.Theme.TextMuted
        nameLabel.TextSize = 10
        nameLabel.Font = Enum.Font.Gotham
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Parent = row

        local stateLabel = Instance.new("TextLabel")
        stateLabel.Name = "State"
        stateLabel.Size = UDim2.new(0, 50, 1, 0)
        stateLabel.Position = UDim2.new(1, -50, 0, 0)
        stateLabel.BackgroundTransparency = 1
        stateLabel.Text = "[" .. stateText .. "]"
        stateLabel.TextColor3 = self.Theme.TextMuted
        stateLabel.TextSize = 9
        stateLabel.Font = Enum.Font.Gotham
        stateLabel.TextXAlignment = Enum.TextXAlignment.Right
        stateLabel.Parent = row
    else
        existing.State.Text = "[" .. stateText .. "]"
    end
end

-- Tooltip System
-- Attaches a hover tooltip to any GUI object. A single shared tooltip frame is
-- lazily created and reused; it follows the cursor while hovering.
function Library:AttachTooltip(instance, text)
    if not instance or not text or text == "" then return end

    if not self.TooltipFrame and self.ScreenGui then
        local tip = Instance.new("Frame")
        tip.Name = "Tooltip"
        tip.AutomaticSize = Enum.AutomaticSize.XY
        tip.BackgroundColor3 = self.Theme.Card
        tip.BorderSizePixel = 0
        tip.Visible = false
        tip.ZIndex = 500
        tip.Parent = self.ScreenGui

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 4)
        corner.Parent = tip

        local stroke = Instance.new("UIStroke")
        stroke.Color = self.Theme.Border
        stroke.Thickness = 1
        stroke.Parent = tip

        local padding = Instance.new("UIPadding")
        padding.PaddingLeft = UDim.new(0, 8)
        padding.PaddingRight = UDim.new(0, 8)
        padding.PaddingTop = UDim.new(0, 4)
        padding.PaddingBottom = UDim.new(0, 4)
        padding.Parent = tip

        local label = Instance.new("TextLabel")
        label.Name = "Label"
        label.AutomaticSize = Enum.AutomaticSize.XY
        label.BackgroundTransparency = 1
        label.Text = ""
        label.TextColor3 = self.Theme.Text
        label.TextSize = 11
        label.Font = Enum.Font.Gotham
        label.ZIndex = 500
        label.Parent = tip

        self.TooltipFrame = tip
    end

    local enterConn = instance.MouseEnter:Connect(function()
        if not self.TooltipFrame then return end
        self.TooltipFrame.Label.Text = text
        self.TooltipFrame.Visible = true
    end)
    table.insert(self.Connections, enterConn)

    local moveConn = instance.MouseMoved:Connect(function(x, y)
        if not self.TooltipFrame or not self.TooltipFrame.Visible then return end
        self.TooltipFrame.Position = UDim2.new(0, x + 14, 0, y + 14)
    end)
    table.insert(self.Connections, moveConn)

    local leaveConn = instance.MouseLeave:Connect(function()
        if self.TooltipFrame then
            self.TooltipFrame.Visible = false
        end
    end)
    table.insert(self.Connections, leaveConn)
end

-- Modal Dialog / Prompt System
-- options = { Title, Content, Buttons = { {Text = "...", Callback = fn}, ... } }
-- Defaults to a single "OK" button. The first button is styled as the accent primary.
function Library:Dialog(options)
    options = options or {}
    local title = options.Title or "Dialog"
    local content = options.Content or ""
    local buttons = options.Buttons or { { Text = "OK" } }

    if not self.ScreenGui then return end

    local Overlay = Instance.new("Frame")
    Overlay.Name = "DialogOverlay"
    Overlay.Size = UDim2.new(1, 0, 1, 0)
    Overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
    Overlay.BackgroundTransparency = 1
    Overlay.BorderSizePixel = 0
    Overlay.ZIndex = 400
    Overlay.Parent = self.ScreenGui

    local Modal = Instance.new("CanvasGroup")
    Modal.Size = UDim2.new(0, 300, 0, 150)
    Modal.Position = UDim2.new(0.5, -150, 0.5, -75)
    Modal.BackgroundColor3 = self.Theme.Card
    Modal.GroupTransparency = 1
    Modal.BorderSizePixel = 0
    Modal.ZIndex = 401
    Modal.Parent = Overlay

    local MCorner = Instance.new("UICorner")
    MCorner.CornerRadius = UDim.new(0, 6)
    MCorner.Parent = Modal

    local MStroke = Instance.new("UIStroke")
    MStroke.Color = self.Theme.Border
    MStroke.Thickness = 1
    MStroke.Parent = Modal

    local TitleLabel = Instance.new("TextLabel")
    TitleLabel.Size = UDim2.new(1, -30, 0, 22)
    TitleLabel.Position = UDim2.new(0, 15, 0, 14)
    TitleLabel.BackgroundTransparency = 1
    TitleLabel.Text = title
    TitleLabel.TextColor3 = self.Theme.Text
    TitleLabel.TextSize = 14
    TitleLabel.Font = Enum.Font.GothamBold
    TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
    TitleLabel.Parent = Modal

    local ContentLabel = Instance.new("TextLabel")
    ContentLabel.Size = UDim2.new(1, -30, 0, 60)
    ContentLabel.Position = UDim2.new(0, 15, 0, 40)
    ContentLabel.BackgroundTransparency = 1
    ContentLabel.Text = content
    ContentLabel.TextColor3 = self.Theme.TextMuted
    ContentLabel.TextSize = 12
    ContentLabel.Font = Enum.Font.Gotham
    ContentLabel.TextWrapped = true
    ContentLabel.TextXAlignment = Enum.TextXAlignment.Left
    ContentLabel.TextYAlignment = Enum.TextYAlignment.Top
    ContentLabel.Parent = Modal

    local ButtonRow = Instance.new("Frame")
    ButtonRow.Size = UDim2.new(1, -30, 0, 28)
    ButtonRow.Position = UDim2.new(0, 15, 1, -42)
    ButtonRow.BackgroundTransparency = 1
    ButtonRow.Parent = Modal

    local BRLayout = Instance.new("UIListLayout")
    BRLayout.FillDirection = Enum.FillDirection.Horizontal
    BRLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    BRLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    BRLayout.Padding = UDim.new(0, 8)
    BRLayout.Parent = ButtonRow

    local closed = false
    local function close(callback)
        if closed then return end
        closed = true
        tween(Overlay, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { BackgroundTransparency = 1 })
        local t = tween(Modal, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            GroupTransparency = 1,
            Size = UDim2.new(0, 280, 0, 130)
        })
        t.Completed:Connect(function()
            Overlay:Destroy()
            if callback then callback() end
        end)
    end

    for i, btnDef in ipairs(buttons) do
        local isPrimary = (i == 1)
        local Btn = Instance.new("TextButton")
        Btn.Size = UDim2.new(0, 80, 1, 0)
        Btn.BackgroundColor3 = isPrimary and self.Theme.Accent or Color3.fromRGB(24, 24, 28)
        Btn.Text = btnDef.Text or "OK"
        Btn.TextColor3 = isPrimary and Color3.fromRGB(255, 255, 255) or self.Theme.Text
        Btn.TextSize = 11
        Btn.Font = Enum.Font.GothamMedium
        Btn.AutoButtonColor = false
        Btn.ZIndex = 402
        Btn.Parent = ButtonRow

        local BC = Instance.new("UICorner")
        BC.CornerRadius = UDim.new(0, 4)
        BC.Parent = Btn

        if isPrimary then
            self:RegisterAccent(Btn, "BackgroundColor3")
        else
            local BS = Instance.new("UIStroke")
            BS.Color = self.Theme.Border
            BS.Thickness = 1
            BS.Parent = Btn
        end

        Btn.MouseButton1Click:Connect(function()
            close(btnDef.Callback)
        end)
    end

    -- Animate in
    tween(Overlay, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 0.5 })
    Modal.Size = UDim2.new(0, 280, 0, 130)
    tween(Modal, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        GroupTransparency = 0,
        Size = UDim2.new(0, 300, 0, 150)
    })
end

-- Intro Loader / Splash Screen
-- Shown before CreateWindow. Returns a controller:
--   ctrl:SetProgress(pct, statusText)  -- pct accepts 0..1 or 0..100
--   ctrl:Finish(callback)              -- fades out, destroys, then calls callback
function Library:CreateLoader(options)
    options = options or {}
    local title = options.Title or "Loading"
    local subtitle = options.Subtitle or ""

    local LoaderGui = Instance.new("ScreenGui")
    LoaderGui.Name = "PremiumUiLoader_" .. HttpService:GenerateGUID(false):sub(1, 8)
    LoaderGui.ResetOnSpawn = false
    LoaderGui.IgnoreGuiInset = true
    LoaderGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    LoaderGui.Parent = getUiParent()

    local Frame = Instance.new("CanvasGroup")
    Frame.Size = UDim2.new(0, 320, 0, 140)
    Frame.Position = UDim2.new(0.5, -160, 0.5, -70)
    Frame.BackgroundColor3 = self.Theme.Background
    Frame.GroupTransparency = 1
    Frame.BorderSizePixel = 0
    Frame.Parent = LoaderGui

    local FCorner = Instance.new("UICorner")
    FCorner.CornerRadius = UDim.new(0, 6)
    FCorner.Parent = Frame

    local FStroke = Instance.new("UIStroke")
    FStroke.Color = self.Theme.Border
    FStroke.Thickness = 1
    FStroke.Parent = Frame

    local TitleLabel = Instance.new("TextLabel")
    TitleLabel.Size = UDim2.new(1, -40, 0, 24)
    TitleLabel.Position = UDim2.new(0, 20, 0, 24)
    TitleLabel.BackgroundTransparency = 1
    TitleLabel.Text = title
    TitleLabel.TextColor3 = self.Theme.Text
    TitleLabel.TextSize = 16
    TitleLabel.Font = Enum.Font.GothamBold
    TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
    TitleLabel.Parent = Frame

    local SubLabel = Instance.new("TextLabel")
    SubLabel.Size = UDim2.new(1, -40, 0, 14)
    SubLabel.Position = UDim2.new(0, 20, 0, 48)
    SubLabel.BackgroundTransparency = 1
    SubLabel.Text = subtitle
    SubLabel.TextColor3 = self.Theme.TextMuted
    SubLabel.TextSize = 11
    SubLabel.Font = Enum.Font.Gotham
    SubLabel.TextXAlignment = Enum.TextXAlignment.Left
    SubLabel.Parent = Frame

    local Track = Instance.new("Frame")
    Track.Size = UDim2.new(1, -40, 0, 6)
    Track.Position = UDim2.new(0, 20, 1, -42)
    Track.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
    Track.BorderSizePixel = 0
    Track.Parent = Frame

    local TC = Instance.new("UICorner")
    TC.CornerRadius = UDim.new(1, 0)
    TC.Parent = Track

    local Fill = Instance.new("Frame")
    Fill.Size = UDim2.new(0, 0, 1, 0)
    Fill.BorderSizePixel = 0
    Fill.Parent = Track
    self:RegisterAccent(Fill, "BackgroundColor3")

    local FillC = Instance.new("UICorner")
    FillC.CornerRadius = UDim.new(1, 0)
    FillC.Parent = Fill

    local StatusLabel = Instance.new("TextLabel")
    StatusLabel.Size = UDim2.new(1, -40, 0, 14)
    StatusLabel.Position = UDim2.new(0, 20, 1, -26)
    StatusLabel.BackgroundTransparency = 1
    StatusLabel.Text = ""
    StatusLabel.TextColor3 = self.Theme.TextMuted
    StatusLabel.TextSize = 10
    StatusLabel.Font = Enum.Font.Gotham
    StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
    StatusLabel.Parent = Frame

    local PercentLabel = Instance.new("TextLabel")
    PercentLabel.Size = UDim2.new(0, 40, 0, 14)
    PercentLabel.Position = UDim2.new(1, -60, 1, -26)
    PercentLabel.BackgroundTransparency = 1
    PercentLabel.Text = "0%"
    PercentLabel.TextColor3 = self.Theme.TextMuted
    PercentLabel.TextSize = 10
    PercentLabel.Font = Enum.Font.Gotham
    PercentLabel.TextXAlignment = Enum.TextXAlignment.Right
    PercentLabel.Parent = Frame

    tween(Frame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { GroupTransparency = 0 })

    local LoaderController = {}

    function LoaderController:SetProgress(pct, statusText)
        pct = pct or 0
        if pct > 1 then pct = pct / 100 end
        pct = math.clamp(pct, 0, 1)
        tween(Fill, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Size = UDim2.new(pct, 0, 1, 0)
        })
        PercentLabel.Text = math.round(pct * 100) .. "%"
        if statusText then
            StatusLabel.Text = statusText
        end
    end

    function LoaderController:Finish(callback)
        local t = tween(Frame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
            GroupTransparency = 1,
            Size = UDim2.new(0, 300, 0, 130)
        })
        t.Completed:Connect(function()
            LoaderGui:Destroy()
            if callback then callback() end
        end)
    end

    return LoaderController
end

-- Toggle Menu Visibility
function Library:Toggle()
    if not self.MainFrame then return end
    self.Visible = not self.Visible
    
    if self.DisableAnimations then
        self.MainFrame.Visible = self.Visible
        self.MainFrame.GroupTransparency = self.Visible and 0 or 1
        self.MainFrame.Size = self.Visible and UDim2.new(0, 580, 0, 400) or UDim2.new(0, 540, 0, 370)
        return
    end
    
    if self.Visible then
        self.MainFrame.Visible = true
        tween(self.MainFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            GroupTransparency = 0,
            Size = UDim2.new(0, 580, 0, 400)
        })
    else
        local t = tween(self.MainFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            GroupTransparency = 1,
            Size = UDim2.new(0, 540, 0, 370)
        })
        t.Completed:Connect(function()
            if not self.Visible then
                self.MainFrame.Visible = false
            end
        end)
    end
end

function Library:CreateWindow(options)
    options = options or {}
    local titleText = options.Name or "Reptillian"
    local infoText = options.Info or "Build date: June 22 2026"
    
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "PremiumUi_" .. HttpService:GenerateGUID(false):sub(1, 8)
    ScreenGui.ResetOnSpawn = false
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ScreenGui.Parent = getUiParent()
    self.ScreenGui = ScreenGui

    -- Main Container (CanvasGroup for smooth fades)
    local MainFrame = Instance.new("CanvasGroup")
    MainFrame.Name = "MainFrame"
    MainFrame.Size = UDim2.new(0, 580, 0, 400)
    MainFrame.Position = UDim2.new(0.5, -290, 0.5, -200)
    MainFrame.BackgroundColor3 = self.Theme.Background
    MainFrame.BorderSizePixel = 0
    MainFrame.Parent = ScreenGui
    self.MainFrame = MainFrame

    local MainCorner = Instance.new("UICorner")
    MainCorner.CornerRadius = UDim.new(0, 5)
    MainCorner.Parent = MainFrame

    local MainStroke = Instance.new("UIStroke")
    MainStroke.Color = self.Theme.Border
    MainStroke.Thickness = 1
    MainStroke.Parent = MainFrame

    -- Header Bar
    local Header = Instance.new("Frame")
    Header.Name = "Header"
    Header.Size = UDim2.new(1, 0, 0, 50)
    Header.BackgroundTransparency = 1
    Header.Parent = MainFrame
    makeDraggable(Header, MainFrame)

    local TitleContainer = Instance.new("Frame")
    TitleContainer.Size = UDim2.new(0, 200, 1, 0)
    TitleContainer.Position = UDim2.new(0, 15, 0, 0)
    TitleContainer.BackgroundTransparency = 1
    TitleContainer.Parent = Header

    local TitleLabel = Instance.new("TextLabel")
    TitleLabel.Size = UDim2.new(1, 0, 0, 25)
    TitleLabel.Position = UDim2.new(0, 0, 0, 8)
    TitleLabel.BackgroundTransparency = 1
    TitleLabel.Text = titleText
    TitleLabel.TextColor3 = self.Theme.Text
    TitleLabel.TextSize = 14
    TitleLabel.Font = Enum.Font.GothamBold
    TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
    TitleLabel.Parent = TitleContainer

    local InfoLabel = Instance.new("TextLabel")
    InfoLabel.Size = UDim2.new(1, 0, 0, 15)
    InfoLabel.Position = UDim2.new(0, 0, 0, 24)
    InfoLabel.BackgroundTransparency = 1
    InfoLabel.Text = infoText
    InfoLabel.TextColor3 = self.Theme.TextMuted
    InfoLabel.TextSize = 9
    InfoLabel.Font = Enum.Font.Gotham
    InfoLabel.TextXAlignment = Enum.TextXAlignment.Left
    InfoLabel.Parent = TitleContainer

    local TabsFrame = Instance.new("Frame")
    TabsFrame.Name = "TabsFrame"
    TabsFrame.Size = UDim2.new(1, -230, 1, 0)
    TabsFrame.Position = UDim2.new(0, 215, 0, 0)
    TabsFrame.BackgroundTransparency = 1
    TabsFrame.Parent = Header

    local TabsLayout = Instance.new("UIListLayout")
    TabsLayout.FillDirection = Enum.FillDirection.Horizontal
    TabsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
    TabsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
    TabsLayout.Padding = UDim.new(0, 6)
    TabsLayout.Parent = TabsFrame

    local TabsPadding = Instance.new("UIPadding")
    TabsPadding.PaddingRight = UDim.new(0, 15)
    TabsPadding.Parent = TabsFrame

    local PagesContainer = Instance.new("Frame")
    PagesContainer.Name = "PagesContainer"
    PagesContainer.Size = UDim2.new(1, 0, 1, -50)
    PagesContainer.Position = UDim2.new(0, 0, 0, 50)
    PagesContainer.BackgroundTransparency = 1
    PagesContainer.Parent = MainFrame

    -- Color Picker Window
    local ColorPickerWindow = Instance.new("Frame")
    ColorPickerWindow.Name = "ColorPickerWindow"
    ColorPickerWindow.Size = UDim2.new(0, 240, 0, 210)
    ColorPickerWindow.BackgroundColor3 = self.Theme.Card
    ColorPickerWindow.Visible = false
    ColorPickerWindow.Parent = ScreenGui

    local CPWCorner = Instance.new("UICorner")
    CPWCorner.CornerRadius = UDim.new(0, 5)
    CPWCorner.Parent = ColorPickerWindow

    local CPWStroke = Instance.new("UIStroke")
    CPWStroke.Color = self.Theme.Border
    CPWStroke.Thickness = 1
    CPWStroke.Parent = ColorPickerWindow

    makeDraggable(ColorPickerWindow, ColorPickerWindow)

    local CPWHeader = Instance.new("Frame")
    CPWHeader.Size = UDim2.new(1, 0, 0, 30)
    CPWHeader.BackgroundTransparency = 1
    CPWHeader.Parent = ColorPickerWindow

    local ColorTab = Instance.new("Frame")
    ColorTab.Size = UDim2.new(0, 65, 0, 20)
    ColorTab.Position = UDim2.new(0, 10, 0.5, -10)
    ColorTab.BackgroundColor3 = self.Theme.Active
    ColorTab.Parent = CPWHeader
    local CTC = Instance.new("UICorner")
    CTC.CornerRadius = UDim.new(0, 4)
    CTC.Parent = ColorTab
    local CTS = Instance.new("UIStroke")
    CTS.Color = self.Theme.Border
    CTS.Thickness = 1
    CTS.Parent = ColorTab

    local ColorTabIcon = Instance.new("ImageLabel")
    ColorTabIcon.Size = UDim2.new(0, 10, 0, 10)
    ColorTabIcon.Position = UDim2.new(0, 6, 0.5, -5)
    ColorTabIcon.BackgroundTransparency = 1
    ColorTabIcon.Image = "rbxassetid://10842354714"
    ColorTabIcon.ImageColor3 = self.Theme.Text
    ColorTabIcon.Parent = ColorTab

    local ColorTabLabel = Instance.new("TextLabel")
    ColorTabLabel.Size = UDim2.new(1, -20, 1, 0)
    ColorTabLabel.Position = UDim2.new(0, 20, 0, 0)
    ColorTabLabel.BackgroundTransparency = 1
    ColorTabLabel.Text = "Color"
    ColorTabLabel.TextColor3 = self.Theme.Text
    ColorTabLabel.TextSize = 10
    ColorTabLabel.Font = Enum.Font.GothamBold
    ColorTabLabel.TextXAlignment = Enum.TextXAlignment.Left
    ColorTabLabel.Parent = ColorTab

    local PaintTab = Instance.new("Frame")
    PaintTab.Size = UDim2.new(0, 24, 0, 20)
    PaintTab.Position = UDim2.new(0, 80, 0.5, -10)
    PaintTab.BackgroundTransparency = 1
    PaintTab.Parent = CPWHeader

    local PaintIcon = Instance.new("ImageLabel")
    PaintIcon.Size = UDim2.new(0, 11, 0, 11)
    PaintIcon.Position = UDim2.new(0.5, -5, 0.5, -5)
    PaintIcon.BackgroundTransparency = 1
    PaintIcon.Image = "rbxassetid://10842432243"
    PaintIcon.ImageColor3 = self.Theme.TextMuted
    PaintIcon.Parent = PaintTab

    local CPWClose = Instance.new("TextButton")
    CPWClose.Size = UDim2.new(0, 30, 0, 30)
    CPWClose.Position = UDim2.new(1, -30, 0, 0)
    CPWClose.BackgroundTransparency = 1
    CPWClose.Text = "×"
    CPWClose.TextColor3 = self.Theme.TextMuted
    CPWClose.TextSize = 18
    CPWClose.Font = Enum.Font.Gotham
    CPWClose.Parent = CPWHeader
    CPWClose.MouseButton1Click:Connect(function()
        ColorPickerWindow.Visible = false
    end)

    local SatValCanvas = Instance.new("TextButton")
    SatValCanvas.Size = UDim2.new(0, 180, 0, 120)
    SatValCanvas.Position = UDim2.new(0, 12, 0, 35)
    SatValCanvas.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
    SatValCanvas.BorderSizePixel = 0
    SatValCanvas.Text = ""
    SatValCanvas.AutoButtonColor = false
    SatValCanvas.Parent = ColorPickerWindow

    local SVC_Corner = Instance.new("UICorner")
    SVC_Corner.CornerRadius = UDim.new(0, 4)
    SVC_Corner.Parent = SatValCanvas

    local WhiteGradFrame = Instance.new("Frame")
    WhiteGradFrame.Size = UDim2.new(1, 0, 1, 0)
    WhiteGradFrame.BackgroundColor3 = Color3.new(1, 1, 1)
    WhiteGradFrame.BorderSizePixel = 0
    WhiteGradFrame.Parent = SatValCanvas
    local WGC_Corner = Instance.new("UICorner")
    WGC_Corner.CornerRadius = UDim.new(0, 4)
    WGC_Corner.Parent = WhiteGradFrame
    local WhiteGrad = Instance.new("UIGradient")
    WhiteGrad.Color = ColorSequence.new(Color3.new(1, 1, 1))
    WhiteGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0),
        NumberSequenceKeypoint.new(1, 1)
    })
    WhiteGrad.Parent = WhiteGradFrame

    local BlackGradFrame = Instance.new("Frame")
    BlackGradFrame.Size = UDim2.new(1, 0, 1, 0)
    BlackGradFrame.BackgroundColor3 = Color3.new(0, 0, 0)
    BlackGradFrame.BorderSizePixel = 0
    BlackGradFrame.Parent = SatValCanvas
    local BGC_Corner = Instance.new("UICorner")
    BGC_Corner.CornerRadius = UDim.new(0, 4)
    BGC_Corner.Parent = BlackGradFrame
    local BlackGrad = Instance.new("UIGradient")
    BlackGrad.Color = ColorSequence.new(Color3.new(0, 0, 0))
    BlackGrad.Rotation = 90
    BlackGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(1, 0)
    })
    BlackGrad.Parent = BlackGradFrame

    local SVCursor = Instance.new("Frame")
    SVCursor.Size = UDim2.new(0, 6, 0, 6)
    SVCursor.BackgroundColor3 = Color3.new(255, 255, 255)
    SVCursor.Position = UDim2.new(1, -3, 0, -3)
    SVCursor.BorderSizePixel = 0
    SVCursor.Parent = SatValCanvas
    local SVCC = Instance.new("UICorner")
    SVCC.CornerRadius = UDim.new(1, 0)
    SVCC.Parent = SVCursor
    local SVCurStroke = Instance.new("UIStroke")
    SVCurStroke.Color = Color3.new(0, 0, 0)
    SVCurStroke.Thickness = 1
    SVCurStroke.Parent = SVCursor

    local HueSlider = Instance.new("TextButton")
    HueSlider.Size = UDim2.new(0, 15, 0, 120)
    HueSlider.Position = UDim2.new(0, 205, 0, 35)
    HueSlider.BackgroundColor3 = Color3.new(255, 255, 255)
    HueSlider.BorderSizePixel = 0
    HueSlider.Text = ""
    HueSlider.AutoButtonColor = false
    HueSlider.Parent = ColorPickerWindow

    local HSCorner = Instance.new("UICorner")
    HSCorner.CornerRadius = UDim.new(0, 3)
    HSCorner.Parent = HueSlider

    local HueGrad = Instance.new("UIGradient")
    HueGrad.Rotation = 90
    HueGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
        ColorSequenceKeypoint.new(0.17, Color3.fromRGB(255, 255, 0)),
        ColorSequenceKeypoint.new(0.33, Color3.fromRGB(0, 255, 0)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(0, 255, 255)),
        ColorSequenceKeypoint.new(0.67, Color3.fromRGB(0, 0, 255)),
        ColorSequenceKeypoint.new(0.83, Color3.fromRGB(255, 0, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 0, 0))
    })
    HueGrad.Parent = HueSlider

    local HueCursor = Instance.new("Frame")
    HueCursor.Size = UDim2.new(1, 4, 0, 4)
    HueCursor.Position = UDim2.new(0, -2, 0, -2)
    HueCursor.BackgroundColor3 = Color3.new(255, 255, 255)
    HueCursor.BorderSizePixel = 0
    HueCursor.Parent = HueSlider
    local HCCS = Instance.new("UIStroke")
    HCCS.Color = Color3.new(0, 0, 0)
    HCCS.Thickness = 1
    HCCS.Parent = HueCursor

    local OpacitySlider = Instance.new("TextButton")
    OpacitySlider.Size = UDim2.new(0, 180, 0, 12)
    OpacitySlider.Position = UDim2.new(0, 12, 0, 168)
    OpacitySlider.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
    OpacitySlider.BorderSizePixel = 0
    OpacitySlider.Text = ""
    OpacitySlider.AutoButtonColor = false
    OpacitySlider.Parent = ColorPickerWindow

    local OSCorner = Instance.new("UICorner")
    OSCorner.CornerRadius = UDim.new(0, 3)
    OSCorner.Parent = OpacitySlider

    local Checkerboard = Instance.new("Frame")
    Checkerboard.Size = UDim2.new(1, 0, 1, 0)
    Checkerboard.BackgroundTransparency = 1
    Checkerboard.ClipsDescendants = true
    Checkerboard.Parent = OpacitySlider
    local CBC = Instance.new("UICorner")
    CBC.CornerRadius = UDim.new(0, 3)
    CBC.Parent = Checkerboard

    for x = 0, 30 do
        for y = 0, 2 do
            if (x + y) % 2 == 0 then
                local sq = Instance.new("Frame")
                sq.Size = UDim2.new(0, 6, 0, 6)
                sq.Position = UDim2.new(0, x * 6, 0, y * 6)
                sq.BackgroundColor3 = Color3.fromRGB(60, 60, 65)
                sq.BorderSizePixel = 0
                sq.Parent = Checkerboard
            end
        end
    end

    local OpacityFill = Instance.new("Frame")
    OpacityFill.Size = UDim2.new(1, 0, 1, 0)
    OpacityFill.BorderSizePixel = 0
    OpacityFill.Parent = OpacitySlider
    local OFC = Instance.new("UICorner")
    OFC.CornerRadius = UDim.new(0, 3)
    OFC.Parent = OpacityFill

    local OpacityGrad = Instance.new("UIGradient")
    OpacityGrad.Parent = OpacityFill

    local OpacityCursor = Instance.new("Frame")
    OpacityCursor.Size = UDim2.new(0, 4, 1, 4)
    OpacityCursor.Position = UDim2.new(1, -2, 0, -2)
    OpacityCursor.BackgroundColor3 = Color3.new(255, 255, 255)
    OpacityCursor.BorderSizePixel = 0
    OpacityCursor.Parent = OpacitySlider
    local OCCS = Instance.new("UIStroke")
    OCCS.Color = Color3.new(0, 0, 0)
    OCCS.Thickness = 1
    OCCS.Parent = OpacityCursor

    local currentH, currentS, currentV = 1, 1, 1
    local currentAlpha = 1
    local activeCallback = nil
    local activeRegistryKey = nil
    local activePreviewBtn = nil

    local function updateColorPickerVisuals()
        local baseColor = Color3.fromHSV(currentH, 1, 1)
        local finalColor = Color3.fromHSV(currentH, currentS, currentV)
        
        SatValCanvas.BackgroundColor3 = baseColor
        
        OpacityGrad.Color = ColorSequence.new(finalColor)
        OpacityGrad.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1)
        })

        if activePreviewBtn then
            activePreviewBtn.BackgroundColor3 = finalColor
            activePreviewBtn.BackgroundTransparency = 1 - currentAlpha
        end

        if activeRegistryKey then
            Library.Registry[activeRegistryKey] = {finalColor.R, finalColor.G, finalColor.B, currentAlpha}
        end

        if activeCallback then
            activeCallback(finalColor, currentAlpha)
        end
    end

    local pickingSV = false
    local pickingHue = false
    local pickingAlpha = false

    local function updateSV(input)
        local relativeX = input.Position.X - SatValCanvas.AbsolutePosition.X
        local relativeY = input.Position.Y - SatValCanvas.AbsolutePosition.Y
        local s = math.clamp(relativeX / SatValCanvas.AbsoluteSize.X, 0, 1)
        local v = math.clamp(1 - (relativeY / SatValCanvas.AbsoluteSize.Y), 0, 1)
        currentS = s
        currentV = v
        SVCursor.Position = UDim2.new(s, -3, 1 - v, -3)
        updateColorPickerVisuals()
    end

    local function updateHue(input)
        local relativeY = input.Position.Y - HueSlider.AbsolutePosition.Y
        local h = math.clamp(relativeY / HueSlider.AbsoluteSize.Y, 0, 1)
        currentH = 1 - h
        HueCursor.Position = UDim2.new(0, -2, h, -2)
        updateColorPickerVisuals()
    end

    local function updateAlpha(input)
        local relativeX = input.Position.X - OpacitySlider.AbsolutePosition.X
        local a = math.clamp(relativeX / OpacitySlider.AbsoluteSize.X, 0, 1)
        currentAlpha = a
        OpacityCursor.Position = UDim2.new(a, -2, 0, -2)
        updateColorPickerVisuals()
    end

    SatValCanvas.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            pickingSV = true
            updateSV(input)
        end
    end)

    HueSlider.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            pickingHue = true
            updateHue(input)
        end
    end)

    OpacitySlider.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            pickingAlpha = true
            updateAlpha(input)
        end
    end)

    local conn1 = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            pickingSV = false
            pickingHue = false
            pickingAlpha = false
        end
    end)
    table.insert(self.Connections, conn1)

    local conn2 = UserInputService.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            if pickingSV then
                updateSV(input)
            elseif pickingHue then
                updateHue(input)
            elseif pickingAlpha then
                updateAlpha(input)
            end
        end
    end)
    table.insert(self.Connections, conn2)

    local conn3 = UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if input.KeyCode == self.ToggleKey then
            self:Toggle()
        end
    end)
    table.insert(self.Connections, conn3)

    local WindowObj = {
        Tabs = {},
        SelectedTab = nil
    }

    function WindowObj:CreateTab(tabName, icon)
        tabName = tabName or "Tab"
        icon = icon or ""
        
        local isImageIcon = (type(icon) == "string" and (icon:find("rbxassetid://") or icon:find("http") or tonumber(icon))) or type(icon) == "number"
        local iconAsset = isImageIcon and (tonumber(icon) and "rbxassetid://" .. icon or icon) or nil

        -- Tab Button Container
        local TabBtn = Instance.new("TextButton")
        TabBtn.Name = tabName .. "_Btn"
        TabBtn.Size = UDim2.new(0, 85, 0, 26)
        TabBtn.BackgroundColor3 = Library.Theme.Active
        TabBtn.BackgroundTransparency = 1
        TabBtn.Text = ""
        TabBtn.AutoButtonColor = false
        TabBtn.Parent = TabsFrame

        local TabBtnCorner = Instance.new("UICorner")
        TabBtnCorner.CornerRadius = UDim.new(0, 5)
        TabBtnCorner.Parent = TabBtn

        local TabBtnStroke = Instance.new("UIStroke")
        TabBtnStroke.Color = Library.Theme.Border
        TabBtnStroke.Thickness = 1
        TabBtnStroke.Enabled = false
        TabBtnStroke.Parent = TabBtn
        Library:RegisterAccent(TabBtnStroke, "Color")

        -- Icon Element
        local IconElement
        if isImageIcon then
            IconElement = Instance.new("ImageLabel")
            IconElement.Image = iconAsset
            IconElement.ImageColor3 = Library.Theme.TextMuted
            IconElement.BackgroundTransparency = 1
            IconElement.Size = UDim2.new(0, 14, 0, 14)
            IconElement.Parent = TabBtn
        else
            IconElement = Instance.new("TextLabel")
            IconElement.Text = icon
            IconElement.TextColor3 = Library.Theme.TextMuted
            IconElement.TextSize = 12
            IconElement.Font = Enum.Font.GothamMedium
            IconElement.BackgroundTransparency = 1
            IconElement.Size = UDim2.new(0, 14, 0, 14)
            IconElement.Parent = TabBtn
        end

        -- Tab Text Label
        local TabBtnLabel = Instance.new("TextLabel")
        TabBtnLabel.Size = UDim2.new(1, -26, 1, 0)
        TabBtnLabel.Position = UDim2.new(0, 26, 0, 0)
        TabBtnLabel.BackgroundTransparency = 1
        TabBtnLabel.Text = tabName
        TabBtnLabel.TextColor3 = Library.Theme.TextMuted
        TabBtnLabel.TextSize = 11
        TabBtnLabel.Font = Enum.Font.GothamMedium
        TabBtnLabel.TextXAlignment = Enum.TextXAlignment.Left
        TabBtnLabel.Visible = false
        TabBtnLabel.Parent = TabBtn

        -- Tab Page Container
        local TabPage = Instance.new("Frame")
        TabPage.Name = tabName .. "_Page"
        TabPage.Size = UDim2.new(1, 0, 1, 0)
        TabPage.BackgroundTransparency = 1
        TabPage.Visible = false
        TabPage.Parent = PagesContainer

        -- Sub-tabs vertical list (hidden by default)
        local SubTabsFrame = Instance.new("ScrollingFrame")
        SubTabsFrame.Name = "SubTabsFrame"
        SubTabsFrame.Size = UDim2.new(0, 90, 1, -20)
        SubTabsFrame.Position = UDim2.new(0, 15, 0, 10)
        SubTabsFrame.BackgroundTransparency = 1
        SubTabsFrame.BorderSizePixel = 0
        SubTabsFrame.ScrollBarThickness = 0
        SubTabsFrame.Visible = false
        SubTabsFrame.Parent = TabPage

        local SubTabsLayout = Instance.new("UIListLayout")
        SubTabsLayout.Padding = UDim.new(0, 6)
        SubTabsLayout.Parent = SubTabsFrame

        -- Main column container (Full width by default)
        local MainColumnsFrame = Instance.new("Frame")
        MainColumnsFrame.Name = "MainColumnsFrame"
        MainColumnsFrame.Size = UDim2.new(1, 0, 1, 0)
        MainColumnsFrame.BackgroundTransparency = 1
        MainColumnsFrame.Parent = TabPage

        -- Default Columns (If no sub-tabs are used)
        local LeftColumn = Instance.new("ScrollingFrame")
        LeftColumn.Name = "LeftColumn"
        LeftColumn.Size = UDim2.new(0, 270, 1, -20)
        LeftColumn.Position = UDim2.new(0, 15, 0, 10)
        LeftColumn.BackgroundTransparency = 1
        LeftColumn.BorderSizePixel = 0
        LeftColumn.ScrollBarThickness = 3
        LeftColumn.ScrollBarImageColor3 = Library.Theme.Accent
        LeftColumn.Parent = MainColumnsFrame
        Library:RegisterAccent(LeftColumn, "ScrollBarImageColor3")

        local L_Layout = Instance.new("UIListLayout")
        L_Layout.SortOrder = Enum.SortOrder.LayoutOrder
        L_Layout.Padding = UDim.new(0, 10)
        L_Layout.Parent = LeftColumn
        L_Layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            LeftColumn.CanvasSize = UDim2.new(0, 0, 0, L_Layout.AbsoluteContentSize.Y + 10)
        end)

        local RightColumn = Instance.new("ScrollingFrame")
        RightColumn.Name = "RightColumn"
        RightColumn.Size = UDim2.new(0, 270, 1, -20)
        RightColumn.Position = UDim2.new(0, 295, 0, 10)
        RightColumn.BackgroundTransparency = 1
        RightColumn.BorderSizePixel = 0
        RightColumn.ScrollBarThickness = 3
        RightColumn.ScrollBarImageColor3 = Library.Theme.Accent
        RightColumn.Parent = MainColumnsFrame
        Library:RegisterAccent(RightColumn, "ScrollBarImageColor3")

        local R_Layout = Instance.new("UIListLayout")
        R_Layout.SortOrder = Enum.SortOrder.LayoutOrder
        R_Layout.Padding = UDim.new(0, 10)
        R_Layout.Parent = RightColumn
        R_Layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
            RightColumn.CanvasSize = UDim2.new(0, 0, 0, R_Layout.AbsoluteContentSize.Y + 10)
        end)

        local TabObj = {
            Page = TabPage,
            Button = TabBtn,
            IconElement = IconElement,
            TextLabel = TabBtnLabel,
            Name = tabName,
            IsImageIcon = isImageIcon,
            HasSubTabs = false,
            SubTabs = {},
            SelectedSubTab = nil
        }

        local function selectTab()
            if WindowObj.SelectedTab == TabObj then return end
            
            if WindowObj.SelectedTab then
                local prev = WindowObj.SelectedTab
                prev.Page.Visible = false
                prev.TextLabel.Visible = false
                prev.Button.Size = UDim2.new(0, 30, 0, 26)
                prev.Button.UIStroke.Enabled = false
                prev.IconElement.Position = UDim2.new(0.5, -7, 0.5, -7)
                
                if prev.IsImageIcon then
                    tween(prev.IconElement, TweenInfo.new(0.15), {ImageColor3 = Library.Theme.TextMuted})
                else
                    tween(prev.IconElement, TweenInfo.new(0.15), {TextColor3 = Library.Theme.TextMuted})
                end
                tween(prev.Button, TweenInfo.new(0.15), {BackgroundTransparency = 1})
            end

            WindowObj.SelectedTab = TabObj
            TabPage.Visible = true
            TabBtn.Size = UDim2.new(0, 85, 0, 26)
            TabBtnStroke.Enabled = true
            IconElement.Position = UDim2.new(0, 8, 0.5, -7)
            TabBtnLabel.Visible = true
            
            if isImageIcon then
                tween(IconElement, TweenInfo.new(0.15), {ImageColor3 = Library.Theme.Text})
            else
                tween(IconElement, TweenInfo.new(0.15), {TextColor3 = Library.Theme.Text})
            end
            tween(TabBtnLabel, TweenInfo.new(0.15), {TextColor3 = Library.Theme.Text})
            tween(TabBtn, TweenInfo.new(0.15), {BackgroundTransparency = 0})
        end

        TabBtn.MouseButton1Click:Connect(selectTab)

        TabBtn.MouseEnter:Connect(function()
            if WindowObj.SelectedTab ~= TabObj then
                if isImageIcon then
                    tween(IconElement, TweenInfo.new(0.15), {ImageColor3 = Library.Theme.Text})
                else
                    tween(IconElement, TweenInfo.new(0.15), {TextColor3 = Library.Theme.Text})
                end
            end
        end)

        TabBtn.MouseLeave:Connect(function()
            if WindowObj.SelectedTab ~= TabObj then
                if isImageIcon then
                    tween(IconElement, TweenInfo.new(0.15), {ImageColor3 = Library.Theme.TextMuted})
                else
                    tween(IconElement, TweenInfo.new(0.15), {TextColor3 = Library.Theme.TextMuted})
                end
            end
        end)

        if WindowObj.SelectedTab then
            TabBtn.Size = UDim2.new(0, 30, 0, 26)
            IconElement.Position = UDim2.new(0.5, -7, 0.5, -7)
        else
            selectTab()
        end

        -- Section creator helper
        local function setupSectionCreator(leftCol, rightCol)
            local TabSectionObj = {}

            function TabSectionObj:CreateSection(sectionName, column)
                column = column or "Left"
                local targetColumn = (column == "Right") and rightCol or leftCol

                local SectionFrame = Instance.new("Frame")
                SectionFrame.Name = sectionName .. "_Section"
                SectionFrame.Size = UDim2.new(1, -4, 0, 0)
                SectionFrame.AutomaticSize = Enum.AutomaticSize.Y
                SectionFrame.BackgroundColor3 = Library.Theme.Card
                SectionFrame.BorderSizePixel = 0
                SectionFrame.Parent = targetColumn

                local SFC_Corner = Instance.new("UICorner")
                SFC_Corner.CornerRadius = UDim.new(0, 5)
                SFC_Corner.Parent = SectionFrame

                local SFC_Stroke = Instance.new("UIStroke")
                SFC_Stroke.Color = Library.Theme.Border
                SFC_Stroke.Thickness = 1
                SFC_Stroke.Parent = SectionFrame

                local TitleLabel = Instance.new("TextLabel")
                TitleLabel.Size = UDim2.new(1, 0, 0, 26)
                TitleLabel.Position = UDim2.new(0, 10, 0, 0)
                TitleLabel.BackgroundTransparency = 1
                TitleLabel.Text = sectionName
                TitleLabel.TextColor3 = Library.Theme.Text
                TitleLabel.TextSize = 11
                TitleLabel.Font = Enum.Font.GothamBold
                TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
                TitleLabel.Parent = SectionFrame

                local ContentFrame = Instance.new("Frame")
                ContentFrame.Name = "Content"
                ContentFrame.Size = UDim2.new(1, 0, 0, 0)
                ContentFrame.Position = UDim2.new(0, 0, 0, 24)
                ContentFrame.AutomaticSize = Enum.AutomaticSize.Y
                ContentFrame.BackgroundTransparency = 1
                ContentFrame.Parent = SectionFrame

                local ContentLayout = Instance.new("UIListLayout")
                ContentLayout.SortOrder = Enum.SortOrder.LayoutOrder
                ContentLayout.Padding = UDim.new(0, 8)
                ContentLayout.Parent = ContentFrame

                local ContentPadding = Instance.new("UIPadding")
                ContentPadding.PaddingLeft = UDim.new(0, 10)
                ContentPadding.PaddingRight = UDim.new(0, 10)
                ContentPadding.PaddingTop = UDim.new(0, 4)
                ContentPadding.PaddingBottom = UDim.new(0, 10)
                ContentPadding.Parent = ContentFrame

                local ComponentObj = {}

                -- TOGGLE COMPONENT
                function ComponentObj:CreateToggle(toggleOptions)
                    toggleOptions = toggleOptions or {}
                    local toggleName = toggleOptions.Name or "Toggle"
                    local defaultState = toggleOptions.Default or false
                    local callback = toggleOptions.Callback or function() end
                    local configName = toggleOptions.ConfigName or toggleName

                    local ToggleRow = Instance.new("Frame")
                    ToggleRow.Size = UDim2.new(1, 0, 0, 20)
                    ToggleRow.BackgroundTransparency = 1
                    ToggleRow.Parent = ContentFrame

                    local Checkbox = Instance.new("Frame")
                    Checkbox.Size = UDim2.new(0, 12, 0, 12)
                    Checkbox.Position = UDim2.new(0, 0, 0.5, -6)
                    Checkbox.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                    Checkbox.BorderSizePixel = 0
                    Checkbox.Parent = ToggleRow

                    local CBCorner = Instance.new("UICorner")
                    CBCorner.CornerRadius = UDim.new(0, 2)
                    CBCorner.Parent = Checkbox

                    local CBStroke = Instance.new("UIStroke")
                    CBStroke.Color = Library.Theme.Border
                    CBStroke.Thickness = 1
                    CBStroke.Parent = Checkbox

                    local Checkmark = Instance.new("TextLabel")
                    Checkmark.Size = UDim2.new(1, 0, 1, 0)
                    Checkmark.BackgroundTransparency = 1
                    Checkmark.Text = "✓"
                    Checkmark.TextColor3 = Color3.new(255, 255, 255)
                    Checkmark.TextSize = 10
                    Checkmark.Font = Enum.Font.GothamBold
                    Checkmark.Visible = false
                    Checkmark.Parent = Checkbox

                    local TglLabel = Instance.new("TextLabel")
                    TglLabel.Size = UDim2.new(1, -70, 1, 0)
                    TglLabel.Position = UDim2.new(0, 18, 0, 0)
                    TglLabel.BackgroundTransparency = 1
                    TglLabel.Text = toggleName
                    TglLabel.TextColor3 = Library.Theme.TextMuted
                    TglLabel.TextSize = 11
                    TglLabel.Font = Enum.Font.GothamMedium
                    TglLabel.TextXAlignment = Enum.TextXAlignment.Left
                    TglLabel.Parent = ToggleRow

                    local ClickArea = Instance.new("TextButton")
                    ClickArea.Size = UDim2.new(1, -60, 1, 0)
                    ClickArea.BackgroundTransparency = 1
                    ClickArea.Text = ""
                    ClickArea.Parent = ToggleRow

                    local RightControls = Instance.new("Frame")
                    RightControls.Size = UDim2.new(0, 60, 1, 0)
                    RightControls.Position = UDim2.new(1, 0, 0, 0)
                    RightControls.AnchorPoint = Vector2.new(1, 0)
                    RightControls.BackgroundTransparency = 1
                    RightControls.Parent = ToggleRow

                    local RCLayout = Instance.new("UIListLayout")
                    RCLayout.FillDirection = Enum.FillDirection.Horizontal
                    RCLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
                    RCLayout.VerticalAlignment = Enum.VerticalAlignment.Center
                    RCLayout.Padding = UDim.new(0, 6)
                    RCLayout.Parent = RightControls

                    local state = defaultState

                    local function updateVisual()
                        Checkmark.Visible = state
                        local targetBg = state and Library.Theme.Accent or Color3.fromRGB(20, 20, 24)
                        local targetText = state and Library.Theme.Text or Library.Theme.TextMuted
                        
                        if state then
                            Library:RegisterAccent(Checkbox, "BackgroundColor3")
                        else
                            Checkbox.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                        end
                        tween(TglLabel, TweenInfo.new(0.12), {TextColor3 = targetText})
                    end

                    local function toggle()
                        state = not state
                        updateVisual()
                        Library.Registry[configName] = state
                        callback(state)
                    end

                    ClickArea.MouseButton1Click:Connect(toggle)
                    updateVisual()

                    ClickArea.MouseEnter:Connect(function()
                        if not state then
                            tween(TglLabel, TweenInfo.new(0.12), {TextColor3 = Library.Theme.Text})
                        end
                    end)
                    ClickArea.MouseLeave:Connect(function()
                        if not state then
                            tween(TglLabel, TweenInfo.new(0.12), {TextColor3 = Library.Theme.TextMuted})
                        end
                    end)

                    if toggleOptions.Tooltip then Library:AttachTooltip(ToggleRow, toggleOptions.Tooltip) end

                    Library.Registry[configName] = state

                    -- Inline Color Picker
                    if toggleOptions.HasColor then
                        local colorVal = toggleOptions.ColorDefault or Color3.fromRGB(255, 0, 0)
                        local alphaVal = toggleOptions.ColorAlpha or 1
                        local colorCallback = toggleOptions.ColorCallback or function() end
                        local colorConfigName = configName .. "_Color"

                        local ColorBtn = Instance.new("TextButton")
                        ColorBtn.Size = UDim2.new(0, 18, 0, 12)
                        ColorBtn.BackgroundColor3 = colorVal
                        ColorBtn.BackgroundTransparency = 1 - alphaVal
                        ColorBtn.BorderSizePixel = 0
                        ColorBtn.Text = ""
                        ColorBtn.Parent = RightControls

                        local CBCorner = Instance.new("UICorner")
                        CBCorner.CornerRadius = UDim.new(0, 2)
                        CBCorner.Parent = ColorBtn

                        local CBStroke = Instance.new("UIStroke")
                        CBStroke.Color = Library.Theme.Border
                        CBStroke.Thickness = 1
                        CBStroke.Parent = ColorBtn

                        ColorBtn.MouseButton1Click:Connect(function()
                            currentH, currentS, currentV = colorVal:ToHSV()
                            currentAlpha = alphaVal
                            activeCallback = colorCallback
                            activeRegistryKey = colorConfigName
                            activePreviewBtn = ColorBtn

                            ColorPickerWindow.Position = UDim2.new(0, MainFrame.AbsolutePosition.X + MainFrame.AbsoluteSize.X + 10, 0, MainFrame.AbsolutePosition.Y)
                            
                            SVCursor.Position = UDim2.new(currentS, -3, 1 - currentV, -3)
                            HueCursor.Position = UDim2.new(0, -2, 1 - currentH, -2)
                            OpacityCursor.Position = UDim2.new(currentAlpha, -2, 0, -2)

                            updateColorPickerVisuals()
                            ColorPickerWindow.Visible = true
                        end)

                        Library.Registry[colorConfigName] = {colorVal.R, colorVal.G, colorVal.B, alphaVal}
                    end

                    -- Inline Keybind
                    if toggleOptions.HasKeybind then
                        local bindKey = toggleOptions.KeybindDefault or Enum.KeyCode.Unknown
                        local bindCallback = toggleOptions.KeybindCallback or function() end
                        local bindConfigName = configName .. "_Keybind"
                        local listening = false

                        local KeybindBtn = Instance.new("TextButton")
                        KeybindBtn.Size = UDim2.new(0, 32, 0, 16)
                        KeybindBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                        KeybindBtn.Text = bindKey == Enum.KeyCode.Unknown and "[None]" or "[" .. bindKey.Name .. "]"
                        KeybindBtn.TextColor3 = Library.Theme.TextMuted
                        KeybindBtn.TextSize = 9
                        KeybindBtn.Font = Enum.Font.Gotham
                        KeybindBtn.Parent = RightControls

                        local KBC = Instance.new("UICorner")
                        KBC.CornerRadius = UDim.new(0, 3)
                        KBC.Parent = KeybindBtn

                        local KBS = Instance.new("UIStroke")
                        KBS.Color = Library.Theme.Border
                        KBS.Thickness = 1
                        KBS.Parent = KeybindBtn

                        KeybindBtn.MouseButton1Click:Connect(function()
                            listening = true
                            KeybindBtn.Text = "[...]"
                            Library:RegisterAccent(KeybindBtn, "TextColor3")
                        end)

                        local conn = UserInputService.InputBegan:Connect(function(input, gpe)
                            if gpe then return end
                            if listening then
                                listening = false
                                if input.KeyCode == Enum.KeyCode.Escape then
                                    bindKey = Enum.KeyCode.Unknown
                                    KeybindBtn.Text = "[None]"
                                else
                                    bindKey = input.KeyCode
                                    KeybindBtn.Text = "[" .. bindKey.Name .. "]"
                                end
                                KeybindBtn.TextColor3 = Library.Theme.TextMuted
                                Library.Registry[bindConfigName] = bindKey.Value
                                bindCallback(bindKey)
                            else
                                if bindKey ~= Enum.KeyCode.Unknown and input.KeyCode == bindKey then
                                    toggle()
                                    Library:UpdateKeybindList(toggleName, state, "Toggled")
                                end
                            end
                        end)
                        table.insert(Library.Connections, conn)

                        Library.Registry[bindConfigName] = bindKey.Value
                    end

                    local ToggleController = {}
                    function ToggleController:Set(val)
                        state = val
                        updateVisual()
                        Library.Registry[configName] = state
                        callback(state)
                    end

                    Library.Controllers[configName] = ToggleController
                    return ToggleController
                end

                -- STANDALONE KEYBIND
                function ComponentObj:CreateKeybind(kbOptions)
                    kbOptions = kbOptions or {}
                    local kbName = kbOptions.Name or "Keybind"
                    local defaultKey = kbOptions.Default or Enum.KeyCode.Unknown
                    local callback = kbOptions.Callback or function() end
                    local configName = kbOptions.ConfigName or kbName
                    local listening = false
                    local bindKey = defaultKey
                    local active = false

                    local KeybindRow = Instance.new("Frame")
                    KeybindRow.Size = UDim2.new(1, 0, 0, 20)
                    KeybindRow.BackgroundTransparency = 1
                    KeybindRow.Parent = ContentFrame

                    local KbLabel = Instance.new("TextLabel")
                    KbLabel.Size = UDim2.new(1, -45, 1, 0)
                    KbLabel.BackgroundTransparency = 1
                    KbLabel.Text = kbName
                    KbLabel.TextColor3 = Library.Theme.TextMuted
                    KbLabel.TextSize = 11
                    KbLabel.Font = Enum.Font.GothamMedium
                    KbLabel.TextXAlignment = Enum.TextXAlignment.Left
                    KbLabel.Parent = KeybindRow

                    local KeybindBtn = Instance.new("TextButton")
                    KeybindBtn.Size = UDim2.new(0, 40, 0, 16)
                    KeybindBtn.Position = UDim2.new(1, -40, 0.5, -8)
                    KeybindBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                    KeybindBtn.Text = bindKey == Enum.KeyCode.Unknown and "[None]" or "[" .. bindKey.Name .. "]"
                    KeybindBtn.TextColor3 = Library.Theme.TextMuted
                    KeybindBtn.TextSize = 9
                    KeybindBtn.Font = Enum.Font.Gotham
                    KeybindBtn.Parent = KeybindRow

                    local KBC = Instance.new("UICorner")
                    KBC.CornerRadius = UDim.new(0, 3)
                    KBC.Parent = KeybindBtn

                    local KBS = Instance.new("UIStroke")
                    KBS.Color = Library.Theme.Border
                    KBS.Thickness = 1
                    KBS.Parent = KeybindBtn

                    KeybindBtn.MouseButton1Click:Connect(function()
                        listening = true
                        KeybindBtn.Text = "[...]"
                        Library:RegisterAccent(KeybindBtn, "TextColor3")
                    end)

                    local conn = UserInputService.InputBegan:Connect(function(input, gpe)
                        if gpe then return end
                        if listening then
                            listening = false
                            if input.KeyCode == Enum.KeyCode.Escape then
                                bindKey = Enum.KeyCode.Unknown
                                KeybindBtn.Text = "[None]"
                            else
                                bindKey = input.KeyCode
                                KeybindBtn.Text = "[" .. bindKey.Name .. "]"
                            end
                            KeybindBtn.TextColor3 = Library.Theme.TextMuted
                            Library.Registry[configName] = bindKey.Value
                            callback(bindKey)
                        else
                            if bindKey ~= Enum.KeyCode.Unknown and input.KeyCode == bindKey then
                                active = not active
                                callback(bindKey)
                                Library:UpdateKeybindList(kbName, active, active and "Active" or "Inactive")
                            end
                        end
                    end)
                    table.insert(Library.Connections, conn)

                    KeybindBtn.MouseEnter:Connect(function()
                        if not listening then
                            tween(KeybindBtn, TweenInfo.new(0.12), {BackgroundColor3 = Library.Theme.Hover})
                        end
                    end)
                    KeybindBtn.MouseLeave:Connect(function()
                        if not listening then
                            tween(KeybindBtn, TweenInfo.new(0.12), {BackgroundColor3 = Color3.fromRGB(20, 20, 24)})
                        end
                    end)

                    if kbOptions.Tooltip then Library:AttachTooltip(KeybindRow, kbOptions.Tooltip) end

                    Library.Registry[configName] = bindKey.Value

                    local KeybindController = {}
                    function KeybindController:Set(key)
                        bindKey = key
                        KeybindBtn.Text = bindKey == Enum.KeyCode.Unknown and "[None]" or "[" .. bindKey.Name .. "]"
                        Library.Registry[configName] = bindKey.Value
                        callback(bindKey)
                    end

                    Library.Controllers[configName] = KeybindController
                    return KeybindController
                end

                -- STANDALONE TEXTBOX
                function ComponentObj:CreateTextbox(tbOptions)
                    tbOptions = tbOptions or {}
                    local tbName = tbOptions.Name or "Textbox"
                    local placeholder = tbOptions.Placeholder or "Enter text..."
                    local defaultText = tbOptions.Default or ""
                    local callback = tbOptions.Callback or function() end
                    local configName = tbOptions.ConfigName or tbName

                    local TextboxContainer = Instance.new("Frame")
                    TextboxContainer.Size = UDim2.new(1, 0, 0, 44)
                    TextboxContainer.BackgroundTransparency = 1
                    TextboxContainer.Parent = ContentFrame

                    local TbLabel = Instance.new("TextLabel")
                    TbLabel.Size = UDim2.new(1, 0, 0, 14)
                    TbLabel.BackgroundTransparency = 1
                    TbLabel.Text = tbName
                    TbLabel.TextColor3 = Library.Theme.TextMuted
                    TbLabel.TextSize = 11
                    TbLabel.Font = Enum.Font.GothamMedium
                    TbLabel.TextXAlignment = Enum.TextXAlignment.Left
                    TbLabel.Parent = TextboxContainer

                    local InputBox = Instance.new("Frame")
                    InputBox.Size = UDim2.new(1, 0, 0, 24)
                    InputBox.Position = UDim2.new(0, 0, 0, 18)
                    InputBox.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                    InputBox.Parent = TextboxContainer

                    local IBCorner = Instance.new("UICorner")
                    IBCorner.CornerRadius = UDim.new(0, 3)
                    IBCorner.Parent = InputBox

                    local IBStroke = Instance.new("UIStroke")
                    IBStroke.Color = Library.Theme.Border
                    IBStroke.Thickness = 1
                    IBStroke.Parent = InputBox

                    local TextBox = Instance.new("TextBox")
                    TextBox.Size = UDim2.new(1, -20, 1, 0)
                    TextBox.Position = UDim2.new(0, 10, 0, 0)
                    TextBox.BackgroundTransparency = 1
                    TextBox.Text = defaultText
                    TextBox.PlaceholderText = placeholder
                    TextBox.PlaceholderColor3 = Library.Theme.TextMuted
                    TextBox.TextColor3 = Library.Theme.Text
                    TextBox.TextSize = 11
                    TextBox.Font = Enum.Font.Gotham
                    TextBox.TextXAlignment = Enum.TextXAlignment.Left
                    TextBox.ClearTextOnFocus = false
                    TextBox.Parent = InputBox

                    TextBox.FocusLost:Connect(function(enterPressed)
                        local text = TextBox.Text
                        Library.Registry[configName] = text
                        callback(text)
                    end)

                    if tbOptions.Tooltip then Library:AttachTooltip(TextboxContainer, tbOptions.Tooltip) end

                    Library.Registry[configName] = defaultText

                    local TextboxController = {}
                    function TextboxController:Set(text)
                        TextBox.Text = text
                        Library.Registry[configName] = text
                        callback(text)
                    end

                    Library.Controllers[configName] = TextboxController
                    return TextboxController
                end

                -- MULTI-SELECT DROPDOWN
                function ComponentObj:CreateMultiDropdown(mddOptions)
                    mddOptions = mddOptions or {}
                    local mddName = mddOptions.Name or "Multi Dropdown"
                    local optionsList = mddOptions.Options or {}
                    local defaultList = mddOptions.Default or {}
                    local callback = mddOptions.Callback or function() end
                    local configName = mddOptions.ConfigName or mddName

                    local DropdownContainer = Instance.new("Frame")
                    DropdownContainer.Size = UDim2.new(1, 0, 0, 44)
                    DropdownContainer.BackgroundTransparency = 1
                    DropdownContainer.Parent = ContentFrame

                    local DdLabel = Instance.new("TextLabel")
                    DdLabel.Size = UDim2.new(1, 0, 0, 14)
                    DdLabel.BackgroundTransparency = 1
                    DdLabel.Text = mddName
                    DdLabel.TextColor3 = Library.Theme.TextMuted
                    DdLabel.TextSize = 11
                    DdLabel.Font = Enum.Font.GothamMedium
                    DdLabel.TextXAlignment = Enum.TextXAlignment.Left
                    DdLabel.Parent = DropdownContainer

                    local SelectorBtn = Instance.new("TextButton")
                    SelectorBtn.Size = UDim2.new(1, 0, 0, 24)
                    SelectorBtn.Position = UDim2.new(0, 0, 0, 18)
                    SelectorBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                    SelectorBtn.Text = ""
                    SelectorBtn.AutoButtonColor = false
                    SelectorBtn.Parent = DropdownContainer

                    local SBCorner = Instance.new("UICorner")
                    SBCorner.CornerRadius = UDim.new(0, 3)
                    SBCorner.Parent = SelectorBtn

                    local SBStroke = Instance.new("UIStroke")
                    SBStroke.Color = Library.Theme.Border
                    SBStroke.Thickness = 1
                    SBStroke.Parent = SelectorBtn

                    local SelectedText = Instance.new("TextLabel")
                    SelectedText.Size = UDim2.new(1, -30, 1, 0)
                    SelectedText.Position = UDim2.new(0, 10, 0, 0)
                    SelectedText.BackgroundTransparency = 1
                    SelectedText.TextColor3 = Library.Theme.TextMuted
                    SelectedText.TextSize = 11
                    SelectedText.Font = Enum.Font.Gotham
                    SelectedText.TextXAlignment = Enum.TextXAlignment.Left
                    SelectedText.Parent = SelectorBtn

                    local ArrowsIcon = Instance.new("TextLabel")
                    ArrowsIcon.Size = UDim2.new(0, 20, 1, 0)
                    ArrowsIcon.Position = UDim2.new(1, -25, 0, 0)
                    ArrowsIcon.BackgroundTransparency = 1
                    ArrowsIcon.Text = "⇅"
                    ArrowsIcon.TextColor3 = Library.Theme.TextMuted
                    ArrowsIcon.TextSize = 11
                    ArrowsIcon.Font = Enum.Font.Gotham
                    ArrowsIcon.Parent = SelectorBtn

                    local ListContainer = Instance.new("Frame")
                    ListContainer.Size = UDim2.new(0, 0, 0, 0)
                    ListContainer.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                    ListContainer.Visible = false
                    ListContainer.ClipsDescendants = true
                    ListContainer.ZIndex = 100
                    ListContainer.Parent = ScreenGui

                    local LCCorner = Instance.new("UICorner")
                    LCCorner.CornerRadius = UDim.new(0, 3)
                    LCCorner.Parent = ListContainer

                    local LCStroke = Instance.new("UIStroke")
                    LCStroke.Color = Library.Theme.Border
                    LCStroke.Thickness = 1
                    LCStroke.Parent = ListContainer

                    local ListScroll = Instance.new("ScrollingFrame")
                    ListScroll.Size = UDim2.new(1, 0, 1, 0)
                    ListScroll.BackgroundTransparency = 1
                    ListScroll.BorderSizePixel = 0
                    ListScroll.ScrollBarThickness = 2
                    ListScroll.ScrollBarImageColor3 = Library.Theme.Border
                    ListScroll.Parent = ListContainer

                    local ListLayout = Instance.new("UIListLayout")
                    ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
                    ListLayout.Parent = ListScroll

                    local selectedItems = {}
                    for _, v in ipairs(defaultList) do
                        selectedItems[v] = true
                    end

                    local optionButtons = {}
                    local isOpen = false

                    local function updateDropdownText()
                        local selected = {}
                        for opt, val in pairs(selectedItems) do
                            if val then
                                table.insert(selected, opt)
                            end
                        end
                        table.sort(selected)
                        if #selected == 0 then
                            SelectedText.Text = "None"
                        else
                            SelectedText.Text = table.concat(selected, ", ")
                        end
                        Library.Registry[configName] = selected
                        callback(selected)
                    end

                    for idx, optionName in ipairs(optionsList) do
                        local OptBtn = Instance.new("TextButton")
                        OptBtn.Size = UDim2.new(1, 0, 0, 24)
                        OptBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                        OptBtn.BackgroundTransparency = 1
                        OptBtn.Text = "  " .. tostring(optionName)
                        OptBtn.TextColor3 = selectedItems[optionName] and Library.Theme.Text or Library.Theme.TextMuted
                        OptBtn.TextSize = 11
                        OptBtn.Font = Enum.Font.Gotham
                        OptBtn.TextXAlignment = Enum.TextXAlignment.Left
                        OptBtn.Parent = ListScroll

                        if selectedItems[optionName] then
                            Library:RegisterAccent(OptBtn, "TextColor3")
                        end

                        OptBtn.MouseButton1Click:Connect(function()
                            selectedItems[optionName] = not selectedItems[optionName]
                            if selectedItems[optionName] then
                                Library:RegisterAccent(OptBtn, "TextColor3")
                            else
                                OptBtn.TextColor3 = Library.Theme.TextMuted
                            end
                            updateDropdownText()
                        end)
                        optionButtons[optionName] = OptBtn
                    end

                    ListScroll.CanvasSize = UDim2.new(0, 0, 0, #optionsList * 24)

                    local function closeList()
                        if not isOpen then return end
                        isOpen = false
                        local t = tween(ListContainer, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                            Size = UDim2.new(0, ListContainer.AbsoluteSize.X, 0, 0)
                        })
                        t.Completed:Connect(function()
                            if not isOpen then ListContainer.Visible = false end
                        end)
                    end

                    local function openList()
                        isOpen = true
                        local targetH = math.min(#optionsList * 24, 120)
                        ListContainer.Position = UDim2.new(0, SelectorBtn.AbsolutePosition.X, 0, SelectorBtn.AbsolutePosition.Y + SelectorBtn.AbsoluteSize.Y + 2)
                        ListContainer.Size = UDim2.new(0, SelectorBtn.AbsoluteSize.X, 0, 0)
                        ListContainer.Visible = true
                        tween(ListContainer, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                            Size = UDim2.new(0, SelectorBtn.AbsoluteSize.X, 0, targetH)
                        })
                    end

                    SelectorBtn.MouseButton1Click:Connect(function()
                        if isOpen then closeList() else openList() end
                    end)

                    SelectorBtn.MouseEnter:Connect(function()
                        tween(SelectorBtn, TweenInfo.new(0.12), {BackgroundColor3 = Library.Theme.Hover})
                    end)
                    SelectorBtn.MouseLeave:Connect(function()
                        tween(SelectorBtn, TweenInfo.new(0.12), {BackgroundColor3 = Color3.fromRGB(20, 20, 24)})
                    end)

                    ensureSharedInput()
                    table.insert(dropdownClosers, function(input)
                        if not isOpen then return end
                        if not pointInside(ListContainer, input.Position) and not pointInside(SelectorBtn, input.Position) then
                            closeList()
                        end
                    end)

                    if mddOptions.Tooltip then Library:AttachTooltip(DropdownContainer, mddOptions.Tooltip) end

                    updateDropdownText()

                    local MultiDropdownController = {}
                    function MultiDropdownController:Set(newList)
                        selectedItems = {}
                        for _, v in ipairs(newList) do
                            selectedItems[v] = true
                        end
                        for opt, btn in pairs(optionButtons) do
                            if selectedItems[opt] then
                                Library:RegisterAccent(btn, "TextColor3")
                            else
                                btn.TextColor3 = Library.Theme.TextMuted
                            end
                        end
                        updateDropdownText()
                    end
                    return MultiDropdownController
                end

                -- SLIDER COMPONENT
                function ComponentObj:CreateSlider(sliderOptions)
                    sliderOptions = sliderOptions or {}
                    local sliderName = sliderOptions.Name or "Slider"
                    local min = sliderOptions.Min or 0
                    local max = sliderOptions.Max or 100
                    local default = sliderOptions.Default or min
                    local suffix = sliderOptions.Suffix or ""
                    local callback = sliderOptions.Callback or function() end
                    local configName = sliderOptions.ConfigName or sliderName

                    local SliderContainer = Instance.new("Frame")
                    SliderContainer.Size = UDim2.new(1, 0, 0, 32)
                    SliderContainer.BackgroundTransparency = 1
                    SliderContainer.Parent = ContentFrame

                    local TextRow = Instance.new("Frame")
                    TextRow.Size = UDim2.new(1, 0, 0, 16)
                    TextRow.BackgroundTransparency = 1
                    TextRow.Parent = SliderContainer

                    local SldLabel = Instance.new("TextLabel")
                    SldLabel.Size = UDim2.new(1, -80, 1, 0)
                    SldLabel.BackgroundTransparency = 1
                    SldLabel.Text = sliderName
                    SldLabel.TextColor3 = Library.Theme.TextMuted
                    SldLabel.TextSize = 11
                    SldLabel.Font = Enum.Font.GothamMedium
                    SldLabel.TextXAlignment = Enum.TextXAlignment.Left
                    SldLabel.Parent = TextRow

                    local ValLabel = Instance.new("TextLabel")
                    ValLabel.Size = UDim2.new(0, 80, 1, 0)
                    ValLabel.Position = UDim2.new(1, -80, 0, 0)
                    ValLabel.BackgroundTransparency = 1
                    ValLabel.Text = tostring(default) .. suffix
                    ValLabel.TextColor3 = Library.Theme.TextMuted
                    ValLabel.TextSize = 10
                    ValLabel.Font = Enum.Font.Gotham
                    ValLabel.TextXAlignment = Enum.TextXAlignment.Right
                    ValLabel.Parent = TextRow

                    local Track = Instance.new("TextButton")
                    Track.Name = "Track"
                    Track.Size = UDim2.new(1, 0, 0, 4)
                    Track.Position = UDim2.new(0, 0, 0, 20)
                    Track.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
                    Track.BorderSizePixel = 0
                    Track.Text = ""
                    Track.AutoButtonColor = false
                    Track.Parent = SliderContainer

                    local TC = Instance.new("UICorner")
                    TC.CornerRadius = UDim.new(1, 0)
                    TC.Parent = Track

                    local Fill = Instance.new("Frame")
                    Fill.Size = UDim2.new(0, 0, 1, 0)
                    Fill.BorderSizePixel = 0
                    Fill.Parent = Track
                    Library:RegisterAccent(Fill, "BackgroundColor3")

                    local FC = Instance.new("UICorner")
                    FC.CornerRadius = UDim.new(1, 0)
                    FC.Parent = Fill

                    local Handle = Instance.new("Frame")
                    Handle.Size = UDim2.new(0, 6, 0, 6)
                    Handle.Position = UDim2.new(0, 0, 0.5, -3)
                    Handle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
                    Handle.BorderSizePixel = 0
                    Handle.Parent = Track

                    local HC = Instance.new("UICorner")
                    HC.CornerRadius = UDim.new(1, 0)
                    HC.Parent = Handle

                    local value = default

                    local function updateSlider(input)
                        local relativeX = input.Position.X - Track.AbsolutePosition.X
                        local percentage = math.clamp(relativeX / Track.AbsoluteSize.X, 0, 1)
                        local exactVal = min + (max - min) * percentage
                        value = math.round(exactVal)

                        local visualPercentage = (value - min) / (max - min)
                        tween(Fill, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                            Size = UDim2.new(visualPercentage, 0, 1, 0)
                        })
                        tween(Handle, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                            Position = UDim2.new(visualPercentage, 0, 0.5, -3)
                        })
                        ValLabel.Text = tostring(value) .. suffix
                        
                        Library.Registry[configName] = value
                        callback(value)
                    end

                    -- Uses the shared input dispatch (no per-slider global connections)
                    Track.InputBegan:Connect(function(input)
                        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
                            ensureSharedInput()
                            SharedInput.dragUpdate = updateSlider
                            updateSlider(input)
                        end
                    end)

                    local initPercentage = (default - min) / (max - min)
                    Fill.Size = UDim2.new(initPercentage, 0, 1, 0)
                    Handle.Position = UDim2.new(initPercentage, 0, 0.5, -3)
                    Library.Registry[configName] = default

                    if sliderOptions.Tooltip then Library:AttachTooltip(SliderContainer, sliderOptions.Tooltip) end

                    local SliderController = {}
                    function SliderController:Set(val)
                        value = math.clamp(val, min, max)
                        local percent = (value - min) / (max - min)
                        tween(Fill, TweenInfo.new(0.15), {Size = UDim2.new(percent, 0, 1, 0)})
                        tween(Handle, TweenInfo.new(0.15), {Position = UDim2.new(percent, 0, 0.5, -3)})
                        ValLabel.Text = tostring(value) .. suffix
                        Library.Registry[configName] = value
                        callback(value)
                    end

                    Library.Controllers[configName] = SliderController
                    return SliderController
                end

                -- DROPDOWN COMPONENT
                function ComponentObj:CreateDropdown(ddOptions)
                    ddOptions = ddOptions or {}
                    local ddName = ddOptions.Name or "Dropdown"
                    local optionsList = ddOptions.Options or {}
                    local default = ddOptions.Default or optionsList[1]
                    local callback = ddOptions.Callback or function() end
                    local configName = ddOptions.ConfigName or ddName

                    local DropdownContainer = Instance.new("Frame")
                    DropdownContainer.Size = UDim2.new(1, 0, 0, 44)
                    DropdownContainer.BackgroundTransparency = 1
                    DropdownContainer.Parent = ContentFrame

                    local DdLabel = Instance.new("TextLabel")
                    DdLabel.Size = UDim2.new(1, 0, 0, 14)
                    DdLabel.BackgroundTransparency = 1
                    DdLabel.Text = ddName
                    DdLabel.TextColor3 = Library.Theme.TextMuted
                    DdLabel.TextSize = 11
                    DdLabel.Font = Enum.Font.GothamMedium
                    DdLabel.TextXAlignment = Enum.TextXAlignment.Left
                    DdLabel.Parent = DropdownContainer

                    local SelectorBtn = Instance.new("TextButton")
                    SelectorBtn.Size = UDim2.new(1, 0, 0, 24)
                    SelectorBtn.Position = UDim2.new(0, 0, 0, 18)
                    SelectorBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                    SelectorBtn.Text = ""
                    SelectorBtn.AutoButtonColor = false
                    SelectorBtn.Parent = DropdownContainer

                    local SBCorner = Instance.new("UICorner")
                    SBCorner.CornerRadius = UDim.new(0, 3)
                    SBCorner.Parent = SelectorBtn

                    local SBStroke = Instance.new("UIStroke")
                    SBStroke.Color = Library.Theme.Border
                    SBStroke.Thickness = 1
                    SBStroke.Parent = SelectorBtn

                    local SelectedText = Instance.new("TextLabel")
                    SelectedText.Size = UDim2.new(1, -30, 1, 0)
                    SelectedText.Position = UDim2.new(0, 10, 0, 0)
                    SelectedText.BackgroundTransparency = 1
                    SelectedText.Text = tostring(default)
                    SelectedText.TextColor3 = Library.Theme.TextMuted
                    SelectedText.TextSize = 11
                    SelectedText.Font = Enum.Font.Gotham
                    SelectedText.TextXAlignment = Enum.TextXAlignment.Left
                    SelectedText.Parent = SelectorBtn

                    local ArrowsIcon = Instance.new("TextLabel")
                    ArrowsIcon.Size = UDim2.new(0, 20, 1, 0)
                    ArrowsIcon.Position = UDim2.new(1, -25, 0, 0)
                    ArrowsIcon.BackgroundTransparency = 1
                    ArrowsIcon.Text = "⇅"
                    ArrowsIcon.TextColor3 = Library.Theme.TextMuted
                    ArrowsIcon.TextSize = 11
                    ArrowsIcon.Font = Enum.Font.Gotham
                    ArrowsIcon.Parent = SelectorBtn

                    local ListContainer = Instance.new("Frame")
                    ListContainer.Size = UDim2.new(0, 0, 0, 0)
                    ListContainer.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                    ListContainer.Visible = false
                    ListContainer.ClipsDescendants = true
                    ListContainer.ZIndex = 100
                    ListContainer.Parent = ScreenGui

                    local LCCorner = Instance.new("UICorner")
                    LCCorner.CornerRadius = UDim.new(0, 3)
                    LCCorner.Parent = ListContainer

                    local LCStroke = Instance.new("UIStroke")
                    LCStroke.Color = Library.Theme.Border
                    LCStroke.Thickness = 1
                    LCStroke.Parent = ListContainer

                    local ListScroll = Instance.new("ScrollingFrame")
                    ListScroll.Size = UDim2.new(1, 0, 1, 0)
                    ListScroll.BackgroundTransparency = 1
                    ListScroll.BorderSizePixel = 0
                    ListScroll.ScrollBarThickness = 2
                    ListScroll.ScrollBarImageColor3 = Library.Theme.Border
                    ListScroll.Parent = ListContainer

                    local ListLayout = Instance.new("UIListLayout")
                    ListLayout.SortOrder = Enum.SortOrder.LayoutOrder
                    ListLayout.Parent = ListScroll

                    local selectedValue = default
                    local isOpen = false

                    local function closeList()
                        if not isOpen then return end
                        isOpen = false
                        local t = tween(ListContainer, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                            Size = UDim2.new(0, ListContainer.AbsoluteSize.X, 0, 0)
                        })
                        t.Completed:Connect(function()
                            if not isOpen then ListContainer.Visible = false end
                        end)
                    end

                    local function openList()
                        isOpen = true
                        local targetH = math.min(#optionsList * 24, 120)
                        ListContainer.Position = UDim2.new(0, SelectorBtn.AbsolutePosition.X, 0, SelectorBtn.AbsolutePosition.Y + SelectorBtn.AbsoluteSize.Y + 2)
                        ListContainer.Size = UDim2.new(0, SelectorBtn.AbsoluteSize.X, 0, 0)
                        ListContainer.Visible = true
                        tween(ListContainer, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                            Size = UDim2.new(0, SelectorBtn.AbsoluteSize.X, 0, targetH)
                        })
                    end

                    local function selectValue(val)
                        selectedValue = val
                        SelectedText.Text = tostring(val)
                        Library.Registry[configName] = val
                        callback(val)
                        closeList()
                    end

                    for idx, optionName in ipairs(optionsList) do
                        local OptBtn = Instance.new("TextButton")
                        OptBtn.Size = UDim2.new(1, 0, 0, 24)
                        OptBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                        OptBtn.BackgroundTransparency = 1
                        OptBtn.Text = tostring(optionName)
                        OptBtn.TextColor3 = Library.Theme.TextMuted
                        OptBtn.TextSize = 11
                        OptBtn.Font = Enum.Font.Gotham
                        OptBtn.Parent = ListScroll

                        OptBtn.MouseEnter:Connect(function()
                            tween(OptBtn, TweenInfo.new(0.1), {BackgroundTransparency = 0, BackgroundColor3 = Library.Theme.Hover, TextColor3 = Library.Theme.Text})
                        end)
                        OptBtn.MouseLeave:Connect(function()
                            tween(OptBtn, TweenInfo.new(0.1), {BackgroundTransparency = 1, TextColor3 = Library.Theme.TextMuted})
                        end)
                        OptBtn.MouseButton1Click:Connect(function()
                            selectValue(optionName)
                        end)
                    end

                    ListScroll.CanvasSize = UDim2.new(0, 0, 0, #optionsList * 24)

                    SelectorBtn.MouseButton1Click:Connect(function()
                        if isOpen then closeList() else openList() end
                    end)

                    SelectorBtn.MouseEnter:Connect(function()
                        tween(SelectorBtn, TweenInfo.new(0.12), {BackgroundColor3 = Library.Theme.Hover})
                    end)
                    SelectorBtn.MouseLeave:Connect(function()
                        tween(SelectorBtn, TweenInfo.new(0.12), {BackgroundColor3 = Color3.fromRGB(20, 20, 24)})
                    end)

                    ensureSharedInput()
                    table.insert(dropdownClosers, function(input)
                        if not isOpen then return end
                        if not pointInside(ListContainer, input.Position) and not pointInside(SelectorBtn, input.Position) then
                            closeList()
                        end
                    end)

                    if ddOptions.Tooltip then Library:AttachTooltip(DropdownContainer, ddOptions.Tooltip) end

                    Library.Registry[configName] = default

                    local DropdownController = {}
                    function DropdownController:Set(val)
                        selectValue(val)
                    end
                    return DropdownController
                end

                -- COLOR PICKER COMPONENT
                function ComponentObj:CreateColorPicker(cpOptions)
                    cpOptions = cpOptions or {}
                    local cpName = cpOptions.Name or "Color Picker"
                    local defaultColor = cpOptions.Default or Color3.fromRGB(255, 0, 0)
                    local defaultAlpha = cpOptions.Alpha or 1
                    local callback = cpOptions.Callback or function() end
                    local configName = cpOptions.ConfigName or cpName

                    local CPRow = Instance.new("Frame")
                    CPRow.Size = UDim2.new(1, 0, 0, 20)
                    CPRow.BackgroundTransparency = 1
                    CPRow.Parent = ContentFrame

                    local CPLabel = Instance.new("TextLabel")
                    CPLabel.Size = UDim2.new(1, -40, 1, 0)
                    CPLabel.BackgroundTransparency = 1
                    CPLabel.Text = cpName
                    CPLabel.TextColor3 = Library.Theme.TextMuted
                    CPLabel.TextSize = 11
                    CPLabel.Font = Enum.Font.GothamMedium
                    CPLabel.TextXAlignment = Enum.TextXAlignment.Left
                    CPLabel.Parent = CPRow

                    local ColorBtn = Instance.new("TextButton")
                    ColorBtn.Size = UDim2.new(0, 18, 0, 12)
                    ColorBtn.Position = UDim2.new(1, -18, 0.5, -6)
                    ColorBtn.BackgroundColor3 = defaultColor
                    ColorBtn.BackgroundTransparency = 1 - defaultAlpha
                    ColorBtn.BorderSizePixel = 0
                    ColorBtn.Text = ""
                    ColorBtn.Parent = CPRow

                    local CBCorner = Instance.new("UICorner")
                    CBCorner.CornerRadius = UDim.new(0, 2)
                    CBCorner.Parent = ColorBtn

                    local CBStroke = Instance.new("UIStroke")
                    CBStroke.Color = Library.Theme.Border
                    CBStroke.Thickness = 1
                    CBStroke.Parent = ColorBtn

                    local colorVal = defaultColor
                    local alphaVal = defaultAlpha

                    ColorBtn.MouseButton1Click:Connect(function()
                        currentH, currentS, currentV = colorVal:ToHSV()
                        currentAlpha = alphaVal
                        activeCallback = callback
                        activeRegistryKey = configName
                        activePreviewBtn = ColorBtn

                        ColorPickerWindow.Position = UDim2.new(0, MainFrame.AbsolutePosition.X + MainFrame.AbsoluteSize.X + 10, 0, MainFrame.AbsolutePosition.Y)
                        
                        SVCursor.Position = UDim2.new(currentS, -3, 1 - currentV, -3)
                        HueCursor.Position = UDim2.new(0, -2, 1 - currentH, -2)
                        OpacityCursor.Position = UDim2.new(currentAlpha, -2, 0, -2)

                        updateColorPickerVisuals()
                        ColorPickerWindow.Visible = true
                    end)

                    if cpOptions.Tooltip then Library:AttachTooltip(CPRow, cpOptions.Tooltip) end

                    Library.Registry[configName] = {defaultColor.R, defaultColor.G, defaultColor.B, defaultAlpha}

                    local ColorController = {}
                    function ColorController:Set(color, alpha)
                        colorVal = color
                        alphaVal = alpha or 1
                        ColorBtn.BackgroundColor3 = colorVal
                        ColorBtn.BackgroundTransparency = 1 - alphaVal
                        Library.Registry[configName] = {colorVal.R, colorVal.G, colorVal.B, alphaVal}
                        callback(colorVal, alphaVal)
                    end

                    Library.Controllers[configName] = ColorController
                    return ColorController
                end

                -- BUTTON COMPONENT
                function ComponentObj:CreateButton(btnOptions)
                    btnOptions = btnOptions or {}
                    local btnName = btnOptions.Name or "Button"
                    local callback = btnOptions.Callback or function() end

                    local ButtonFrame = Instance.new("Frame")
                    ButtonFrame.Size = UDim2.new(1, 0, 0, 24)
                    ButtonFrame.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
                    ButtonFrame.Parent = ContentFrame

                    local BC = Instance.new("UICorner")
                    BC.CornerRadius = UDim.new(0, 3)
                    BC.Parent = ButtonFrame

                    local BS = Instance.new("UIStroke")
                    BS.Color = Library.Theme.Border
                    BS.Thickness = 1
                    BS.Parent = ButtonFrame

                    local ActualButton = Instance.new("TextButton")
                    ActualButton.Size = UDim2.new(1, 0, 1, 0)
                    ActualButton.BackgroundTransparency = 1
                    ActualButton.Text = btnName
                    ActualButton.TextColor3 = Library.Theme.Text
                    ActualButton.TextSize = 10
                    ActualButton.Font = Enum.Font.GothamMedium
                    ActualButton.Parent = ButtonFrame

                    ActualButton.MouseEnter:Connect(function()
                        tween(ButtonFrame, TweenInfo.new(0.12), {BackgroundColor3 = Library.Theme.Hover})
                    end)

                    ActualButton.MouseLeave:Connect(function()
                        tween(ButtonFrame, TweenInfo.new(0.12), {BackgroundColor3 = Color3.fromRGB(24, 24, 28)})
                    end)

                    ActualButton.MouseButton1Down:Connect(function()
                        tween(ButtonFrame, TweenInfo.new(0.06), {Size = UDim2.new(1, -4, 0, 22)})
                    end)

                    ActualButton.MouseButton1Up:Connect(function()
                        tween(ButtonFrame, TweenInfo.new(0.06), {Size = UDim2.new(1, 0, 0, 24)})
                        callback()
                    end)

                    if btnOptions.Tooltip then Library:AttachTooltip(ButtonFrame, btnOptions.Tooltip) end
                end

                -- 3D ESP PREVIEW COMPONENT
                function ComponentObj:CreateESPPreview(espOptions)
                    espOptions = espOptions or {}
                    local espName = espOptions.Name or "ESP Preview"

                    -- Floating mode renders the preview in its own panel glued to the left
                    -- of the main window; otherwise it embeds inline in the section.
                    local Viewport
                    local FloatingPanel

                    if espOptions.Floating then
                        local Panel = Instance.new("CanvasGroup")
                        Panel.Name = "ESPPreviewPanel"
                        Panel.Size = UDim2.new(0, 220, 0, 400)
                        Panel.BackgroundColor3 = Library.Theme.Card
                        Panel.BorderSizePixel = 0
                        Panel.Parent = ScreenGui
                        FloatingPanel = Panel

                        local PCorner = Instance.new("UICorner")
                        PCorner.CornerRadius = UDim.new(0, 5)
                        PCorner.Parent = Panel

                        local PStroke = Instance.new("UIStroke")
                        PStroke.Color = Library.Theme.Border
                        PStroke.Thickness = 1
                        PStroke.Parent = Panel

                        local Title = Instance.new("TextLabel")
                        Title.Size = UDim2.new(1, -20, 0, 24)
                        Title.Position = UDim2.new(0, 10, 0, 4)
                        Title.BackgroundTransparency = 1
                        Title.Text = espName
                        Title.TextColor3 = Library.Theme.Text
                        Title.TextSize = 11
                        Title.Font = Enum.Font.GothamBold
                        Title.TextXAlignment = Enum.TextXAlignment.Left
                        Title.Parent = Panel

                        local ViewportBg = Instance.new("Frame")
                        ViewportBg.Size = UDim2.new(1, -16, 1, -38)
                        ViewportBg.Position = UDim2.new(0, 8, 0, 30)
                        ViewportBg.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                        ViewportBg.Parent = Panel

                        local VBCorner = Instance.new("UICorner")
                        VBCorner.CornerRadius = UDim.new(0, 4)
                        VBCorner.Parent = ViewportBg

                        local VBStroke = Instance.new("UIStroke")
                        VBStroke.Color = Library.Theme.Border
                        VBStroke.Thickness = 1
                        VBStroke.Parent = ViewportBg

                        Viewport = Instance.new("ViewportFrame")
                        Viewport.Size = UDim2.new(1, -10, 1, -10)
                        Viewport.Position = UDim2.new(0, 5, 0, 5)
                        Viewport.BackgroundTransparency = 1
                        Viewport.Parent = ViewportBg
                    else
                        local PreviewContainer = Instance.new("Frame")
                        PreviewContainer.Size = UDim2.new(1, 0, 0, 180)
                        PreviewContainer.BackgroundTransparency = 1
                        PreviewContainer.Parent = ContentFrame

                        local Label = Instance.new("TextLabel")
                        Label.Size = UDim2.new(1, 0, 0, 14)
                        Label.BackgroundTransparency = 1
                        Label.Text = espName
                        Label.TextColor3 = Library.Theme.TextMuted
                        Label.TextSize = 11
                        Label.Font = Enum.Font.GothamMedium
                        Label.TextXAlignment = Enum.TextXAlignment.Left
                        Label.Parent = PreviewContainer

                        local ViewportBg = Instance.new("Frame")
                        ViewportBg.Size = UDim2.new(1, 0, 1, -20)
                        ViewportBg.Position = UDim2.new(0, 0, 0, 20)
                        ViewportBg.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                        ViewportBg.Parent = PreviewContainer

                        local VBCorner = Instance.new("UICorner")
                        VBCorner.CornerRadius = UDim.new(0, 4)
                        VBCorner.Parent = ViewportBg

                        local VBStroke = Instance.new("UIStroke")
                        VBStroke.Color = Library.Theme.Border
                        VBStroke.Thickness = 1
                        VBStroke.Parent = ViewportBg

                        Viewport = Instance.new("ViewportFrame")
                        Viewport.Size = UDim2.new(1, -10, 1, -10)
                        Viewport.Position = UDim2.new(0, 5, 0, 5)
                        Viewport.BackgroundTransparency = 1
                        Viewport.Parent = ViewportBg
                    end

                    local Camera = Instance.new("Camera")
                    Camera.FieldOfView = 50
                    Viewport.CurrentCamera = Camera
                    Camera.Parent = Viewport

                    local World = Instance.new("WorldModel")
                    World.Parent = Viewport

                    -- Load the local player's actual Roblox avatar into the preview.
                    -- Falls back to a simple blocky dummy if the avatar can't be fetched.
                    local Dummy
                    local userId = (Players.LocalPlayer and Players.LocalPlayer.UserId) or 1
                    local loadedAvatar = pcall(function()
                        Dummy = Players:CreateHumanoidModelFromUserId(userId)
                    end)

                    if loadedAvatar and Dummy then
                        Dummy.Name = "Dummy"
                        Dummy.Parent = World
                        if not Dummy.PrimaryPart then
                            Dummy.PrimaryPart = Dummy:FindFirstChild("HumanoidRootPart") or Dummy:FindFirstChildWhichIsA("BasePart")
                        end
                    else
                        Dummy = Instance.new("Model")
                        Dummy.Name = "Dummy"
                        Dummy.Parent = World

                        local Torso = Instance.new("Part")
                        Torso.Name = "Torso"
                        Torso.Size = Vector3.new(2, 2, 1)
                        Torso.Position = Vector3.new(0, 0, 0)
                        Torso.Color = Color3.fromRGB(60, 60, 65)
                        Torso.Parent = Dummy
                        Dummy.PrimaryPart = Torso

                        local FbHead = Instance.new("Part")
                        FbHead.Name = "Head"
                        FbHead.Size = Vector3.new(1.1, 1.1, 1.1)
                        FbHead.Position = Vector3.new(0, 1.5, 0)
                        FbHead.Color = Color3.fromRGB(70, 70, 75)
                        FbHead.Parent = Dummy

                        local LeftArm = Instance.new("Part")
                        LeftArm.Name = "Left Arm"
                        LeftArm.Size = Vector3.new(1, 2, 1)
                        LeftArm.Position = Vector3.new(-1.5, 0, 0)
                        LeftArm.Color = Color3.fromRGB(60, 60, 65)
                        LeftArm.Parent = Dummy

                        local RightArm = Instance.new("Part")
                        RightArm.Name = "Right Arm"
                        RightArm.Size = Vector3.new(1, 2, 1)
                        RightArm.Position = Vector3.new(1.5, 0, 0)
                        RightArm.Color = Color3.fromRGB(60, 60, 65)
                        RightArm.Parent = Dummy

                        local LeftLeg = Instance.new("Part")
                        LeftLeg.Name = "Left Leg"
                        LeftLeg.Size = Vector3.new(1, 2, 1)
                        LeftLeg.Position = Vector3.new(-0.5, -2, 0)
                        LeftLeg.Color = Color3.fromRGB(55, 55, 60)
                        LeftLeg.Parent = Dummy

                        local RightLeg = Instance.new("Part")
                        RightLeg.Name = "Right Leg"
                        RightLeg.Size = Vector3.new(1, 2, 1)
                        RightLeg.Position = Vector3.new(0.5, -2, 0)
                        RightLeg.Color = Color3.fromRGB(55, 55, 60)
                        RightLeg.Parent = Dummy
                    end

                    -- Anchor every part so the model holds its pose (no physics in a ViewportFrame)
                    for _, p in ipairs(Dummy:GetDescendants()) do
                        if p:IsA("BasePart") then p.Anchored = true end
                    end

                    -- Snapshot original appearance so Chams can be toggled off cleanly
                    local originalProps = {}
                    for _, part in ipairs(Dummy:GetDescendants()) do
                        if part:IsA("BasePart") then
                            originalProps[part] = {
                                Color = part.Color,
                                Material = part.Material,
                                Transparency = part.Transparency
                            }
                        end
                    end

                    local Head = Dummy:FindFirstChild("Head") or Dummy.PrimaryPart

                    -- Vertical offset so the avatar's bounding-box center sits on the spin axis,
                    -- keeping the character centered in the viewport regardless of rig (R6/R15).
                    local pivotY = 0.5
                    pcall(function()
                        local bbCF = Dummy:GetBoundingBox()
                        pivotY = Dummy.PrimaryPart.CFrame:PointToObjectSpace(bbCF.Position).Y
                    end)

                    local BoxPart = Instance.new("Part")
                    BoxPart.Size = Vector3.new(3.8, 5.2, 2.2)
                    BoxPart.Position = Vector3.new(0, -0.25, 0)
                    BoxPart.Transparency = 1
                    BoxPart.CanCollide = false
                    BoxPart.Parent = World

                    local BoxStroke = Instance.new("SelectionBox")
                    BoxStroke.Color3 = Library.Theme.Accent
                    BoxStroke.LineThickness = 0.04
                    BoxStroke.Adornee = BoxPart
                    BoxStroke.Visible = false
                    BoxStroke.Parent = BoxPart
                    Library:RegisterAccent(BoxStroke, "Color3")

                    local HealthPart = Instance.new("Part")
                    HealthPart.Size = Vector3.new(0.1, 4.8, 0.1)
                    HealthPart.Position = Vector3.new(-2.1, -0.25, 0)
                    HealthPart.Color = Color3.fromRGB(0, 255, 100)
                    HealthPart.Material = Enum.Material.Neon
                    HealthPart.CanCollide = false
                    HealthPart.Transparency = 1
                    HealthPart.Parent = World

                    local Skeleton = Instance.new("Model")
                    Skeleton.Name = "Skeleton"
                    Skeleton.Parent = World

                    local function createBone(size, pos)
                        local bone = Instance.new("Part")
                        bone.Size = size
                        bone.Position = pos
                        bone.Color = Color3.fromRGB(255, 255, 255)
                        bone.Material = Enum.Material.Neon
                        bone.CanCollide = false
                        bone.Parent = Skeleton
                        return bone
                    end

                    local spine = createBone(Vector3.new(0.15, 2, 0.15), Vector3.new(0, 0, 0))
                    local clavicle = createBone(Vector3.new(3, 0.15, 0.15), Vector3.new(0, 1, 0))
                    local lLegBone = createBone(Vector3.new(0.15, 2, 0.15), Vector3.new(-0.5, -2, 0))
                    local rLegBone = createBone(Vector3.new(0.15, 2, 0.15), Vector3.new(0.5, -2, 0))

                    for _, b in ipairs(Skeleton:GetChildren()) do
                        b.Transparency = 1
                    end

                    local BBGui = Instance.new("BillboardGui")
                    BBGui.Size = UDim2.new(0, 100, 0, 20)
                    BBGui.AlwaysOnTop = true
                    BBGui.Adornee = Head
                    BBGui.Parent = Head

                    local NameLabel = Instance.new("TextLabel")
                    NameLabel.Size = UDim2.new(1, 0, 1, 0)
                    NameLabel.BackgroundTransparency = 1
                    NameLabel.Text = (Players.LocalPlayer and Players.LocalPlayer.DisplayName) or "Player"
                    NameLabel.TextColor3 = Library.Theme.Text
                    NameLabel.TextSize = 9
                    NameLabel.Font = Enum.Font.GothamBold
                    NameLabel.Visible = false
                    NameLabel.Parent = BBGui

                    local spinConn = RunService.RenderStepped:Connect(function()
                        local angle = os.clock() * 1.2
                        local rootCFrame = CFrame.new(0, -pivotY, 0) * CFrame.Angles(0, angle, 0)

                        Dummy:SetPrimaryPartCFrame(rootCFrame)
                        BoxPart.CFrame = rootCFrame * CFrame.new(0, 0.25, 0)
                        HealthPart.CFrame = rootCFrame * CFrame.new(-2.1, 0.25, 0)

                        spine.CFrame = rootCFrame * CFrame.new(0, 0.5, 0)
                        clavicle.CFrame = rootCFrame * CFrame.new(0, 1.5, 0)
                        lLegBone.CFrame = rootCFrame * CFrame.new(-0.5, -0.5, 0)
                        rLegBone.CFrame = rootCFrame * CFrame.new(0.5, -0.5, 0)

                        -- Reframe the camera for the current viewport aspect so the avatar
                        -- stays centered and fully visible (avatar center is at the world origin).
                        local aspect = Viewport.AbsoluteSize.X / math.max(Viewport.AbsoluteSize.Y, 1)
                        local halfTan = math.tan(math.rad(Camera.FieldOfView) / 2)
                        local distV = 3.0 / halfTan
                        local distH = 2.6 / (halfTan * math.max(aspect, 0.05))
                        local dist = math.max(distV, distH) + 0.5
                        Camera.CFrame = CFrame.new(Vector3.new(0, 0, dist), Vector3.new(0, 0, 0))

                        -- Keep the floating panel glued to the left of the main window, matching
                        -- its height, and mirroring its fade/visibility so it toggles with the menu.
                        if FloatingPanel and MainFrame then
                            FloatingPanel.Size = UDim2.fromOffset(220, MainFrame.AbsoluteSize.Y)
                            FloatingPanel.Position = UDim2.fromOffset(
                                math.floor(MainFrame.AbsolutePosition.X - FloatingPanel.AbsoluteSize.X - 10),
                                math.floor(MainFrame.AbsolutePosition.Y)
                            )
                            FloatingPanel.GroupTransparency = MainFrame.GroupTransparency
                            FloatingPanel.Visible = MainFrame.Visible
                        end
                    end)
                    table.insert(Library.Connections, spinConn)

                    local ESPController = {}

                    function ESPController:SetBox(state)
                        BoxStroke.Visible = state
                    end

                    function ESPController:SetSkeleton(state)
                        for _, b in ipairs(Skeleton:GetChildren()) do
                            b.Transparency = state and 0 or 1
                        end
                    end

                    function ESPController:SetHealth(state)
                        HealthPart.Transparency = state and 0 or 1
                    end

                    function ESPController:SetName(state)
                        NameLabel.Visible = state
                    end

                    function ESPController:SetChams(state)
                        for _, part in ipairs(Dummy:GetDescendants()) do
                            if part:IsA("BasePart") then
                                if state then
                                    part.Material = Enum.Material.Neon
                                    part.Color = Library.Theme.Accent
                                    part.Transparency = 0.4
                                else
                                    local orig = originalProps[part]
                                    if orig then
                                        part.Material = orig.Material
                                        part.Color = orig.Color
                                        part.Transparency = orig.Transparency
                                    end
                                end
                            end
                        end
                    end

                    return ESPController
                end

                -- ALL-IN-ONE ESP SECTION (3D preview + pre-wired feature toggles)
                function ComponentObj:CreateESPSection(espOptions)
                    espOptions = espOptions or {}
                    local name = espOptions.Name or "ESP Preview"
                    local configPrefix = espOptions.ConfigName or "ESP"
                    local features = espOptions.Features      -- optional list to restrict, e.g. {"Box","Chams"}
                    local defaults = espOptions.Defaults or {} -- e.g. {Box = true, Chams = false}

                    -- Floating preview (left of the main window) by default; pass Floating=false to embed inline.
                    local floating = espOptions.Floating ~= false
                    local preview = self:CreateESPPreview({ Name = name, Floating = floating })
                    self:CreateDivider({ Text = "Features" })

                    local toggleDefs = {
                        { key = "Box",      label = "box esp",      setter = "SetBox" },
                        { key = "Skeleton", label = "skeleton esp", setter = "SetSkeleton" },
                        { key = "Health",   label = "health bar",   setter = "SetHealth" },
                        { key = "Name",     label = "name esp",     setter = "SetName" },
                        { key = "Chams",    label = "chams",        setter = "SetChams" },
                    }

                    local ESPSectionController = { Preview = preview, Toggles = {} }

                    for _, def in ipairs(toggleDefs) do
                        if features == nil or table.find(features, def.key) then
                            local default = defaults[def.key] or false

                            local toggle = self:CreateToggle({
                                Name = def.label,
                                Default = default,
                                Callback = function(state)
                                    preview[def.setter](preview, state)
                                end,
                                ConfigName = configPrefix .. "_" .. def.key
                            })

                            -- Apply the default to the preview immediately (CreateToggle does not fire its callback on init)
                            preview[def.setter](preview, default)

                            ESPSectionController.Toggles[def.key] = toggle
                        end
                    end

                    return ESPSectionController
                end

                -- LABEL COMPONENT (single line static text)
                function ComponentObj:CreateLabel(labelOptions)
                    labelOptions = labelOptions or {}
                    local text = labelOptions.Text or "Label"

                    local LabelText = Instance.new("TextLabel")
                    LabelText.Size = UDim2.new(1, 0, 0, 16)
                    LabelText.BackgroundTransparency = 1
                    LabelText.Text = text
                    LabelText.TextColor3 = Library.Theme.Text
                    LabelText.TextSize = 11
                    LabelText.Font = Enum.Font.GothamMedium
                    LabelText.TextXAlignment = Enum.TextXAlignment.Left
                    LabelText.TextTruncate = Enum.TextTruncate.AtEnd
                    LabelText.Parent = ContentFrame

                    if labelOptions.Tooltip then Library:AttachTooltip(LabelText, labelOptions.Tooltip) end

                    local LabelController = {}
                    function LabelController:Set(newText)
                        LabelText.Text = newText
                    end
                    return LabelController
                end

                -- PARAGRAPH COMPONENT (optional title + wrapping body text)
                function ComponentObj:CreateParagraph(paraOptions)
                    paraOptions = paraOptions or {}
                    local titleText = paraOptions.Title
                    local bodyText = paraOptions.Text or ""

                    local ParaContainer = Instance.new("Frame")
                    ParaContainer.Size = UDim2.new(1, 0, 0, 0)
                    ParaContainer.AutomaticSize = Enum.AutomaticSize.Y
                    ParaContainer.BackgroundTransparency = 1
                    ParaContainer.Parent = ContentFrame

                    local ParaLayout = Instance.new("UIListLayout")
                    ParaLayout.SortOrder = Enum.SortOrder.LayoutOrder
                    ParaLayout.Padding = UDim.new(0, 4)
                    ParaLayout.Parent = ParaContainer

                    local TitleLabel
                    if titleText then
                        TitleLabel = Instance.new("TextLabel")
                        TitleLabel.Size = UDim2.new(1, 0, 0, 14)
                        TitleLabel.BackgroundTransparency = 1
                        TitleLabel.Text = titleText
                        TitleLabel.TextColor3 = Library.Theme.Text
                        TitleLabel.TextSize = 11
                        TitleLabel.Font = Enum.Font.GothamBold
                        TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
                        TitleLabel.LayoutOrder = 1
                        TitleLabel.Parent = ParaContainer
                    end

                    local BodyLabel = Instance.new("TextLabel")
                    BodyLabel.Size = UDim2.new(1, 0, 0, 0)
                    BodyLabel.AutomaticSize = Enum.AutomaticSize.Y
                    BodyLabel.BackgroundTransparency = 1
                    BodyLabel.Text = bodyText
                    BodyLabel.TextColor3 = Library.Theme.TextMuted
                    BodyLabel.TextSize = 11
                    BodyLabel.Font = Enum.Font.Gotham
                    BodyLabel.TextWrapped = true
                    BodyLabel.TextXAlignment = Enum.TextXAlignment.Left
                    BodyLabel.TextYAlignment = Enum.TextYAlignment.Top
                    BodyLabel.LayoutOrder = 2
                    BodyLabel.Parent = ParaContainer

                    local ParagraphController = {}
                    function ParagraphController:Set(newText)
                        BodyLabel.Text = newText
                    end
                    function ParagraphController:SetTitle(newTitle)
                        if TitleLabel then TitleLabel.Text = newTitle end
                    end
                    return ParagraphController
                end

                -- DIVIDER COMPONENT (themed separator line, optional centered label)
                function ComponentObj:CreateDivider(divOptions)
                    divOptions = divOptions or {}
                    local text = divOptions.Text

                    local DividerFrame = Instance.new("Frame")
                    DividerFrame.Size = UDim2.new(1, 0, 0, text and 16 or 8)
                    DividerFrame.BackgroundTransparency = 1
                    DividerFrame.Parent = ContentFrame

                    local Line = Instance.new("Frame")
                    Line.Size = UDim2.new(1, 0, 0, 1)
                    Line.Position = UDim2.new(0, 0, 0.5, 0)
                    Line.BackgroundColor3 = Library.Theme.Border
                    Line.BorderSizePixel = 0
                    Line.Parent = DividerFrame

                    if text then
                        local CenterLabel = Instance.new("TextLabel")
                        CenterLabel.AutomaticSize = Enum.AutomaticSize.X
                        CenterLabel.Size = UDim2.new(0, 0, 1, 0)
                        CenterLabel.AnchorPoint = Vector2.new(0.5, 0.5)
                        CenterLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
                        CenterLabel.BackgroundColor3 = Library.Theme.Card
                        CenterLabel.Text = text
                        CenterLabel.TextColor3 = Library.Theme.TextMuted
                        CenterLabel.TextSize = 10
                        CenterLabel.Font = Enum.Font.GothamMedium
                        CenterLabel.Parent = DividerFrame

                        local labelPadding = Instance.new("UIPadding")
                        labelPadding.PaddingLeft = UDim.new(0, 6)
                        labelPadding.PaddingRight = UDim.new(0, 6)
                        labelPadding.Parent = CenterLabel
                    end
                end

                -- PROGRESS BAR COMPONENT (display-only animated fill)
                function ComponentObj:CreateProgressBar(pbOptions)
                    pbOptions = pbOptions or {}
                    local pbName = pbOptions.Name or "Progress"
                    local maxVal = pbOptions.Max or 100
                    local default = pbOptions.Default or 0
                    local suffix = pbOptions.Suffix or "%"

                    local PBContainer = Instance.new("Frame")
                    PBContainer.Size = UDim2.new(1, 0, 0, 30)
                    PBContainer.BackgroundTransparency = 1
                    PBContainer.Parent = ContentFrame

                    local TextRow = Instance.new("Frame")
                    TextRow.Size = UDim2.new(1, 0, 0, 16)
                    TextRow.BackgroundTransparency = 1
                    TextRow.Parent = PBContainer

                    local PBLabel = Instance.new("TextLabel")
                    PBLabel.Size = UDim2.new(1, -60, 1, 0)
                    PBLabel.BackgroundTransparency = 1
                    PBLabel.Text = pbName
                    PBLabel.TextColor3 = Library.Theme.TextMuted
                    PBLabel.TextSize = 11
                    PBLabel.Font = Enum.Font.GothamMedium
                    PBLabel.TextXAlignment = Enum.TextXAlignment.Left
                    PBLabel.Parent = TextRow

                    local PBValue = Instance.new("TextLabel")
                    PBValue.Size = UDim2.new(0, 60, 1, 0)
                    PBValue.Position = UDim2.new(1, -60, 0, 0)
                    PBValue.BackgroundTransparency = 1
                    PBValue.Text = tostring(default) .. suffix
                    PBValue.TextColor3 = Library.Theme.TextMuted
                    PBValue.TextSize = 10
                    PBValue.Font = Enum.Font.Gotham
                    PBValue.TextXAlignment = Enum.TextXAlignment.Right
                    PBValue.Parent = TextRow

                    local Track = Instance.new("Frame")
                    Track.Size = UDim2.new(1, 0, 0, 6)
                    Track.Position = UDim2.new(0, 0, 0, 20)
                    Track.BackgroundColor3 = Color3.fromRGB(24, 24, 28)
                    Track.BorderSizePixel = 0
                    Track.Parent = PBContainer

                    local TC = Instance.new("UICorner")
                    TC.CornerRadius = UDim.new(1, 0)
                    TC.Parent = Track

                    local Fill = Instance.new("Frame")
                    Fill.Size = UDim2.new(math.clamp(default / maxVal, 0, 1), 0, 1, 0)
                    Fill.BorderSizePixel = 0
                    Fill.Parent = Track
                    Library:RegisterAccent(Fill, "BackgroundColor3")

                    local FC = Instance.new("UICorner")
                    FC.CornerRadius = UDim.new(1, 0)
                    FC.Parent = Fill

                    if pbOptions.Tooltip then Library:AttachTooltip(PBContainer, pbOptions.Tooltip) end

                    local ProgressController = {}
                    function ProgressController:Set(value)
                        value = math.clamp(value, 0, maxVal)
                        local percent = value / maxVal
                        tween(Fill, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                            Size = UDim2.new(percent, 0, 1, 0)
                        })
                        PBValue.Text = tostring(math.round(value)) .. suffix
                    end
                    return ProgressController
                end

                -- SEGMENTED CONTROL COMPONENT (pill-style single selector)
                function ComponentObj:CreateSegmented(segOptions)
                    segOptions = segOptions or {}
                    local segName = segOptions.Name or "Segmented"
                    local optionsList = segOptions.Options or {}
                    local default = segOptions.Default or optionsList[1]
                    local callback = segOptions.Callback or function() end
                    local configName = segOptions.ConfigName or segName

                    local SegContainer = Instance.new("Frame")
                    SegContainer.Size = UDim2.new(1, 0, 0, 44)
                    SegContainer.BackgroundTransparency = 1
                    SegContainer.Parent = ContentFrame

                    local SegLabel = Instance.new("TextLabel")
                    SegLabel.Size = UDim2.new(1, 0, 0, 14)
                    SegLabel.BackgroundTransparency = 1
                    SegLabel.Text = segName
                    SegLabel.TextColor3 = Library.Theme.TextMuted
                    SegLabel.TextSize = 11
                    SegLabel.Font = Enum.Font.GothamMedium
                    SegLabel.TextXAlignment = Enum.TextXAlignment.Left
                    SegLabel.Parent = SegContainer

                    local Bar = Instance.new("Frame")
                    Bar.Size = UDim2.new(1, 0, 0, 24)
                    Bar.Position = UDim2.new(0, 0, 0, 18)
                    Bar.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
                    Bar.BorderSizePixel = 0
                    Bar.Parent = SegContainer

                    local BarCorner = Instance.new("UICorner")
                    BarCorner.CornerRadius = UDim.new(0, 3)
                    BarCorner.Parent = Bar

                    local BarStroke = Instance.new("UIStroke")
                    BarStroke.Color = Library.Theme.Border
                    BarStroke.Thickness = 1
                    BarStroke.Parent = Bar

                    local BarPadding = Instance.new("UIPadding")
                    BarPadding.PaddingLeft = UDim.new(0, 2)
                    BarPadding.PaddingRight = UDim.new(0, 2)
                    BarPadding.PaddingTop = UDim.new(0, 2)
                    BarPadding.PaddingBottom = UDim.new(0, 2)
                    BarPadding.Parent = Bar

                    local BarLayout = Instance.new("UIListLayout")
                    BarLayout.FillDirection = Enum.FillDirection.Horizontal
                    BarLayout.SortOrder = Enum.SortOrder.LayoutOrder
                    BarLayout.Padding = UDim.new(0, 2)
                    BarLayout.Parent = Bar

                    local count = #optionsList
                    local selectedValue = default
                    local segButtons = {}

                    local function updateVisuals()
                        for value, btn in pairs(segButtons) do
                            if value == selectedValue then
                                btn.TextColor3 = Color3.fromRGB(255, 255, 255)
                                Library:RegisterAccent(btn, "BackgroundColor3")
                                tween(btn, TweenInfo.new(0.12), {BackgroundTransparency = 0})
                            else
                                tween(btn, TweenInfo.new(0.12), {BackgroundTransparency = 1, TextColor3 = Library.Theme.TextMuted})
                            end
                        end
                    end

                    local function selectValue(value, fireCallback)
                        selectedValue = value
                        updateVisuals()
                        Library.Registry[configName] = value
                        if fireCallback then callback(value) end
                    end

                    for idx, optionName in ipairs(optionsList) do
                        local SegBtn = Instance.new("TextButton")
                        SegBtn.Size = UDim2.new(1 / count, -2, 1, 0)
                        SegBtn.BackgroundColor3 = Library.Theme.Accent
                        SegBtn.BackgroundTransparency = 1
                        SegBtn.AutoButtonColor = false
                        SegBtn.Text = tostring(optionName)
                        SegBtn.TextColor3 = Library.Theme.TextMuted
                        SegBtn.TextSize = 10
                        SegBtn.Font = Enum.Font.GothamMedium
                        SegBtn.LayoutOrder = idx
                        SegBtn.Parent = Bar

                        local SBC = Instance.new("UICorner")
                        SBC.CornerRadius = UDim.new(0, 2)
                        SBC.Parent = SegBtn

                        SegBtn.MouseEnter:Connect(function()
                            if selectedValue ~= optionName then
                                tween(SegBtn, TweenInfo.new(0.12), {TextColor3 = Library.Theme.Text})
                            end
                        end)
                        SegBtn.MouseLeave:Connect(function()
                            if selectedValue ~= optionName then
                                tween(SegBtn, TweenInfo.new(0.12), {TextColor3 = Library.Theme.TextMuted})
                            end
                        end)
                        SegBtn.MouseButton1Click:Connect(function()
                            selectValue(optionName, true)
                        end)

                        segButtons[optionName] = SegBtn
                    end

                    updateVisuals()
                    Library.Registry[configName] = selectedValue

                    if segOptions.Tooltip then Library:AttachTooltip(SegContainer, segOptions.Tooltip) end

                    local SegmentedController = {}
                    function SegmentedController:Set(value)
                        selectValue(value, true)
                    end
                    Library.Controllers[configName] = SegmentedController
                    return SegmentedController
                end

                return ComponentObj
            end

            return TabSectionObj
        end

        -- Main Tab Section creator interface
        local defaultInterface = setupSectionCreator(LeftColumn, RightColumn)

        function TabObj:CreateSubTab(subTabName)
            if not self.HasSubTabs then
                self.HasSubTabs = true
                SubTabsFrame.Visible = true
                MainColumnsFrame.Position = UDim2.new(0, 110, 0, 0)
                MainColumnsFrame.Size = UDim2.new(1, -110, 1, 0)
                MainColumnsFrame.Visible = false -- Hide default columns
            end

            local SubTabBtn = Instance.new("TextButton")
            SubTabBtn.Size = UDim2.new(1, 0, 0, 20)
            SubTabBtn.BackgroundTransparency = 1
            SubTabBtn.Text = subTabName
            SubTabBtn.TextColor3 = Library.Theme.TextMuted
            SubTabBtn.TextSize = 10
            SubTabBtn.Font = Enum.Font.GothamBold
            SubTabBtn.TextXAlignment = Enum.TextXAlignment.Left
            SubTabBtn.Parent = SubTabsFrame

            local SubTabPage = Instance.new("Frame")
            SubTabPage.Size = UDim2.new(1, 0, 1, 0)
            SubTabPage.BackgroundTransparency = 1
            SubTabPage.Visible = false
            SubTabPage.Parent = MainColumnsFrame

            local S_LeftColumn = Instance.new("ScrollingFrame")
            S_LeftColumn.Name = "LeftColumn"
            S_LeftColumn.Size = UDim2.new(0, 220, 1, -20)
            S_LeftColumn.Position = UDim2.new(0, 15, 0, 10)
            S_LeftColumn.BackgroundTransparency = 1
            S_LeftColumn.BorderSizePixel = 0
            S_LeftColumn.ScrollBarThickness = 3
            S_LeftColumn.ScrollBarImageColor3 = Library.Theme.Accent
            S_LeftColumn.Parent = SubTabPage
            Library:RegisterAccent(S_LeftColumn, "ScrollBarImageColor3")

            local SL_Layout = Instance.new("UIListLayout")
            SL_Layout.SortOrder = Enum.SortOrder.LayoutOrder
            SL_Layout.Padding = UDim.new(0, 10)
            SL_Layout.Parent = S_LeftColumn
            SL_Layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
                S_LeftColumn.CanvasSize = UDim2.new(0, 0, 0, SL_Layout.AbsoluteContentSize.Y + 10)
            end)

            local S_RightColumn = Instance.new("ScrollingFrame")
            S_RightColumn.Name = "RightColumn"
            S_RightColumn.Size = UDim2.new(0, 220, 1, -20)
            S_RightColumn.Position = UDim2.new(0, 245, 0, 10)
            S_RightColumn.BackgroundTransparency = 1
            S_RightColumn.BorderSizePixel = 0
            S_RightColumn.ScrollBarThickness = 3
            S_RightColumn.ScrollBarImageColor3 = Library.Theme.Accent
            S_RightColumn.Parent = SubTabPage
            Library:RegisterAccent(S_RightColumn, "ScrollBarImageColor3")

            local SR_Layout = Instance.new("UIListLayout")
            SR_Layout.SortOrder = Enum.SortOrder.LayoutOrder
            SR_Layout.Padding = UDim.new(0, 10)
            SR_Layout.Parent = S_RightColumn
            SR_Layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
                S_RightColumn.CanvasSize = UDim2.new(0, 0, 0, SR_Layout.AbsoluteContentSize.Y + 10)
            end)

            local SubTabObj = {
                Button = SubTabBtn,
                Page = SubTabPage
            }

            local function selectSubTab()
                if self.SelectedSubTab == SubTabObj then return end
                
                if self.SelectedSubTab then
                    self.SelectedSubTab.Page.Visible = false
                    self.SelectedSubTab.Button.TextColor3 = Library.Theme.TextMuted
                end

                self.SelectedSubTab = SubTabObj
                MainColumnsFrame.Visible = true
                SubTabPage.Visible = true
                Library:RegisterAccent(SubTabBtn, "TextColor3")
            end

            SubTabBtn.MouseButton1Click:Connect(selectSubTab)

            if not self.SelectedSubTab then
                selectSubTab()
            end

            return setupSectionCreator(S_LeftColumn, S_RightColumn)
        end

        -- Backward compatible CreateSection implementation
        function TabObj:CreateSection(sectionName, column)
            return defaultInterface:CreateSection(sectionName, column)
        end

        return TabObj
    end

    -- Built-in customization tab (live theme editor + menu settings + config manager).
    -- Deferred so it is appended AFTER the user's own tabs (and isn't auto-selected).
    if options.Customization ~= false then
        task.defer(function()
            if not self.ScreenGui or not self.ScreenGui.Parent then return end

            local Tab = WindowObj:CreateTab("Customize", "rbxassetid://106205298246017")

            -- Live theme editor: one color picker per Theme color
            local ThemeSec = Tab:CreateSection("Theme", "Left")
            local themeOrder = {
                { key = "Accent",    label = "accent" },
                { key = "Background", label = "background" },
                { key = "Card",      label = "card / sections" },
                { key = "Element",   label = "inputs" },
                { key = "Element2",  label = "buttons / tracks" },
                { key = "Border",    label = "borders" },
                { key = "Text",      label = "text" },
                { key = "TextMuted", label = "muted text" },
                { key = "Hover",     label = "hover" },
                { key = "Active",    label = "active" },
            }
            for _, entry in ipairs(themeOrder) do
                ThemeSec:CreateColorPicker({
                    Name = entry.label,
                    Default = self.Theme[entry.key],
                    Callback = function(color)
                        self:SetThemeColor(entry.key, color)
                    end,
                    ConfigName = "Theme_" .. entry.key
                })
            end

            -- Menu behavior settings
            local MenuSec = Tab:CreateSection("Menu", "Right")
            MenuSec:CreateToggle({
                Name = "animations",
                Default = not self.DisableAnimations,
                Callback = function(state) self.DisableAnimations = not state end,
                ConfigName = "Menu_Animations"
            })
            MenuSec:CreateToggle({
                Name = "watermark",
                Default = self.WatermarkFrame ~= nil and self.WatermarkFrame.Visible,
                Callback = function(state)
                    if state then self:SetWatermark(self.WatermarkText or titleText) else self:SetWatermark(nil) end
                end,
                ConfigName = "Menu_Watermark"
            })
            MenuSec:CreateToggle({
                Name = "keybind list",
                Default = self.KeybindListFrame ~= nil and self.KeybindListFrame.Visible,
                Callback = function(state) self:SetKeybindListVisible(state) end,
                ConfigName = "Menu_KeybindList"
            })
            MenuSec:CreateKeybind({
                Name = "menu toggle key",
                Default = self.ToggleKey,
                Callback = function(key) self.ToggleKey = key end,
                ConfigName = "Menu_ToggleKey"
            })
            MenuSec:CreateButton({
                Name = "unload UI",
                Callback = function() self:Unload() end
            })

            -- Config manager
            local ConfigSec = Tab:CreateSection("Config", "Right")
            self:CreateConfigSection(ConfigSec)

            -- Bind every static element to its theme color so the editor recolors the whole UI live
            self:RefreshThemeBindings()
        end)
    end

    return WindowObj
end

-- Built-in Config Section Generator using Roblox File System or In-Memory
function Library:CreateConfigSection(section)
    local ConfigListDropdown
    local NewConfigNameText = ""

    local function getConfigs()
        local list = {}
        if listfiles then
            local success, files = pcall(function()
                return listfiles(self.ConfigFolder)
            end)
            if success and files then
                for _, file in ipairs(files) do
                    local name = file:match("([^/]+)%.json$") or file:match("([^\\]+)%.json$")
                    if name then
                        table.insert(list, name)
                    end
                end
            end
        else
            for name, _ in pairs(self.InMemoryConfigs) do
                table.insert(list, name)
            end
        end
        if #list == 0 then
            table.insert(list, "default")
        end
        return list
    end

    local currentSelected = "default"

    -- Config list dropdown
    ConfigListDropdown = section:CreateDropdown({
        Name = "select config",
        Options = getConfigs(),
        Default = "default",
        Callback = function(selected)
            currentSelected = selected
        end,
        ConfigName = "ConfigSystem_Selected"
    })

    -- Textbox for new config name
    section:CreateTextbox({
        Name = "new config name",
        Placeholder = "Enter name...",
        Default = "",
        Callback = function(text)
            NewConfigNameText = text
        end,
        ConfigName = "ConfigSystem_NewName"
    })

    -- Load button
    section:CreateButton({
        Name = "load config",
        Callback = function()
            local success = self:LoadConfig(currentSelected)
            if success then
                self:Notify({
                    Title = "Config Loaded",
                    Content = "Successfully applied '" .. currentSelected .. "'",
                    Duration = 4
                })
            else
                self:Notify({
                    Title = "Error",
                    Content = "Failed to load '" .. currentSelected .. "'",
                    Duration = 4
                })
            end
        end
    })

    -- Save button
    section:CreateButton({
        Name = "save config",
        Callback = function()
            local target = (NewConfigNameText ~= "") and NewConfigNameText or currentSelected
            self:SaveConfig(target)
            self:Notify({
                Title = "Config Saved",
                Content = "Saved settings to '" .. target .. "'",
                Duration = 4
            })
            ConfigListDropdown:Set(getConfigs())
        end
    })

    -- Delete button
    section:CreateButton({
        Name = "delete config",
        Callback = function()
            if delfile then
                pcall(function()
                    delfile(self.ConfigFolder .. "/" .. currentSelected .. ".json")
                end)
            else
                self.InMemoryConfigs[currentSelected] = nil
            end
            self:Notify({
                Title = "Config Deleted",
                Content = "Removed config '" .. currentSelected .. "'",
                Duration = 4
            })
            ConfigListDropdown:Set(getConfigs())
        end
    })

    -- Refresh button
    section:CreateButton({
        Name = "refresh list",
        Callback = function()
            ConfigListDropdown:Set(getConfigs())
        end
    })
end

return Library
