# Premium Roblox UI Library (V6 Ultimate Edition)

A highly optimized, professional, and visually stunning "skeet/gamesense" style UI library designed for Roblox Studio and external execution. Built with pure Luau, it features horizontal top navigation, vertical sub-tabs, a 2-column section layout, advanced animations, toast notifications, a watermark, an active keybinds list, a dynamic theme engine, and a built-in config manager.

**New in V6:** intro loader screen, modal dialogs, hover tooltips, four new components (Label, Paragraph, Divider, Progress Bar, Segmented Control), themed accent-colored scrollbars, animated open/close + click-outside-to-close dropdowns, richer hover states, and a shared input dispatcher that eliminates per-slider connection leaks.

---

## Features
*   **CanvasGroup-based Toggle**: Fade and scale animations when toggling the menu visibility (default key: `Insert`).
*   **Horizontal Top-Navigation**:
    *   Active Tab: Icon + Text (e.g., `🎯 Aimbot`) inside a clean pill button with a border.
    *   Inactive Tabs: **Icon-only** (e.g., `👁`, `🎒`, `⚙`), using Lucide icons from `icons.rest`.
*   **Vertical Sub-Tabs**: Any main tab page can optionally split into vertical sub-navigation on the left (e.g., `General`, `Accuracy`), shifting section columns to the right.
*   **Dynamic Theme Engine**: Real-time accent color updating via `Library:UpdateAccentColor(newColor)` using a weak-keyed registry to prevent memory leaks.
*   **Floating Active Binds List**: Draggable status window displaying all active keybinds.
*   **Built-in Config Manager**: Automatically populates a section with save, load, delete, and refresh controls using Roblox file system APIs.
*   **Interactive Menu Settings**:
    *   Toggleable watermark and active binds list visibility.
    *   Rebindable menu toggle hotkey (e.g. change from `Insert` to any key).
    *   Toggleable fade/scale animations for instant opening/closing.
    *   Complete `Unload` button to clean up all connections and UI elements.
*   **Dynamic Watermark System**:
    *   Accepts a prefix (e.g. `Reptillian V5`) and automatically appends the local player's Roblox Display Name, real-time FPS, and round-trip Ping (latency).
    *   Automatically updates every 0.5 seconds using a background loop.
*   **Advanced Toggle Controls**: Checkbox toggles can optionally house **inline keybinds** and **inline color pickers** on the same row.
*   **Intro Loader Screen**: Animated splash with an accent progress bar and live status text, driven manually via a controller, shown before the window opens.
*   **Modal Dialogs**: Centered confirm/prompt popups with a dimmed background and configurable buttons (accent-styled primary).
*   **Hover Tooltips**: Any component accepts a `Tooltip` field — a small floating label follows the cursor on hover.
*   **New Components**: `Label`, `Paragraph`, `Divider`, `Progress Bar`, and `Segmented Control`.
*   **Themed Scrollbars**: Section/sub-tab/dropdown scrollbars use the live accent color.
*   **Smarter Dropdowns**: Animated open/close height tween, hover states, and click-outside-to-close.
*   **Built-in Customization (auto)**: Every window automatically gets a **Customize** tab — a live theme editor (a color picker for *every* theme color that recolors the whole UI in real time), menu behavior toggles (animations, watermark, keybind list, toggle key, unload), and the config manager. Opt out with `Customization = false` in `CreateWindow`.

---

## Quick Start Example

