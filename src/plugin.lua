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

-- Temperature sensors; those with a Feature exist on some models only.
local TemperatureSensors = {
  { Prefix = "TemperatureIntake", Label = "Intake" },
  { Prefix = "TemperatureExhaust", Label = "Exhaust" },
  { Prefix = "TemperatureOptics", Label = "Optics", Feature = "TempOptics" },
  { Prefix = "TemperatureLight1", Label = "Light 1", Feature = "TempLight1" },
  { Prefix = "TemperatureLight2", Label = "Light 2", Feature = "TempLight2" },
}

local function sensorsFor(model)
  local list = {}
  for _, sensor in ipairs(TemperatureSensors) do
    if not sensor.Feature or model.Features[sensor.Feature] then list[#list + 1] = sensor end
  end
  return list
end

-- Colour bar on the plugin block in the schematic.
-- Clair Global "Patch of Blue" brand colour (#15a3d5 family).
function GetColor(props)
  return { 0, 210, 255 }
end

-- Device name from the Name property (e.g. "PRJ-201"); spaces become
-- non-breaking so the block face does not word-wrap it.
local function deviceName(props, default)
  local p = props["Name"]
  local name = p and p.Value or ""
  if name:match("^%s*$") then return default end
  return (name:gsub(" ", "\xC2\xA0"))
end

-- Block face label. Non-breaking spaces (U+00A0) stop Q-SYS from
-- word-wrapping the title. The Name property replaces the title when set;
-- the selected model is shown underneath.
function GetPrettyName(props)
  local nbsp = "\xC2\xA0"
  local title = "Projector" .. nbsp .. "Control"
  return deviceName(props, title) .. "\n" .. modelOf(props).Name
end

function GetProperties()
  local props = {
    { Name = "Name", Type = "string", Value = "" },
    { Name = "Model", Type = "enum", Choices = Models.Ids, Value = Models.Default },
    { Name = "IP Address", Type = "string", Value = "192.168.10.100" },
    { Name = "Port", Type = "integer", Min = 1, Max = 65535, Value = 1024 },
    { Name = "Lens Speed", Type = "enum", Choices = { "Slow", "Normal", "Fast" }, Value = "Normal" },
    { Name = "Normal Poll Interval (s)", Type = "integer", Min = 1, Max = 60, Value = 2 },
    { Name = "High Poll Interval (s)", Type = "integer", Min = 1, Max = 10, Value = 1 },
    { Name = "High Poll Timeout (s)", Type = "integer", Min = 5, Max = 180, Value = 30 },
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
  text("ProjectorState")

  add({ Name = "Input", ControlType = "Text", PinStyle = "Both", UserPin = true })
  led("ShutterState")
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

  text("LightSourceState")
  text("ProjectorHours")
  text("LightSource1Hours")
  if m.Features.Light2Hours then text("LightSource2Hours") end
  for _, sensor in ipairs(sensorsFor(m)) do
    text(sensor.Prefix .. "C")
    text(sensor.Prefix .. "F")
  end

  text("DetailText")
  text("Diag1")
  text("Diag2")
  text("LastResponse")

  add({ Name = "CustomCommand", ControlType = "Text", PinStyle = "Both", UserPin = true })
  add({ Name = "CustomReply", ControlType = "Indicator", IndicatorType = "Text", PinStyle = "Output", UserPin = true })
  trigger("CustomSend")

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
    PowerText = "Power~State Text", ProjectorState = "Health~Projector State",
    Input = "Input~Select",
    ShutterState = "Image~Shutter LED", Shutter = "Image~Shutter (Image Mute)", Freeze = "Image~Freeze",
    Menu = "Menu~Menu", Up = "Menu~Up", Down = "Menu~Down", Left = "Menu~Left",
    Right = "Menu~Right", Enter = "Menu~Enter", Default = "Menu~Default",
    AutoSetup = "Menu~Auto Setup",
    LensShiftUp = "Lens~Shift Up", LensShiftDown = "Lens~Shift Down",
    LensShiftLeft = "Lens~Shift Left", LensShiftRight = "Lens~Shift Right",
    FocusPlus = "Lens~Focus +", FocusMinus = "Lens~Focus -",
    ZoomPlus = "Lens~Zoom +", ZoomMinus = "Lens~Zoom -",
    DetailText = "Diagnostics~Detail", Diag1 = "Diagnostics~ERRS1", Diag2 = "Diagnostics~ERRS2",
    LastResponse = "Diagnostics~Last Reply",
    LightSourceState = "Health~Light Source State",
    ProjectorHours = "Health~Projector Hours",
    LightSource1Hours = "Health~Light Source 1 Hours",
    LightSource2Hours = "Health~Light Source 2 Hours",
    CustomCommand = "Raw~Command", CustomSend = "Raw~Send", CustomReply = "Raw~Reply",
  }
  for _, sensor in ipairs(TemperatureSensors) do
    PRETTY[sensor.Prefix .. "C"] = "Health~" .. sensor.Label .. " Temp C"
    PRETTY[sensor.Prefix .. "F"] = "Health~" .. sensor.Label .. " Temp F"
  end

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
  control("ShutterState", "Led", 145, 272, 18, 18)
  button("Freeze", "Freeze", 170, 270, 130, 26)

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

  -- Projector status: lifecycle, light source, hours and temperatures.
  -- Temperatures are shown as returned by the projector (C and F).
  local sensors = sensorsFor(m)
  local sy = 440
  local sensorRows = math.ceil(#sensors / 2)
  local sh = 77 + sensorRows * 26 + 8
  box("Projector Status", 5, sy, 490, sh)
  label("State:", 10, sy + 25, 75)
  control("ProjectorState", "Text", 90, sy + 23, 125, 22)
  label("Light Source:", 220, sy + 25, 80)
  control("LightSourceState", "Text", 305, sy + 23, 125, 22)
  label("Hours:", 10, sy + 51, 75)
  control("ProjectorHours", "Text", 90, sy + 49, 70, 22)
  label("Light 1:", 165, sy + 51, 50)
  control("LightSource1Hours", "Text", 220, sy + 49, 70, 22)
  if m.Features.Light2Hours then
    label("Light 2:", 295, sy + 51, 50)
    control("LightSource2Hours", "Text", 350, sy + 49, 70, 22)
  end
  for i, sensor in ipairs(sensors) do
    local col = (i - 1) % 2
    local row = math.floor((i - 1) / 2)
    local x = (col == 0) and 10 or 250
    local y = sy + 77 + row * 26
    label(sensor.Label .. " C/F:", x, y + 2, 75)
    control(sensor.Prefix .. "C", "Text", x + 80, y, 60, 22)
    control(sensor.Prefix .. "F", "Text", x + 145, y, 60, 22)
  end

  -- Diagnostics
  local dy = sy + sh + 5
  box("Diagnostics", 5, dy, 490, 125)
  label("Detail:", 10, dy + 25, 75)
  control("DetailText", "Text", 90, dy + 23, 390, 22)
  label("ERRS1:", 10, dy + 51, 75)
  control("Diag1", "Text", 90, dy + 49, 390, 22)
  label("ERRS2:", 10, dy + 77, 75)
  control("Diag2", "Text", 90, dy + 75, 390, 22)
  label("Last Reply:", 10, dy + 103, 75)
  control("LastResponse", "Text", 90, dy + 101, 390, 22)

  -- Raw command testing
  local ry = dy + 130
  box("Raw Command", 5, ry, 490, 75)
  control("CustomCommand", "TextBox", 15, ry + 26, 270, 24)
  button("CustomSend", "Send", 290, ry + 24, 60, 28, { 0, 200, 220 })
  control("CustomReply", "Text", 355, ry + 26, 130, 22)

  return layout, graphics
end

function GetPages(props)
  return { { name = "Control" } }
end

-- Runtime only: Controls does not exist at design time.
if Controls then
  require("runtime")()
end
