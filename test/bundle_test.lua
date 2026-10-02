local T = require("helpers")

local BUNDLE_PATH = "dist/PanasonicProjectorControl.qplug"

local function loadBundle()
  local source = __read(BUNDLE_PATH)
  T.truthy(source, "bundle not built")
  local fn, err = load(source, "@bundle")
  if not fn then error(err, 0) end
  fn()
end

-- ---------------------------------------------------------------------------
-- Design time (Controls is nil)
-- ---------------------------------------------------------------------------
loadBundle()

local function propsFromDefaults(overrides)
  local props = {}
  for _, p in ipairs(GetProperties()) do props[p.Name] = { Value = p.Value } end
  for name, value in pairs(overrides or {}) do props[name].Value = value end
  return props
end

T.test("PluginInfo is complete", function()
  T.truthy(PluginInfo.Name:find("Panasonic", 1, true))
  T.truthy(PluginInfo.Id:match("^%x+%-%x+%-%x+%-%x+%-%x+$"))
  T.truthy(PluginInfo.Version:match("^%d+%.%d+%.%d+$"), "version placeholder not replaced")
end)

T.test("property names are unique and defaults are valid", function()
  local seen = {}
  for _, p in ipairs(GetProperties()) do
    T.falsy(seen[p.Name], "duplicate property " .. p.Name)
    seen[p.Name] = true
    if p.Type == "enum" then
      local found = false
      for _, c in ipairs(p.Choices) do if c == p.Value then found = true end end
      T.truthy(found, p.Name .. " default is not a choice")
    end
  end
  T.truthy(seen["Model"] and seen["IP Address"] and seen["Port"] and seen["Lens Speed"] and seen["Debug Print"])
  T.truthy(seen["Normal Poll Interval (s)"] and seen["High Poll Interval (s)"] and seen["High Poll Timeout (s)"])
end)

T.test("RectifyProperties hides optional inputs of the other model", function()
  local props = propsFromDefaults()
  props["Model"].Value = "PT-REQ80"
  RectifyProperties(props)
  T.eq(props["Show SDM 12G-SDI"].IsHidden, false)
  T.eq(props["Show Slot 1 HDMI 1"].IsHidden, true)
  props["Model"].Value = "PT-RQ35K2"
  RectifyProperties(props)
  T.eq(props["Show SDM 12G-SDI"].IsHidden, true)
  T.eq(props["Show Slot 1 HDMI 1"].IsHidden, false)
end)