```lua
-- Load the library
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/your-repo/library.lua"))()

-- Set a dynamic Watermark (Displays: Reptillian V5 | [DisplayName] | FPS: [FPS] | Ping: [Ping]ms)
Library:SetWatermark("Reptillian V5")

-- Enable the floating keybind list
Library:SetKeybindListVisible(true)

-- Send toast notifications
Library:Notify({
    Title = "Reptillian V5 Loaded",
    Content = "Press [Insert] to toggle menu",
    Duration = 8
})

-- Create the main window
local Window = Library:CreateWindow({
    Name = "Reptillian V5",
    Info = "Ultimate Edition (June 2026)"
})

-- Create Tabs (Name, Icon from icons.rest)
local AimbotTab = Window:CreateTab("Aimbot", "rbxassetid://83752373575368")     -- Lucide crosshair
local SettingsTab = Window:CreateTab("Settings", "rbxassetid://106205298246017")   -- Lucide settings

----------------------------------------------
-- Aimbot Tab (With Sub-Tabs!)
----------------------------------------------
local GeneralSub = AimbotTab:CreateSubTab("General")
local AccuracySub = AimbotTab:CreateSubTab("Accuracy")

-- Create sections inside General Sub-Tab
local GenLeft = GeneralSub:CreateSection("Aimbot General", "Left")

-- Toggle with inline Keybind & inline Color Picker
GenLeft:CreateToggle({
    Name = "silent aim",
    Default = true,
    HasColor = true,
    ColorDefault = Color3.fromRGB(160, 140, 255),
    ColorCallback = function(color, alpha)
        print("Inline color changed:", color)
    end,
    HasKeybind = true,
    KeybindDefault = Enum.KeyCode.F,
    KeybindCallback = function(key)
        print("Inline keybind changed:", key.Name)
    end,
    ConfigName = "SilentAim"
})

----------------------------------------------
-- Settings Tab (Dynamic Theme, Menu Settings, Configs)
----------------------------------------------
local ThemeSection = SettingsTab:CreateSection("Theme Customization", "Left")
local MenuSection = SettingsTab:CreateSection("Menu Settings", "Left")
local ConfigSection = SettingsTab:CreateSection("Configuration", "Right")

-- Real-time Accent Color Picker
ThemeSection:CreateColorPicker({
    Name = "accent color",
    Default = Library.Theme.Accent,
    Callback = function(color)
        Library:UpdateAccentColor(color)
    end,
    ConfigName = "MenuAccentColor"
})

-- Menu Settings (Toggleable options)
MenuSection:CreateToggle({
    Name = "show keybind list",
    Default = true,
    Callback = function(state)
        Library:SetKeybindListVisible(state)
    end,
    ConfigName = "ShowKeybindList"
})

MenuSection:CreateToggle({
    Name = "show watermark",
    Default = true,
    Callback = function(state)
        if state then
            Library:SetWatermark("Reptillian V5")
        else
            Library:SetWatermark(nil)
        end
    end,
    ConfigName = "ShowWatermark"
})

MenuSection:CreateKeybind({
    Name = "menu toggle key",
    Default = Enum.KeyCode.Insert,
    Callback = function(key)
        Library.ToggleKey = key
    end,
    ConfigName = "MenuToggleKey"
})

MenuSection:CreateToggle({
    Name = "disable animations",
    Default = false,
    Callback = function(state)
        Library.DisableAnimations = state
    end,
    ConfigName = "DisableAnimations"
})

MenuSection:CreateButton({
    Name = "unload UI",
    Callback = function()
        Library:Unload()
    end
})

-- Built-in Config Manager UI
Library:CreateConfigSection(ConfigSection)
```

---

## API Reference

### `Library`

#### `Library:SetWatermark(prefixText)`
Enables and configures the dynamic watermark at the top-left of the screen. Updates every 0.5s to display the prefix, Roblox Display Name, FPS, and Ping. Pass `nil` or an empty string to hide it.

#### `Library:Notify(options)`
Pops up a toast notification at the bottom-right corner.
*   **Options**: `Title`, `Content`, `Duration`.

#### `Library:SetKeybindListVisible(visible)`
Toggles the visibility of the draggable active binds window.

#### `Library:UpdateKeybindList(name, active, stateText)`
Manually updates or adds a row to the active keybinds list.

#### `Library:SetThemeColor(key, newColor)`
Changes any theme color and tweens **every bound element** to it live. Valid keys: `Accent`, `Background`, `Card`, `Element` (inputs), `Element2` (buttons/tracks), `Border`, `Text`, `TextMuted`, `Hover`, `Active`.

#### `Library:UpdateAccentColor(newColor)`
Convenience wrapper for `SetThemeColor("Accent", newColor)`.

#### `Library:RegisterTheme(instance, property, key)`
Binds an instance's color property to a theme key so it recolors live. `Library:RegisterAccent(instance, property)` is the shorthand for the `Accent` key.

