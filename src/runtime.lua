-- Runtime wiring: Q-SYS controls <-> engine/poller <-> TCP socket.
--
-- Called once from plugin.lua when `Controls` exists. All projector traffic
-- goes through the engine queue; control handlers never write to the socket.
return function()
  local Models = require("models")
  local Protocol = require("protocol")
  local Engine = require("engine")
  local Poller = require("poller")

  local TICK = 0.1
  -- UNVERIFIED: how often a held lens button repeats its move command.
  local LENS_REPEAT = 0.3

  local model = Models.Get(Properties["Model"].Value)
  local ip = Properties["IP Address"].Value
  local port = Properties["Port"].Value
  local lensSpeed = Properties["Lens Speed"].Value
  local debugMode = Properties["Debug Print"].Value
  local normalPoll = tonumber(Properties["Normal Poll Interval (s)"].Value) or 2
  local highPoll = tonumber(Properties["High Poll Interval (s)"].Value) or 1
  local highTimeout = tonumber(Properties["High Poll Timeout (s)"].Value) or 30

  local function dbg(kind, message)
    if debugMode == "All" or (debugMode == "Tx/Rx" and (kind == "tx" or kind == "rx")) then
      print(string.format("[Panasonic %s] %s", kind, tostring(message)))
    end
  end

  -- -------------------------------------------------------------------------
  -- Control helpers. Programmatic changes also fire EventHandlers, so
  -- feedback writes are wrapped to keep them from being sent back out.
  -- -------------------------------------------------------------------------
  local updating = false

  local function setText(control, value)
    if control.String ~= value then control.String = value end
  end

  local function setFlag(control, value)
    updating = true
    control.Boolean = value
    updating = false
  end

  local function setInputText(value)
    updating = true
    Controls.Input.String = value
    updating = false
  end

  local function setProjectorState(value)
    setText(Controls.ProjectorState, tostring(value or "Unknown"))
  end

  local function detail(message)
    setText(Controls.DetailText, message or "")
  end

  -- -------------------------------------------------------------------------
  -- Inputs: built-in inputs plus any optional inputs enabled in properties.
  -- -------------------------------------------------------------------------
  local inputs = {}
  for _, input in ipairs(model.Inputs) do inputs[#inputs + 1] = input end
  for _, input in ipairs(model.OptionalInputs or {}) do
    local prop = Properties[Models.OptionalPropertyName(input)]
    if prop and prop.Value then inputs[#inputs + 1] = input end
  end

  local labelToCode, choices = {}, {}
  for _, input in ipairs(inputs) do
    labelToCode[input.Label] = input.Code
    choices[#choices + 1] = input.Label
  end

  -- Map a QIN reply to a label: exact code first, then a unique match on the
  -- part after the comma (for example "SD1" for "DM1,SD1").
  local function labelForReply(reply)
    for _, input in ipairs(inputs) do
      if input.Code == reply then return input.Label end
    end
    local found
    for _, input in ipairs(inputs) do
      local suffix = input.Code:match(",(.+)$")
      if suffix == reply then
        if found then return nil end
        found = input.Label
      end
    end
    return found
  end

  -- -------------------------------------------------------------------------
  -- Engine and socket
  -- -------------------------------------------------------------------------
  local sock = TcpSocket.New()
  sock.ReconnectTimeout = 0 -- reconnects are driven by the engine

  local poller -- assigned below; handlers refer to it
  local known = { shutter = false, freeze = false }

  -- After a command, the affected key is polled at the high rate until the
  -- projector reports the expected value or the high-rate timeout passes.
  local waiting = {}

  local function expect(key, test)
    waiting[key] = test
    poller:Boost(key, highTimeout)
    poller:PollNow(key)
  end

  local function settled(key, value)
    local test = waiting[key]
    if test and test(value) then
      waiting[key] = nil
      poller:EndBoost(key)
    end
  end

  local COMM_ERRORS = { ["no response"] = true, ["connect timeout"] = true, ["socket error"] = true }

  local function showPowerUnknown()
    setFlag(Controls.PowerState, false)
    setText(Controls.PowerText, "Unknown")
    setProjectorState("Unknown")
    setText(Controls.LightSourceState, "Unknown")
  end

  local function onState(state, why)
    if state == "Ready" then
      Controls.Connected.Boolean = true
      Controls.Status.Value = 0
      Controls.Status.String = "OK"
      detail("")
      Log.Message("Panasonic projector connected: " .. ip)
      return
    end

    Controls.Connected.Boolean = false
    if poller then poller:Reset() end
    showPowerUnknown()

    if state == "Connecting" or state == "Greeting" then
      Controls.Status.Value = 5
      Controls.Status.String = (state == "Connecting") and "Connecting..." or "Initializing..."
    elseif state == "AuthRequired" then
      Controls.Status.Value = 2
      Controls.Status.String = "Command protect is on (authentication not supported)"
      Log.Error("Panasonic projector requires authentication, which this plugin does not support yet")
    elseif COMM_ERRORS[why] then
      Controls.Status.Value = 2
      Controls.Status.String = "Communication error"
      detail(tostring(why))
    else
      Controls.Status.Value = 4
      Controls.Status.String = "Disconnected"
      detail(why and tostring(why) or "")
    end
  end

  local engine = Engine.New({
    send = function(data) sock:Write(data) end,
    connect = function() sock:Connect(ip, port) end,
    disconnect = function() sock:Disconnect() end,
    log = function(kind, message)
      dbg(kind, message)
      if kind == "rx" then setText(Controls.LastResponse, message) end
    end,
    onState = onState,
  })

  -- -------------------------------------------------------------------------
  -- Poll feedback
  -- -------------------------------------------------------------------------
  local handlers = {}

  function handlers.power(ok, value, raw)
    if not ok then
      showPowerUnknown()
      poller:SetPower(nil)
      if raw then detail("Power reply not understood: " .. raw) end
      return
    end
    setFlag(Controls.PowerState, value == "On")
    setText(Controls.PowerText, value)
    poller:SetPower(value)
    settled("power", value)
  end

  -- QVX:POWI1: Off / Warming Up / On / Cooling. While the projector is in a
  -- transition it is polled at the high rate until it leaves it.
  function handlers.powi(ok, value, raw)
    if not ok then
      if raw then detail("Power state reply not understood: " .. raw) end
      return
    end
    setProjectorState(value)
    if value == "Unknown" then detail("Unrecognized power state reply: " .. tostring(raw)) end
    if value == "Warming Up" or value == "Cooling" then
      poller:Boost("powi", highTimeout)
    elseif not waiting.powi then
      poller:EndBoost("powi")
    end
    settled("powi", value)
  end

  -- Q$S: laser / light source lifecycle (separate from the power lifecycle).
  function handlers.lightstate(ok, value, raw)
    if not ok then
      setText(Controls.LightSourceState, "Unknown")
      if raw then detail("Light source reply not understood: " .. raw) end
      return
    end
    setText(Controls.LightSourceState, value)
    if value == "Unknown" then detail("Unrecognized light source reply: " .. tostring(raw)) end
  end

  -- Temperatures and hours keep the last good value when a reply fails.
  local function temperatureHandler(prefix, label)
    return function(ok, value, raw)
      if ok then
        setText(Controls[prefix .. "C"], tostring(value.c))
        setText(Controls[prefix .. "F"], tostring(value.f))
      elseif raw then
        detail(label .. " temperature reply not understood: " .. raw)
      end
    end
  end

  local function hoursHandler(controlName, label)
    return function(ok, value, raw)
      if ok then
        setText(Controls[controlName], tostring(value))
      elseif raw then
        detail(label .. " hours reply not understood: " .. raw)
      end
    end
  end

  handlers.tempIntake = temperatureHandler("TemperatureIntake", "Intake")
  handlers.tempExhaust = temperatureHandler("TemperatureExhaust", "Exhaust")
  handlers.tempOptics = temperatureHandler("TemperatureOptics", "Optics")
  handlers.tempLight1 = temperatureHandler("TemperatureLight1", "Light 1")
  handlers.tempLight2 = temperatureHandler("TemperatureLight2", "Light 2")
  handlers.hoursProj = hoursHandler("ProjectorHours", "Projector")
  handlers.hoursLight1 = hoursHandler("LightSource1Hours", "Light source 1")
  handlers.hoursLight2 = hoursHandler("LightSource2Hours", "Light source 2")

  function handlers.input(ok, value, raw)
    if not ok then
      if raw then detail("Input reply not understood: " .. raw) end
      return
    end
    local label = labelForReply(value)
    if label then
      setInputText(label)
    else
      setInputText(value)
      detail("Unrecognized input reply: " .. value)
    end
    settled("input", label or value)
  end

  function handlers.shutter(ok, value)
    if not ok then return end
    known.shutter = value
    setFlag(Controls.Shutter, value)
    setFlag(Controls.ShutterState, value)
    settled("shutter", value)
  end

  function handlers.freeze(ok, value)
    if not ok then return end
    known.freeze = value
    setFlag(Controls.Freeze, value)
    settled("freeze", value)
  end

  function handlers.diag1(ok, _, raw)
    if ok then setText(Controls.Diag1, raw) end
  end

  function handlers.diag2(ok, _, raw)
    if ok then setText(Controls.Diag2, raw) end
  end

  poller = Poller.New(engine, handlers, {
    NormalInterval = normalPoll,
    HighRateInterval = highPoll,
    Features = model.Features,
  })

  -- -------------------------------------------------------------------------
  -- Socket events
  -- -------------------------------------------------------------------------
  sock.EventHandler = function(_, event, err)
    if event == TcpSocket.Events.Connected then
      engine:OnConnected()
    elseif event == TcpSocket.Events.Data then
      local line = sock:ReadLine(TcpSocket.EOL.Custom, "\r")
      while line do
        engine:OnLine(line)
        line = sock:ReadLine(TcpSocket.EOL.Custom, "\r")
      end
    elseif event == TcpSocket.Events.Closed then
      engine:OnClosed("closed")
    elseif event == TcpSocket.Events.Error or event == TcpSocket.Events.Timeout then
      engine:OnClosed("socket error")
    end
  end

  -- -------------------------------------------------------------------------
  -- Control handlers (enqueue only)
  -- -------------------------------------------------------------------------
  local function send(name, spec, after)
    engine:Command(nil, spec, function(ok, reason)
      if not ok then detail(name .. " failed: " .. tostring(reason)) end
      if after then after(ok) end
    end)
  end

  Controls.PowerOn.EventHandler = function()
    send("Power on", Protocol.Commands.PowerOn, function(ok)
      if not ok then return end
      expect("powi", function(v) return v == "On" end)
      expect("power", function(v) return v == "On" end)
    end)
  end
  Controls.PowerOff.EventHandler = function()
    send("Power off", Protocol.Commands.PowerOff, function(ok)
      if not ok then return end
      expect("powi", function(v) return v == "Off" end)
      expect("power", function(v) return v == "Standby" end)
    end)
  end

  for _, name in ipairs({ "Menu", "Enter", "Up", "Down", "Left", "Right", "Default" }) do
    Controls[name].EventHandler = function()
      send(name, Protocol.Commands[name])
    end
  end

  if model.Features.AutoSetup then
    Controls.AutoSetup.EventHandler = function()
      send("Auto setup", Protocol.Commands.AutoSetup)
    end
  end

  Controls.Shutter.EventHandler = function(control)
    if updating then return end
    local wanted = control.Boolean
    send("Shutter", Protocol.ShutterCommand(wanted), function(ok)
      if ok then
        setFlag(Controls.ShutterState, wanted)
        expect("shutter", function(v) return v == wanted end)
      else
        setFlag(Controls.Shutter, known.shutter)
        setFlag(Controls.ShutterState, known.shutter)
      end
    end)
  end

  Controls.Freeze.EventHandler = function(control)
    if updating then return end
    local wanted = control.Boolean
    send("Freeze", Protocol.FreezeCommand(wanted), function(ok)
      if ok then
        expect("freeze", function(v) return v == wanted end)
      else
        setFlag(Controls.Freeze, known.freeze)
      end
    end)
  end

  Controls.Input.Choices = choices
  Controls.Input.EventHandler = function(control)
    if updating then return end
    local wanted = control.String
    local code = labelToCode[wanted]
    if not code then
      detail("Unknown input: " .. tostring(wanted))
      return
    end
    send("Input", Protocol.InputCommand(code), function(ok)
      if ok then expect("input", function(v) return v == wanted end) end
    end)
  end

  -- Lens: one move command on press, repeated while held.
  for _, lens in ipairs(Models.LensControls) do
    local control = Controls[lens.Name]
    if model.Features[lens.Feature] and control then
      local held = false
      local repeater = Timer.New()
      local function move()
        local spec = Protocol.LensCommand(model.Lens[lens.Function], lens.Direction, lensSpeed)
        engine:Command("lens:" .. lens.Name, spec, function(ok, reason)
          if not ok then detail(lens.Name .. " failed: " .. tostring(reason)) end
        end)
      end
      repeater.EventHandler = function()
        if held then move() else repeater:Stop() end
      end
      control.EventHandler = function(c)
        if c.Boolean then
          held = true
          move()
          repeater:Start(LENS_REPEAT)
        else
          held = false
          repeater:Stop()
        end
      end
    end
  end

  Controls.CustomCommand.String = "QPW"
  Controls.CustomReply.String = "Ready"
  Controls.CustomSend.EventHandler = function()
    local command = tostring(Controls.CustomCommand.String or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if command == "" then
      setText(Controls.CustomReply, "Empty")
      return
    end
    -- Not idempotent: an arbitrary command must never be sent twice.
    engine:Command("custom", { line = command, idempotent = false }, function(ok, value, raw)
      if ok then
        setText(Controls.CustomReply, raw or "OK")
      else
        setText(Controls.CustomReply, tostring(value or "Failed"))
      end
    end)
  end

  -- -------------------------------------------------------------------------
  -- Static info and start-up
  -- -------------------------------------------------------------------------
  Controls.Model.String = model.Name
  Controls.IPAddress.String = ip .. ":" .. tostring(port)
  Controls.Connected.Boolean = false
  showPowerUnknown()
  setProjectorState("Unknown")

  local clock = 0
  local ticker = Timer.New()
  ticker.EventHandler = function()
    clock = clock + TICK
    engine:Tick(clock)
    poller:Tick(clock)
  end

  if ip == nil or ip == "" or ip == "0.0.0.0" then
    Controls.Status.Value = 2
    Controls.Status.String = "Set the IP Address property"
    return
  end

  Controls.Status.Value = 4
  Controls.Status.String = "Disconnected"
  engine:Start(clock)
  ticker:Start(TICK)
end
