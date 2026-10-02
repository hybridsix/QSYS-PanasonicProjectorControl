-- Conservative polling scheduler.
--
-- Intervals (seconds) depend on the last known power state:
--   Unknown : only power is polled, until a power reply arrives
--   Standby : power and the power/light lifecycle, slowly
--   On      : everything, each item at its own pace
--
-- "normal" means the configurable normal poll interval. A boosted key (see
-- Boost) is polled at the high-rate interval until it is ended or times out.
-- Items with a Feature are only polled when the model has that feature.
local Protocol = require("protocol")

local Poller = {}
Poller.__index = Poller

Poller.Schedule = {
  { Key = "power", Interval = { On = "normal", Standby = 10, Unknown = 1 } },
  { Key = "powi", Interval = { On = "normal", Standby = 10 } },
  { Key = "lightstate", Interval = { On = "normal", Standby = 10 } },
  { Key = "input", Interval = { On = "normal" } },
  { Key = "shutter", Interval = { On = "normal" } },
  { Key = "freeze", Interval = { On = "normal" } },
  { Key = "diag1", Interval = { On = 5 } },
  { Key = "diag2", Interval = { On = 5 } },
  { Key = "tempIntake", Interval = { On = 15 } },
  { Key = "tempExhaust", Interval = { On = 15 } },
  { Key = "tempOptics", Interval = { On = 15 }, Feature = "TempOptics" },
  { Key = "tempLight1", Interval = { On = 15 }, Feature = "TempLight1" },
  { Key = "tempLight2", Interval = { On = 15 }, Feature = "TempLight2" },
  { Key = "hoursProj", Interval = { On = 60 } },
  { Key = "hoursLight1", Interval = { On = 60 } },
  { Key = "hoursLight2", Interval = { On = 60 }, Feature = "Light2Hours" },
}

-- handlers[key](ok, value, raw) receives each poll result.
-- options: NormalInterval, HighRateInterval (seconds), Features (model set).
function Poller.New(engine, handlers, options)
  options = options or {}
  local self = setmetatable({}, Poller)
  self.engine = engine
  self.handlers = handlers
  self.last = {}
  self.boost = {}
  self.power = nil
  self.now = 0
  self.options = {
    NormalInterval = options.NormalInterval or 2,
    HighRateInterval = options.HighRateInterval or 1,
    Features = options.Features or {},
  }
  return self
end

function Poller:_enabled(item)
  return not item.Feature or self.options.Features[item.Feature] == true
end

function Poller:_poll(item)
  self.last[item.Key] = self.now
  local handler = self.handlers[item.Key]
  self.engine:Query(item.Key, Protocol.Queries[item.Key], function(ok, value, raw)
    if handler then handler(ok, value, raw) end
  end)
end

-- Poll `key` at the high-rate interval until EndBoost or `timeout` seconds.
function Poller:Boost(key, timeout)
  self.boost[key] = self.now + timeout
end

function Poller:EndBoost(key)
  self.boost[key] = nil
end

function Poller:IsBoosted(key)
  return self.boost[key] ~= nil
end

function Poller:Tick(now)
  self.now = now
  for key, expires in pairs(self.boost) do
    if now > expires then self.boost[key] = nil end
  end
  if not self.engine:IsReady() then return end
  local state = self.power or "Unknown"
  for _, item in ipairs(Poller.Schedule) do
    if self:_enabled(item) then
      local interval = item.Interval[state]
      if self.boost[item.Key] then interval = self.options.HighRateInterval end
      if interval == "normal" then interval = self.options.NormalInterval end
      if interval then
        local last = self.last[item.Key]
        if last == nil or now - last >= interval then
          self:_poll(item)
        end
      end
    end
  end
end

-- Poll one item as soon as possible (for example after sending a command).
function Poller:PollNow(key)
  if not self.engine:IsReady() then return end
  for _, item in ipairs(Poller.Schedule) do
    if item.Key == key and self:_enabled(item) then
      self:_poll(item)
      return
    end
  end
end

-- "On", "Standby" or nil (unknown). Becoming On makes everything due.
function Poller:SetPower(state)
  if state == self.power then return end
  self.power = state
  if state == "On" then
    for _, item in ipairs(Poller.Schedule) do
      if item.Key ~= "power" then self.last[item.Key] = nil end
    end
  end
end

-- Forget all timing, boosts and power state (call on disconnect).
function Poller:Reset()
  self.last = {}
  self.boost = {}
  self.power = nil
end

return Poller