#### `Library:RefreshThemeBindings()`
Scans the whole UI and auto-binds any element whose current color matches a theme color. Called automatically when the built-in Customize tab is set up, so static elements recolor with the theme — call it manually if you build UI dynamically after that.

#### Built-in Customize tab
`Library:CreateWindow` auto-appends a **Customize** tab (theme editor + menu settings + config manager) unless you pass `Customization = false`. It's added after your own tabs, so your first tab stays the default.

#### `Library:CreateConfigSection(sectionInstance)`
Generates a complete config manager UI inside the specified section.

#### `Library:Unload()`
Destroys the UI ScreenGui and disconnects all global input connections (preventing memory leaks).

#### `Library:CreateLoader(options)`
Shows an intro/splash loader **before** `CreateWindow`. Returns a controller. Non-blocking.
*   **Options**: `Title`, `Subtitle`.
*   **Controller**:
    *   `:SetProgress(pct, statusText)` — `pct` accepts `0..1` or `0..100`; tweens the accent fill bar and updates the percent + status text.
    *   `:Finish(callback)` — fades the loader out, destroys it, then runs `callback`.

```lua
local loader = Library:CreateLoader({ Title = "Reptillian V6", Subtitle = "Initializing..." })
task.spawn(function()
    for i = 0, 100, 10 do
        loader:SetProgress(i, "Loading module " .. i .. "%")
        task.wait(0.1)
    end
    loader:Finish(function()
        local Window = Library:CreateWindow({ Name = "Reptillian V6" })
        -- ...build tabs/sections here...
    end)
end)
```

#### `Library:Dialog(options)`
Opens a centered modal dialog over a dimmed background. The first button is styled as the accent primary.
*   **Options**: `Title`, `Content`, `Buttons` (a list of `{ Text = "...", Callback = function() end }`; defaults to a single `OK`). Clicking any button closes the dialog, then fires its callback.

```lua
Library:Dialog({
    Title = "Confirm Unload",
    Content = "Are you sure you want to unload the UI?",
    Buttons = {
        { Text = "Unload", Callback = function() Library:Unload() end },
        { Text = "Cancel" }
    }
})
```

#### `Library:AttachTooltip(instance, text)`
Attaches a cursor-following hover tooltip to any GUI object. Most components accept a `Tooltip` option that calls this for you, so you rarely need it directly.

---

### `TabInstance`

#### `TabInstance:CreateSubTab(name)`
Splits the tab page into a vertical sub-navigation layout. Returns a sub-tab instance supporting `:CreateSection(name, column)`.

---

### `SectionInstance`

Sections are created via `Tab:CreateSection(name, "Left"|"Right")` (or on a sub-tab). Every component below is a method on the returned section instance. Components that take a `ConfigName` are saved/restored by the config manager. **All input components also accept an optional `Tooltip` (string)** that shows a hover tooltip.

#### `:CreateToggle(options)`
Checkbox toggle. **Options**: `Name`, `Default` (bool), `Callback(state)`, `ConfigName`. Optional inline add-ons: `HasColor`, `ColorDefault`, `ColorAlpha`, `ColorCallback(color, alpha)`; `HasKeybind`, `KeybindDefault`, `KeybindCallback(key)`. Returns a controller with `:Set(bool)`.

#### `:CreateKeybind(options)`
Standalone rebindable key. **Options**: `Name`, `Default` (`Enum.KeyCode`), `Callback(key)`, `ConfigName`. Returns `:Set(key)`.

#### `:CreateTextbox(options)`
Text input. **Options**: `Name`, `Placeholder`, `Default`, `Callback(text)`, `ConfigName`. Returns `:Set(text)`.

#### `:CreateSlider(options)`
Numeric slider. **Options**: `Name`, `Min`, `Max`, `Default`, `Suffix`, `Callback(value)`, `ConfigName`. Returns `:Set(value)`.

#### `:CreateDropdown(options)`
Single-select dropdown (animated, click-outside-to-close). **Options**: `Name`, `Options` (table), `Default`, `Callback(value)`, `ConfigName`. Returns `:Set(value)`.

