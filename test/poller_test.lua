local T = require("helpers")
local Poller = require("poller")

-- A stand-in engine that records queries instead of sending them.
local function fakeEngine()
  local e = { ready = true, queries = {} }
  function e:IsReady() return self.ready end
  function e:Query(key) self.queries[#self.queries + 1] = key; return true end
  function e:drain()
    local q = self.queries
    self.queries = {}
    return table.concat(q, ",")
  end
  return e
end

T.test("with unknown power only power is polled, every second", function()
  local e = fakeEngine()
  local p = Poller.New(e, {})
  p:Tick(0)
  T.eq(e:drain(), "power")
  p:Tick(0.9)
  T.eq(e:drain(), "")
  p:Tick(1.0)
  T.eq(e:drain(), "power")
end)

T.test("becoming On makes every item due and then paces them", function()
  local e = fakeEngine()
  local p = Poller.New(e, {})
  p:Tick(0)
  e:drain()
  p:SetPower("On")
  p:Tick(1)
  T.eq(e:drain(), "power,input,shutter,freeze,diag1,diag2")
  p:Tick(2)
  T.eq(e:drain(), "power")
  p:Tick(3)
  T.eq(e:drain(), "power,input,shutter")
  p:Tick(4)
  T.eq(e:drain(), "power,freeze")
  p:Tick(5)
  T.eq(e:drain(), "power,input,shutter")
  p:Tick(6)
  T.eq(e:drain(), "power,diag1,diag2")
end)

T.test("in standby only power is polled, every ten seconds", function()
  local e = fakeEngine()
  local p = Poller.New(e, {})
  p:SetPower("Standby")
  p:Tick(0)
  T.eq(e:drain(), "power")
  p:Tick(9.9)
  T.eq(e:drain(), "")
  p:Tick(10)
  T.eq(e:drain(), "power")
end)

T.test("nothing is polled while the engine is not ready", function()
  local e = fakeEngine()
  e.ready = false
  local p = Poller.New(e, {})
  p:Tick(0)
  p:Tick(5)
  T.eq(e:drain(), "")
  e.ready = true
  p:Tick(6)
  T.eq(e:drain(), "power")
end)

T.test("Reset forgets power state and timing", function()
  local e = fakeEngine()
  local p = Poller.New(e, {})
  p:SetPower("On")
  p:Tick(0)
  e:drain()
  p:Reset()
  p:Tick(0.1)
  T.eq(e:drain(), "power")
end)

T.test("PollNow queries one item immediately", function()
  local e = fakeEngine()
  local p = Poller.New(e, {})
  p:SetPower("On")
  p:PollNow("shutter")
  T.eq(e:drain(), "shutter")
  p:PollNow("nonexistent")
  T.eq(e:drain(), "")
end)

T.test("poll results reach the handler for that key", function()
  local got = {}
  local e = { queries = {} }
  function e:IsReady() return true end
  function e:Query(key, spec, cb) cb(true, "value-" .. key, "raw") return true end
  local p = Poller.New(e, { power = function(ok, v, raw) got[#got + 1] = v .. "/" .. raw end })
  p:Tick(0)
  T.eq(got[1], "value-power/raw")
end)

T.test("high-rate polling follows the boost window and then falls back", function()
  local e = fakeEngine()
  local p = Poller.New(e, {}, { HighRateInterval = 0.5, HighRateTimeout = 2 })
  p:SetPower("On")
  p:Boost("power", 2)
  p:Tick(0)
  T.eq(e:drain(), "power")
  p:Tick(0.5)
  T.eq(e:drain(), "power")
  p:Tick(1.5)
  T.eq(e:drain(), "power")
  p:Tick(2.0)
  T.eq(e:drain(), "power")
end)

return T.finish()
