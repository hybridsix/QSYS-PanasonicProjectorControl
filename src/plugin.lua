-- =============================================================
-- plugin.lua
-- Panasonic Projector Control
-- Author: Michael King
--
-- Design-time definition (properties, controls, layout, pages)
-- plus the runtime hook. Runtime logic lives in runtime.lua and
-- only executes on a running Core. build.js bundles src/ into
-- the single .qplug file that Q-SYS Designer loads.
-- =============================================================

local Models = require("models")

local function modelOf(props)
  return Models.Get(props["Model"].Value)
end

-- Colour bar on the plugin block in the schematic.
-- Clair Global "Patch of Blue" brand colour (#15a3d5 family).
function GetColor(props)
  return { 0, 210, 255 }
end

-- Block face label. Non-breaking spaces (U+00A0) stop Q-SYS from
-- word-wrapping the title. The selected model is shown underneath.
function GetPrettyName(props)
  local nbsp = "\xC2\xA0"
  return "Projector" .. nbsp .. "Control" .. "\n" .. modelOf(props).Name
end

function GetProperties()
  local props = {
    { Name = "Model", Type = "enum", Choices = Models.Ids, Value = Models.Default },
    { Name = "IP Address", Type = "string", Value = "192.168.10.100" },
    { Name = "Port", Type = "integer", Min = 1, Max = 65535, Value = 1024 },
    { Name = "Lens Speed", Type = "enum", Choices = { "Slow", "Normal", "Fast" }, Value = "Normal" },
  }
  -- One switch per optional input of every model; the ones that do not
  -- belong to the selected model are hidden by RectifyProperties.
  for _, id in ipairs(Models.Ids) do
    for _, opt in ipairs(Models.ById[id].OptionalInputs or {}) do
      props[#props + 1] = { Name = Models.OptionalPropertyName(opt), Type = "boolean", Value = false }
    end
  end
  props[#props + 1] = { Name = "Debug Print", Type = "enum", Choices = { "None", "Tx/Rx", "All" }, Value = "None" }
  return props
end

function RectifyProperties(props)
  local selected = props["Model"].Value
  for _, id in ipairs(Models.Ids) do
    for _, opt in ipairs(Models.ById[id].OptionalInputs or {}) do
      local prop = props[Models.OptionalPropertyName(opt)]
      if prop then prop.IsHidden = (id ~= selected) end
    end
  end
  return props
end

function GetControls(props)
  local m = modelOf(props)
  local ctrls = {}

  local function add(c) ctrls[#ctrls + 1] = c end
  local function trigger(name)
    add({ Name = name, ControlType = "Button", ButtonType = "Trigger", PinStyle = "Input", UserPin = true })
  end
  local function toggle(name)
    add({ Name = name, ControlType = "Button", ButtonType = "Toggle", PinStyle = "Both", UserPin = true })
  end
  local function text(name)
    add({ Name = name, ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true })
  end
  local function led(name)
    add({ Name = name, ControlType = "Indicator", IndicatorType = "Led", PinStyle = "Output", UserPin = true })
  end

  trigger("PowerOn")
  trigger("PowerOff")
  led("PowerState")
  text("PowerText")

  add({ Name = "Input", ControlType = "Text", PinStyle = "Both", UserPin = true })
  toggle("Shutter")
  toggle("Freeze")

  for _, name in ipairs({ "Menu", "Enter", "Up", "Down", "Left", "Right", "Default" }) do
    trigger(name)
  end
  if m.Features.AutoSetup then trigger("AutoSetup") end

  for _, lens in ipairs(Models.LensControls) do
    if m.Features[lens.Feature] then
      add({ Name = lens.Name, ControlType = "Button", ButtonType = "Momentary", PinStyle = "Input", UserPin = true })
    end
  end

  led("Connected")
  add({ Name = "Status", ControlType = "Indicator", IndicatorType = "Status", PinStyle = "Output", UserPin = true })
  text("Model")
  text("IPAddress")
  text("DetailText")
  text("Diag1")
  text("Diag2")
  text("LastResponse")

  return ctrls
end

function GetControlLayout(props)
  local m = modelOf(props)
  local layout, graphics = {}, {}
  local TEXT = { 60, 60, 60 }
  local PRETTY = {
    Model = "Status~Model", Connected = "Status~Connected", IPAddress = "Status~IP Address",
    Status = "Status~Connection",
    PowerOn = "Power~On", PowerOff = "Power~Off", PowerState = "Power~State",
    PowerText = "Power~State Text",
    Input = "Input~Select",
    Shutter = "Image~Shutter (Image Mute)", Freeze = "Image~Freeze",
    Menu = "Menu~Menu", Up = "Menu~Up", Down = "Menu~Down", Left = "Menu~Left",
    Right = "Menu~Right", Enter = "Menu~Enter", Default = "Menu~Default",
    AutoSetup = "Menu~Auto Setup",
    LensShiftUp = "Lens~Shift Up", LensShiftDown = "Lens~Shift Down",
    LensShiftLeft = "Lens~Shift Left", LensShiftRight = "Lens~Shift Right",
    FocusPlus = "Lens~Focus +", FocusMinus = "Lens~Focus -",
    ZoomPlus = "Lens~Zoom +", ZoomMinus = "Lens~Zoom -",
    DetailText = "Diagnostics~Detail", Diag1 = "Diagnostics~ERRS1", Diag2 = "Diagnostics~ERRS2",
    LastResponse = "Diagnostics~Last Reply",
  }

  -- Panel width 500px: boxes at x=5, w=490, 5px grid.
  local function box(title, x, y, w, h)
    graphics[#graphics + 1] = {
      Type = "GroupBox", Text = title, Fill = { 195, 195, 195 }, StrokeWidth = 2,
      StrokeColor = { 0, 210, 255 }, CornerRadius = 8, Position = { x, y }, Size = { w, h },
    }
  end
  local function label(title, x, y, w)
    graphics[#graphics + 1] = {
      Type = "Text", Text = title, Position = { x, y }, Size = { w, 20 }, FontSize = 11,
      HTextAlign = "Right", Color = TEXT,
    }
  end
  local function control(name, style, x, y, w, h, extra)
    local c = { PrettyName = PRETTY[name] or name, Style = style, Position = { x, y }, Size = { w, h }, FontSize = 12 }
    for k, v in pairs(extra or {}) do c[k] = v end
    layout[name] = c
  end
  local function button(name, legend, x, y, w, h, color)
    control(name, "Button", x, y, w, h, { Legend = legend, Color = color })
  end

  -- Connection
  box("Connection", 5, 5, 490, 110)
  label("Model:", 10, 30, 75)
  control("Model", "Text", 90, 28, 195, 22)
  label("Connected:", 295, 30, 75)
  control("Connected", "Led", 375, 28, 22, 22)
  label("IP Address:", 10, 58, 75)
  control("IPAddress", "Text", 90, 56, 195, 22)
  label("Status:", 10, 86, 75)
  control("Status", "Text", 90, 84, 390, 22)

  -- Power
  box("Power", 5, 120, 490, 60)
  button("PowerOn", "Power On", 10, 145, 130, 28, { 0, 200, 220 })
  button("PowerOff", "Power Off", 145, 145, 130, 28, { 255, 140, 0 })
  control("PowerState", "Led", 290, 148, 22, 22)
  control("PowerText", "Text", 317, 148, 140, 22)

  -- Input
  box("Input", 5, 185, 490, 55)
  control("Input", "ComboBox", 10, 210, 250, 24)

  -- Image
  box("Image", 5, 245, 490, 55)
  button("Shutter", "Shutter", 10, 270, 130, 26)
  button("Freeze", "Freeze", 145, 270, 130, 26)

  -- Menu navigation
  box("Menu", 5, 305, 240, 130)
  button("Menu", "Menu", 15, 330, 60, 28)
  button("Up", "Up", 80, 330, 60, 28)
  button("Default", "Default", 145, 330, 60, 28)
  button("Left", "Left", 15, 362, 60, 28)
  button("Enter", "Enter", 80, 362, 60, 28)
  button("Right", "Right", 145, 362, 60, 28)
  button("Down", "Down", 80, 394, 60, 28)
  if m.Features.AutoSetup then button("AutoSetup", "Auto Setup", 145, 394, 60, 28) end

  -- Lens
  box("Lens", 250, 305, 245, 130)
  if m.Features.LensShift then
    button("LensShiftUp", "Up", 301, 330, 42, 28)
    button("LensShiftLeft", "Left", 257, 362, 42, 28)
    button("LensShiftRight", "Right", 345, 362, 42, 28)
    button("LensShiftDown", "Down", 301, 394, 42, 28)
  end
  if m.Features.Focus then
    button("FocusPlus", "Foc +", 400, 330, 40, 28)
    button("FocusMinus", "Foc -", 445, 330, 40, 28)
  end
  if m.Features.Zoom then
    button("ZoomPlus", "Zm +", 400, 362, 40, 28)
    button("ZoomMinus", "Zm -", 445, 362, 40, 28)
  end

  -- Diagnostics
  box("Diagnostics", 5, 440, 490, 125)
  label("Detail:", 10, 465, 75)
  control("DetailText", "Text", 90, 463, 390, 22)
  label("ERRS1:", 10, 491, 75)
  control("Diag1", "Text", 90, 489, 390, 22)
  label("ERRS2:", 10, 517, 75)
  control("Diag2", "Text", 90, 515, 390, 22)
  label("Last Reply:", 10, 543, 75)
  control("LastResponse", "Text", 90, 541, 390, 22)

  return layout, graphics
end

function GetPages(props)
  return { { name = "Control" } }
end

-- Runtime only: Controls does not exist at design time.
if Controls then
  require("runtime")()
end