for _, model in ipairs({ "PT-REQ80", "PT-RQ35K2" }) do
  T.test(model .. ": every laid-out control is defined, with no duplicates", function()
    local props = propsFromDefaults({ Model = model })
    local defined = {}
    for _, c in ipairs(GetControls(props)) do
      T.falsy(defined[c.Name], "duplicate control " .. c.Name)
      defined[c.Name] = true
    end
    local layout, graphics = GetControlLayout(props)
    for name in pairs(layout) do
      T.truthy(defined[name], "layout has undefined control " .. name)
    end
    for name in pairs(defined) do
      T.truthy(layout[name], "control missing from layout: " .. name)
    end
    T.truthy(#graphics > 0)
    T.eq(#GetPages(props), 1)
    T.truthy(GetPrettyName(props):find(model, 1, true))
  end)
end

T.test("Auto Setup exists only on the PT-RQ35K2", function()
  local function names(model)
    local set = {}
    for _, c in ipairs(GetControls(propsFromDefaults({ Model = model }))) do set[c.Name] = true end
    return set
  end
  T.truthy(names("PT-RQ35K2").AutoSetup)
  T.falsy(names("PT-REQ80").AutoSetup)
end)

-- ---------------------------------------------------------------------------
-- Runtime, against a mocked Q-SYS environment
-- ---------------------------------------------------------------------------
local mocks = {}

local function installMocks(overrides)
  mocks.printed, mocks.timers, mocks.logs, mocks.socket = {}, {}, {}, nil

  Properties = propsFromDefaults(overrides)

  Controls = setmetatable({}, {
    __index = function(t, name)
      -- Like Q-SYS, assigning a new Boolean/String/Value fires EventHandler,
      -- including when the plugin itself does the assigning.
      local raw = { Name = name, Boolean = false, String = "", Value = 0, Choices = {} }
      local control = setmetatable({}, {
        __index = raw,
        __newindex = function(self, key, value)
          local old = raw[key]
          raw[key] = value
          local watched = key == "Boolean" or key == "String" or key == "Value"
          if watched and old ~= value and raw.EventHandler then raw.EventHandler(self) end
        end,
      })
      rawset(t, name, control)
      return control
    end,
  })

  TcpSocket = {
    Events = { Connected = "Connected", Reconnect = "Reconnect", Data = "Data", Closed = "Closed", Error = "Error", Timeout = "Timeout" },
    EOL = { Custom = "Custom" },
    New = function()
      local s = { written = {}, lines = {}, connectCalls = 0, disconnectCalls = 0 }
      function s:Connect(ip, port) self.connectCalls = self.connectCalls + 1; self.ip, self.port = ip, port end
      function s:Disconnect() self.disconnectCalls = self.disconnectCalls + 1 end
      function s:Write(data) self.written[#self.written + 1] = data end
      function s:ReadLine() return table.remove(self.lines, 1) end
      mocks.socket = s
      return s
    end,
  }

  Timer = {
    New = function()
      local t = { running = false }
      function t:Start(interval) self.running, self.interval = true, interval end
      function t:Stop() self.running = false end
      mocks.timers[#mocks.timers + 1] = t
      return t
    end,
  }

  Log = {
    Message = function(m) mocks.logs[#mocks.logs + 1] = m end,
    Error = function(m) mocks.logs[#mocks.logs + 1] = "ERROR " .. m end,
  }

  mocks.realPrint = mocks.realPrint or print
  print = function(...) mocks.printed[#mocks.printed + 1] = table.concat({ ... }, " ") end

  loadBundle()
end

local function removeMocks()
  Controls, Properties, TcpSocket, Timer, Log = nil, nil, nil, nil, nil
  print = mocks.realPrint
end

local function mainTimer()
  for _, t in ipairs(mocks.timers) do
    if t.interval == 0.1 then return t end
  end
end

local clockTicks = 0
local function tick(n)
  for _ = 1, n or 1 do
    clockTicks = clockTicks + 1
    mainTimer().EventHandler()
  end
end

local function feed(...)
  local sock = mocks.socket
  for _, line in ipairs({ ... }) do sock.lines[#sock.lines + 1] = line end
  sock.EventHandler(sock, TcpSocket.Events.Data)
end

local function lastWritten()
  local w = mocks.socket.written
  return w[#w]
end

-- Reaches the Ready state and answers the first power poll with the given reply.
local function connect(powerReply)
  tick(1)
  local sock = mocks.socket
  T.eq(sock.connectCalls, 1)
  sock.EventHandler(sock, TcpSocket.Events.Connected)
  feed("NTCONTROL 0")
  T.eq(Controls.Status.String, "OK")
  tick(1)
  T.eq(lastWritten(), "00QPW\r")
  feed(powerReply)
end

local ok, runtimeErr = pcall(function()

  T.test("runtime start-up populates static controls and connects to the configured address", function()
    clockTicks = 0
    installMocks({ Model = "PT-REQ80", ["IP Address"] = "10.1.2.3", Port = 1024 })
    T.eq(Controls.Model.String, "Panasonic PT-REQ80")
    T.eq(Controls.IPAddress.String, "10.1.2.3:1024")
    T.eq(Controls.Status.String, "Disconnected")
    T.eq(Controls.Input.Choices[1], "HDMI 1")
    T.eq(#Controls.Input.Choices, 3)
    T.eq(mocks.socket.ReconnectTimeout, 0)
    tick(1)
    T.eq(mocks.socket.connectCalls, 1)
    T.eq(mocks.socket.ip, "10.1.2.3")
    T.eq(mocks.socket.port, 1024)
    T.eq(Controls.Status.String, "Connecting...")
  end)

  T.test("handshake then polling, with power feedback", function()
    installMocks()
    connect("001")
    T.eq(Controls.Connected.Boolean, true)
    T.eq(Controls.PowerState.Boolean, true)
    T.eq(Controls.PowerText.String, "On")
    T.eq(Controls.LastResponse.String, "001")
    -- Power On makes the other items due on the next tick.
    tick(1)
    T.eq(lastWritten(), "00QIN\r")
    feed("HD2")
    T.eq(Controls.Input.String, "HDMI 2")
    T.eq(lastWritten(), "00QSH\r")
    feed("1")
    T.eq(Controls.Shutter.Boolean, true)
    T.eq(lastWritten(), "00QFZ\r")
    feed("0")
    T.eq(Controls.Freeze.Boolean, false)
    T.eq(lastWritten(), "00QVX:ERRS1\r")
    feed("ERRS1=00000000")
    T.eq(Controls.Diag1.String, "ERRS1=00000000")
    T.eq(lastWritten(), "00QVX:ERRS2\r")
    feed("ERRS2=00000000")
    T.eq(Controls.Diag2.String, "ERRS2=00000000")
  end)

  T.test("standby reply is shown and polling slows", function()
    installMocks()
    connect("000")
    T.eq(Controls.PowerState.Boolean, false)
    T.eq(Controls.PowerText.String, "Standby")
    local before = #mocks.socket.written
    tick(50) -- 5 seconds
    T.eq(#mocks.socket.written, before, "nothing but power is polled in standby")
  end)

  T.test("button presses are queued, not written directly", function()
    installMocks()
    connect("001")
    -- A poll (QIN) is now in flight, so the command must wait for it.
    tick(1)
    T.eq(lastWritten(), "00QIN\r")
    local before = #mocks.socket.written
    Controls.Menu.EventHandler(Controls.Menu)
    T.eq(#mocks.socket.written, before, "must wait for the in-flight reply")
    feed("HD1")
    T.eq(lastWritten(), "00OMN\r")
    feed("00OMN")
  end)

  T.test("shutter toggle sends the explicit state and re-polls", function()
    installMocks()
    connect("001")
    tick(1); feed("HD1"); feed("0"); feed("0"); feed("ERRS1=0"); feed("ERRS2=0")
    Controls.Shutter.Boolean = true
    T.eq(lastWritten(), "00OSH:1\r")
    feed("00OSH:1")
    T.eq(lastWritten(), "00QSH\r")
    feed("1")
    T.eq(Controls.Shutter.Boolean, true)
  end)

  T.test("shutter true means shutter engaged (OSH:1); false opens it (OSH:0)", function()
    installMocks()
    connect("001")
    tick(1); feed("HD1"); feed("0"); feed("0"); feed("ERRS1=0"); feed("ERRS2=0")
    Controls.Shutter.Boolean = true
    T.eq(lastWritten(), "00OSH:1\r")
    feed("00OSH:1"); feed("1")
    Controls.Shutter.Boolean = false
    T.eq(lastWritten(), "00OSH:0\r")
  end)

  T.test("Auto Setup sends OAS on the PT-RQ35K2", function()
    installMocks({ Model = "PT-RQ35K2" })
    connect("001")
    tick(1); feed("HD1"); feed("0"); feed("0"); feed("ERRS1=0"); feed("ERRS2=0")
    Controls.AutoSetup.EventHandler(Controls.AutoSetup)
    T.eq(lastWritten(), "00OAS\r")
  end)

  T.test("input selection sends the model code", function()
    installMocks()
    connect("001")
    tick(1); feed("HD1"); feed("0"); feed("0"); feed("ERRS1=0"); feed("ERRS2=0")
    Controls.Input.String = "DisplayPort"
    T.eq(lastWritten(), "00IIS:DP1\r")
  end)

  T.test("feedback updates do not echo back as commands", function()
    installMocks()
    connect("001")
    tick(1); feed("HD2"); feed("1"); feed("1"); feed("ERRS1=0"); feed("ERRS2=0")
    -- Shutter, freeze and input feedback all assigned controls whose handlers
    -- would send commands if they were not guarded.
    T.eq(Controls.Shutter.Boolean, true)
    T.eq(Controls.Freeze.Boolean, true)
    T.eq(Controls.Input.String, "HDMI 2")
    for _, written in ipairs(mocks.socket.written) do
      T.falsy(written:find("OSH", 1, true), "unexpected command: " .. written)
      T.falsy(written:find("OFZ", 1, true), "unexpected command: " .. written)
      T.falsy(written:find("IIS", 1, true), "unexpected command: " .. written)
    end
  end)

  T.test("a failed shutter command reverts the control", function()
    installMocks()
    connect("001")
    tick(1); feed("HD1"); feed("0"); feed("0"); feed("ERRS1=0"); feed("ERRS2=0")
    Controls.Shutter.Boolean = true
    feed("ER403")
    T.eq(Controls.Shutter.Boolean, false)
    T.truthy(Controls.DetailText.String:find("Shutter failed", 1, true))
  end)

  T.test("lens button sends on press and repeats while held", function()
    installMocks({ ["Lens Speed"] = "Normal" })
    connect("001")
    tick(1); feed("HD1"); feed("0"); feed("0"); feed("ERRS1=0"); feed("ERRS2=0")
    local c = Controls.FocusPlus
    c.Boolean = true
    T.eq(lastWritten(), "00VXX:LNSI4=+00100\r")
    local repeater
    for _, t in ipairs(mocks.timers) do
      if t.running and t.interval ~= 0.1 then repeater = t end
    end
    T.truthy(repeater, "repeat timer should be running")
    feed("00VXX:LNSI4=+00100")
    repeater.EventHandler()
    T.eq(#mocks.socket.written > 0, true)
    T.eq(lastWritten(), "00VXX:LNSI4=+00100\r")
    feed("00VXX:LNSI4=+00100")
    c.Boolean = false
    T.eq(repeater.running, false)
    local before = #mocks.socket.written
    repeater.EventHandler()
    T.eq(#mocks.socket.written, before, "no repeat after release")
  end)

  T.test("lens repeat does not pile up behind a slow projector", function()
    installMocks()
    connect("001")
    tick(1); feed("HD1"); feed("0"); feed("0"); feed("ERRS1=0"); feed("ERRS2=0")
    local c = Controls.ZoomMinus
    c.Boolean = true
    local sent = #mocks.socket.written
    local repeater
    for _, t in ipairs(mocks.timers) do
      if t.running and t.interval ~= 0.1 then repeater = t end
    end
    for _ = 1, 5 do repeater.EventHandler() end -- no reply yet
    T.eq(#mocks.socket.written, sent, "extra repeats are dropped while one is in flight")
    T.eq(lastWritten(), "00VXX:LNSI5=+00101\r")
  end)

  T.test("losing the connection resets feedback and reports status", function()
    installMocks()
    connect("001")
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Closed)
    T.eq(Controls.Connected.Boolean, false)
    T.eq(Controls.Status.String, "Disconnected")
    T.eq(Controls.PowerText.String, "Unknown")
    T.eq(Controls.PowerState.Boolean, false)
    -- reconnect honours the delay (5s = 50 ticks)
    tick(40)
    T.eq(sock.connectCalls, 1)
    tick(20)
    T.eq(sock.connectCalls, 2)
  end)

  T.test("silence from the projector surfaces a communication error", function()
    installMocks()
    tick(1)
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Connected)
    feed("NTCONTROL 0")
    -- QPW goes unanswered: 3 timeouts at 2s each, with a retry in between
    tick(100)
    T.eq(Controls.Status.String, "Communication error")
    T.eq(Controls.Status.Value, 2)
    T.truthy(sock.disconnectCalls >= 1)
  end)

  T.test("command protect is reported clearly", function()
    installMocks()
    tick(1)
    local sock = mocks.socket
    sock.EventHandler(sock, TcpSocket.Events.Connected)
    feed("NTCONTROL 1 a1b2c3d4")
    T.eq(Controls.Status.Value, 2)
    T.truthy(Controls.Status.String:find("authentication", 1, true))
  end)

  T.test("an unset IP address does not start connecting", function()
    installMocks({ ["IP Address"] = "" })
    T.eq(Controls.Status.String, "Set the IP Address property")
    T.eq(mainTimer(), nil)
    T.eq(mocks.socket.connectCalls, 0)
  end)

  T.test("optional inputs appear in the input list only when enabled", function()
    installMocks({ Model = "PT-RQ35K2", ["Show Slot 1 HDMI 2"] = true })
    T.eq(#Controls.Input.Choices, 3)
    T.eq(Controls.Input.Choices[3], "Slot 1 HDMI 2")
  end)

  T.test("optional input replies resolve by unique suffix", function()
    installMocks({ Model = "PT-REQ80", ["Show SDM 12G-SDI"] = true })
    connect("001")
    tick(1)
    T.eq(lastWritten(), "00QIN\r")
    feed("SD1")
    T.eq(Controls.Input.String, "SDM 12G-SDI")
  end)

  T.test("an unrecognised input reply is shown rather than hidden", function()
    installMocks()
    connect("001")
    tick(1)
    feed("ZZ9")
    T.eq(Controls.Input.String, "ZZ9")
    T.truthy(Controls.DetailText.String:find("Unrecognized input", 1, true))
  end)

  T.test("debug print is off by default and logs traffic when enabled", function()
    installMocks()
    connect("001")
    T.eq(#mocks.printed, 0)
    installMocks({ ["Debug Print"] = "Tx/Rx" })
    connect("001")
    T.truthy(#mocks.printed > 0)
  end)

end)

removeMocks()
if not ok then error(runtimeErr, 0) end

return T.finish()
