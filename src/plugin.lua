local Models = require("models")

local function modelOf(props)
  return Models.Get(props["Model"].Value)
end

function GetColor(props)
  return { 28, 72, 128 }
end

function GetPrettyName(props)
  return modelOf(props).Name .. " Control"
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
  local WHITE = { 255, 255, 255 }

  local function box(title, x, y, w, h)
    graphics[#graphics + 1] = {
      Type = "GroupBox", Text = title, Fill = { 52, 56, 64 }, StrokeColor = { 90, 96, 108 },
      StrokeWidth = 1, CornerRadius = 6, HTextAlign = "Left", Position = { x, y }, Size = { w, h },
    }
  end
  local function label(title, x, y, w)
    graphics[#graphics + 1] = {
      Type = "Text", Text = title, Position = { x, y }, Size = { w, 18 }, FontSize = 12,
      HTextAlign = "Right", Color = WHITE,
    }
  end
  local function control(name, style, x, y, w, h, extra)
    local c = { PrettyName = name, Style = style, Position = { x, y }, Size = { w, h }, FontSize = 12 }
    for k, v in pairs(extra or {}) do c[k] = v end
    layout[name] = c
  end
  local function button(name, legend, x, y, w, h)
    control(name, "Button", x, y, w, h, { Legend = legend })
  end

  -- Connection
  box("Connection", 5, 5, 430, 110)
  label("Model", 15, 30, 85)
  control("Model", "Text", 105, 28, 160, 22)
  label("Connected", 275, 30, 85)
  control("Connected", "Led", 365, 28, 22, 22)
  label("IP Address", 15, 58, 85)
  control("IPAddress", "Text", 105, 56, 160, 22)
  label("Status", 15, 86, 85)
  control("Status", "Text", 105, 84, 320, 22)

  -- Power
  box("Power", 5, 120, 430, 60)
  button("PowerOn", "On", 15, 145, 90, 28)
  button("PowerOff", "Off", 110, 145, 90, 28)
  control("PowerState", "Led", 215, 148, 22, 22)
  control("PowerText", "Text", 242, 148, 100, 22)

  -- Input
  box("Input", 5, 185, 430, 55)
  control("Input", "ComboBox", 15, 210, 250, 24)

  -- Image
  box("Image", 5, 245, 430, 55)
  button("Shutter", "Shutter", 15, 270, 120, 26)
  layout["Shutter"].PrettyName = "Shutter (Image Mute)"
  button("Freeze", "Freeze", 140, 270, 120, 26)

  -- Menu navigation
  box("Menu", 5, 305, 205, 130)
  button("Menu", "Menu", 15, 330, 60, 28)
  button("Up", "Up", 80, 330, 60, 28)
  button("Default", "Default", 145, 330, 60, 28)
  button("Left", "Left", 15, 362, 60, 28)
  button("Enter", "Enter", 80, 362, 60, 28)
  button("Right", "Right", 145, 362, 60, 28)
  button("Down", "Down", 80, 394, 60, 28)
  if m.Features.AutoSetup then button("AutoSetup", "Auto Setup", 145, 394, 60, 28) end

  -- Lens
  box("Lens", 215, 305, 220, 130)
  if m.Features.LensShift then
    button("LensShiftUp", "Up", 266, 330, 42, 28)
    button("LensShiftLeft", "Left", 222, 362, 42, 28)
    button("LensShiftRight", "Right", 310, 362, 42, 28)
    button("LensShiftDown", "Down", 266, 394, 42, 28)
  end
  if m.Features.Focus then
    button("FocusPlus", "Foc +", 358, 330, 34, 28)
    button("FocusMinus", "Foc -", 394, 330, 34, 28)
  end
  if m.Features.Zoom then
    button("ZoomPlus", "Zm +", 358, 362, 34, 28)
    button("ZoomMinus", "Zm -", 394, 362, 34, 28)
  end

  -- Diagnostics
  box("Diagnostics", 5, 440, 430, 125)
  label("Detail", 15, 465, 80)
  control("DetailText", "Text", 100, 463, 325, 22)
  label("ERRS1", 15, 491, 80)
  control("Diag1", "Text", 100, 489, 325, 22)
  label("ERRS2", 15, 517, 80)
  control("Diag2", "Text", 100, 515, 325, 22)
  label("Last reply", 15, 543, 80)
  control("LastResponse", "Text", 100, 541, 325, 22)

  return layout, graphics
end

function GetPages(props)
  return { { name = "Control" } }
end

-- Runtime only: Controls does not exist at design time.
if Controls then
  require("runtime")()
end