#### `:CreateMultiDropdown(options)`
Multi-select dropdown. **Options**: `Name`, `Options` (table), `Default` (table of selected), `Callback(selectedTable)`, `ConfigName`. Returns `:Set(selectedTable)`.

#### `:CreateColorPicker(options)`
HSV color picker with opacity. **Options**: `Name`, `Default` (`Color3`), `Alpha` (0–1), `Callback(color, alpha)`, `ConfigName`. Returns `:Set(color, alpha)`.

#### `:CreateButton(options)`
Clickable button. **Options**: `Name`, `Callback()`.

#### `:CreateESPPreview(options)`
3D rotating preview of the **local player's Roblox avatar** (falls back to a blocky dummy if the avatar can't be fetched). **Options**: `Name`, `Floating` (bool). When `Floating = true` the preview renders in its own panel glued to the **left of the main window** (fades/hides with the menu) instead of embedding in the section. Returns a controller with `:SetBox(b)`, `:SetSkeleton(b)`, `:SetHealth(b)`, `:SetName(b)`, `:SetChams(b)`.

#### `:CreateESPSection(options)`
All-in-one helper that builds the 3D avatar preview **and** the feature toggles (Box, Skeleton, Health, Name, Chams) already wired to it — no manual wiring. By default the preview **floats to the left of the main window**; the toggles stay in the section. Pass `Floating = false` to embed the preview inline instead.
*   **Options**:
    *   `Name` (string): Preview label.
    *   `Floating` (bool, default `true`): Float the preview left of the window vs. embed it in the section.
    *   `ConfigName` (string): Prefix for each toggle's config key (e.g. `"ESP"` → `ESP_Box`, `ESP_Chams`...). Saves/loads with the config manager.
    *   `Features` (table, optional): Restrict which toggles appear, e.g. `{ "Box", "Chams" }`. Omit for all five.
    *   `Defaults` (table, optional): Initial on/off per feature, e.g. `{ Box = true, Chams = false }`.
*   **Returns** a controller: `.Preview` (the underlying ESP preview controller) and `.Toggles` (map of feature key → toggle controller).

```lua
local espSection = VisualsTab:CreateSection("ESP", "Left")

local esp = espSection:CreateESPSection({
    Name = "player esp",
    ConfigName = "PlayerESP",
    Defaults = { Box = true, Name = true },
    -- Features = { "Box", "Skeleton", "Chams" },  -- optional subset
})

-- Drive it manually if needed:
esp.Toggles.Box:Set(false)
esp.Preview:SetChams(true)
```

---

#### New in V6

#### `:CreateLabel(options)`
Single-line static text. **Options**: `Text`, `Tooltip`. Returns `:Set(text)`.

#### `:CreateParagraph(options)`
Wrapping multi-line text with an optional title. **Options**: `Title` (optional), `Text`. Returns `:Set(text)` and `:SetTitle(title)`.

#### `:CreateDivider(options)`
A thin themed separator. **Options**: `Text` (optional) — when provided, a centered label splits the line.

#### `:CreateProgressBar(options)`
Display-only animated accent fill bar. **Options**: `Name`, `Max` (default `100`), `Default`, `Suffix` (default `"%"`), `Tooltip`. Returns `:Set(value)`.

#### `:CreateSegmented(options)`
Pill-style single selector (compact inline switcher). **Options**: `Name`, `Options` (table), `Default`, `Callback(value)`, `ConfigName`, `Tooltip`. Returns `:Set(value)`.

```lua
local section = MiscTab:CreateSection("New Components", "Left")

section:CreateLabel({ Text = "Status: Ready", Tooltip = "Current module status" })
section:CreateParagraph({ Title = "About", Text = "This panel demonstrates the V6 components with wrapping body text." })
section:CreateDivider({ Text = "Options" })

section:CreateSegmented({
    Name = "aim mode",
    Options = { "Closest", "Crosshair", "Random" },
    Default = "Closest",
    Callback = function(mode) print("Mode:", mode) end,
    ConfigName = "AimMode"
})

local bar = section:CreateProgressBar({ Name = "load", Default = 0 })
bar:Set(75)
```
