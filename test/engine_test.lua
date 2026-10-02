local T = require("helpers")
local Engine = require("engine")

-- Builds an engine with recording dependencies.
local function setup(options)
  local ctx = { sent = {}, connects = 0, disconnects = 0, states = {} }
  ctx.engine = Engine.New({
    send = function(data) ctx.sent[#ctx.sent + 1] = data end,
    connect = function() ctx.connects = ctx.connects + 1 end,
    disconnect = function() ctx.disconnects = ctx.disconnects + 1 end,
    onState = function(state, detail) ctx.states[#ctx.states + 1] = state .. (detail and (":" .. detail) or "") end,
  }, options)
  return ctx
end

-- Drives the engine to Ready at time 0.
local function ready(options)
  local ctx = setup(options)
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 0\r")
  return ctx
end

local power = { line = "QPW", parse = function(t) if t == "001" then return "On" end end }
local freeze = { line = "QFZ", parse = function(t) if t == "0" then return false end end }

T.test("connect, greeting, ready", function()
  local ctx = setup()
  ctx.engine:Start(0)
  T.eq(ctx.engine.state, "Disconnected")
  ctx.engine:Tick(0)
  T.eq(ctx.connects, 1)
  T.eq(ctx.engine.state, "Connecting")
  ctx.engine:OnConnected()
  T.eq(ctx.engine.state, "Greeting")
  ctx.engine:OnLine("NTCONTROL 0\r")
  T.eq(ctx.engine.state, "Ready")
end)

T.test("proceeds to Ready if the greeting never arrives", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:Tick(1.9)
  T.eq(ctx.engine.state, "Greeting")
  ctx.engine:Tick(2.0)
  T.eq(ctx.engine.state, "Ready")
end)

T.test("requests are rejected when not Ready", function()
  local ctx = setup()
  local result
  local queued = ctx.engine:Query("power", power, function(ok, reason) result = { ok, reason } end)
  T.falsy(queued)
  T.eq(result[1], false)
  T.eq(result[2], "not connected")
  T.eq(#ctx.sent, 0)
end)

T.test("only one request is in flight; the next goes out on the reply", function()
  local ctx = ready()
  local results = {}
  ctx.engine:Query("power", power, function(ok, v) results[#results + 1] = "power:" .. tostring(v) end)
  ctx.engine:Query("freeze", freeze, function(ok, v) results[#results + 1] = "freeze:" .. tostring(v) end)
  T.eq(#ctx.sent, 1)
  T.eq(ctx.sent[1], "00QPW\r")
  ctx.engine:OnLine("001\r")
  T.eq(#ctx.sent, 2)
  T.eq(ctx.sent[2], "00QFZ\r")
  ctx.engine:OnLine("0\r")
  T.eq(results[1], "power:On")
  T.eq(results[2], "freeze:false")
end)

T.test("commands jump ahead of queued queries but keep their own order", function()
  local ctx = ready()
  ctx.engine:Query("power", power)
  ctx.engine:Query("freeze", freeze)
  ctx.engine:Command(nil, { line = "OMN" })
  ctx.engine:Command(nil, { line = "OEN" })
  T.eq(ctx.sent[1], "00QPW\r")
  ctx.engine:OnLine("001")
  T.eq(ctx.sent[2], "00OMN\r")
  ctx.engine:OnLine("00OMN")
  T.eq(ctx.sent[3], "00OEN\r")
  ctx.engine:OnLine("00OEN")
  T.eq(ctx.sent[4], "00QFZ\r")
end)

T.test("a keyed request is dropped while one with the same key is pending", function()
  local ctx = ready()
  T.truthy(ctx.engine:Query("power", power))
  T.falsy(ctx.engine:Query("power", power))
  ctx.engine:Query("freeze", freeze)
  T.falsy(ctx.engine:Query("freeze", freeze))
  T.eq(#ctx.sent, 1)
end)

T.test("a reply that does not parse fails the request but not the link", function()
  local ctx = ready()
  local got
  ctx.engine:Query("power", power, function(ok, value, raw) got = { ok, value, raw } end)
  ctx.engine:OnLine("garbage")
  T.eq(got[1], false)
  T.eq(got[2], "unexpected reply")
  T.eq(got[3], "garbage")
  T.eq(ctx.engine.state, "Ready")
end)

T.test("projector error replies fail the request with the code", function()
  local ctx = ready()
  local got
  ctx.engine:Command(nil, { line = "OMN" }, function(ok, value) got = { ok, value } end)
  ctx.engine:OnLine("ER403")
  T.eq(got[1], false)
  T.eq(got[2], "ER403")
  T.eq(ctx.engine.failures, 0)
end)

T.test("a command with no parser succeeds on any non-error reply", function()
  local ctx = ready()
  local got
  ctx.engine:Command(nil, { line = "OMN" }, function(ok) got = ok end)
  ctx.engine:OnLine("00OMN")
  T.eq(got, true)
end)

T.test("a timed-out query is retried once, then fails", function()
  local ctx = ready()
  local got
  ctx.engine:Query("power", power, function(ok, reason) got = { ok, reason } end)
  T.eq(#ctx.sent, 1)
  ctx.engine:Tick(1.9)
  T.eq(#ctx.sent, 1)
  ctx.engine:Tick(2.0)
  T.eq(#ctx.sent, 2)
  T.eq(got, nil)
  ctx.engine:Tick(4.0)
  T.eq(got[1], false)
  T.eq(got[2], "timeout")
  T.eq(ctx.engine.state, "Ready")
end)

T.test("a timed-out non-idempotent command is not resent", function()
  local ctx = ready()
  local got
  ctx.engine:Command(nil, { line = "OMN" }, function(ok, reason) got = { ok, reason } end)
  ctx.engine:Tick(2.0)
  T.eq(#ctx.sent, 1)
  T.eq(got[2], "timeout")
end)

T.test("an idempotent command is retried once", function()
  local ctx = ready()
  ctx.engine:Command(nil, { line = "PON", idempotent = true })
  ctx.engine:Tick(2.0)
  T.eq(#ctx.sent, 2)
  T.eq(ctx.sent[2], "00PON\r")
end)

T.test("repeated timeouts drop the connection and reconnect after the delay", function()
  local ctx = ready()
  local failures = {}
  local function cb(ok, reason) failures[#failures + 1] = reason end
  ctx.engine:Query("power", power, cb)   -- timeout 1 at t=2, retried
  ctx.engine:Tick(2.0)
  ctx.engine:Tick(4.0)                   -- timeout 2, fails
  ctx.engine:Query("freeze", freeze, cb)
  ctx.engine:Tick(6.0)                   -- timeout 3 -> drop
  T.eq(ctx.disconnects, 1)
  T.eq(ctx.engine.state, "Disconnected")
  T.eq(ctx.states[#ctx.states], "Disconnected:no response")
  ctx.engine:Tick(10.9)
  T.eq(ctx.connects, 1, "must wait the reconnect delay")
  ctx.engine:Tick(11.0)
  T.eq(ctx.connects, 2)
  T.eq(ctx.engine.state, "Connecting")
end)

T.test("reconnect delay doubles up to the cap and resets after a reply", function()
  local ctx = setup()
  ctx.engine:Start(0)
  local delays, now = {}, 0
  for _ = 1, 6 do
    ctx.engine:Tick(now)
    T.eq(ctx.engine.state, "Connecting")
    ctx.engine:OnClosed("socket error")
    delays[#delays + 1] = ctx.engine.nextConnectAt - now
    now = ctx.engine.nextConnectAt
  end
  T.eq(delays[1], 5)
  T.eq(delays[2], 10)
  T.eq(delays[3], 20)
  T.eq(delays[4], 30)
  T.eq(delays[5], 30)
  T.eq(delays[6], 30)

  ctx.engine:Tick(now)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 0")
  ctx.engine:Query("power", power)
  ctx.engine:OnLine("001")
  local t = now + 1
  ctx.engine:Tick(t)
  ctx.engine:OnClosed("closed")
  T.eq(ctx.engine.nextConnectAt - t, 5)
end)

T.test("a connect that never completes is abandoned", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:Tick(9.9)
  T.eq(ctx.engine.state, "Connecting")
  ctx.engine:Tick(10.0)
  T.eq(ctx.engine.state, "Disconnected")
  T.eq(ctx.disconnects, 1)
  T.eq(ctx.engine.nextConnectAt, 15)
end)

T.test("a socket close fails the in-flight and queued requests", function()
  local ctx = ready()
  local reasons = {}
  local function cb(ok, reason) reasons[#reasons + 1] = tostring(ok) .. ":" .. tostring(reason) end
  ctx.engine:Query("power", power, cb)
  ctx.engine:Query("freeze", freeze, cb)
  ctx.engine:OnClosed("closed")
  T.eq(#reasons, 2)
  T.eq(reasons[1], "false:closed")
  T.eq(ctx.engine.state, "Disconnected")
end)

T.test("a duplicate close event does not push the reconnect out further", function()
  local ctx = ready()
  ctx.engine:Tick(1)
  ctx.engine:OnClosed("closed")
  local first = ctx.engine.nextConnectAt
  ctx.engine:OnClosed("closed")
  T.eq(ctx.engine.nextConnectAt, first)
end)

T.test("command protect puts the engine in AuthRequired and backs off", function()
  local ctx = setup()
  ctx.engine:Start(0)
  ctx.engine:Tick(0)
  ctx.engine:OnConnected()
  ctx.engine:OnLine("NTCONTROL 1 a1b2c3d4")
  T.eq(ctx.engine.state, "AuthRequired")
  T.eq(ctx.disconnects, 1)
  ctx.engine:Tick(29.9)
  T.eq(ctx.connects, 1)
  ctx.engine:Tick(30.0)
  T.eq(ctx.connects, 2)
end)

T.test("Stop disconnects and does not reconnect", function()
  local ctx = ready()
  ctx.engine:Stop()
  T.eq(ctx.disconnects, 1)
  ctx.engine:Tick(100)
  T.eq(ctx.connects, 1)
end)

T.test("unsolicited replies are ignored", function()
  local ctx = ready()
  ctx.engine:OnLine("001")
  T.eq(ctx.engine.state, "Ready")
  T.eq(#ctx.sent, 0)
end)

T.test("the queue is bounded", function()
  local ctx = ready({ MaxQueue = 2 })
  local full
  ctx.engine:Command(nil, { line = "A" })               -- in flight
  ctx.engine:Command(nil, { line = "B" })
  ctx.engine:Command(nil, { line = "C" })
  ctx.engine:Command(nil, { line = "D" }, function(ok, reason) full = reason end)
  T.eq(full, "queue full")
end)

return T.finish()
