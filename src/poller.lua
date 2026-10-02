-- Conservative polling scheduler.
--
-- Intervals (seconds) depend on the last known power state:
--   Unknown : only power is polled, until a power reply arrives
--   Standby : only power, slowly
--   On      : power, input, shutter, freeze, diagnostics
local Protocol = require("protocol")

local Poller = {}
Poller.__index = Poller

Poller.Schedule = {
  { Key = "power", Interval = { On = 1, Standby = 10, Unknown = 1 } },
  { Key = "input", Interval = { On = 2 } },
  { Key = "shutter", Interval = { On = 2 } },
  { Key = "freeze", Interval = { On = 3 } },
  { Key = "diag1", Interval = { On = 5 } },
  { Key = "diag2", Interval = { On = 5 } },
}

-- handlers[key](ok, value, raw) receives each poll result.
function Poller.New(engine, handlers)
  local self = setmetatable({}, Poller)
  self.engine = engine
  self.handlers = handlers
  self.last = {}
  self.power = nil
  self.now = 0
  return self
end

function Poller:_poll(item)
  self.last[item.Key] = self.now
  local handler = self.handlers[item.Key]
  self.engine:Query(item.Key, Protocol.Queries[item.Key], function(ok, value, raw)
    if handler then handler(ok, value, raw) end
  end)
end

function Poller:Tick(now)
  self.now = now
  if not self.engine:IsReady() then return end
  local state = self.power or "Unknown"
  for _, item in ipairs(Poller.Schedule) do
    local interval = item.Interval[state]
    if interval then
      local last = self.last[item.Key]
      if last == nil or now - last >= interval then
        self:_poll(item)
      end
    end
  end
end

-- Poll one item as soon as possible (for example after sending a command).
function Poller:PollNow(key)
  if not self.engine:IsReady() then return end
  for _, item in ipairs(Poller.Schedule) do
    if item.Key == key then
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

-- Forget all timing and power state (call on disconnect).
function Poller:Reset()
  self.last = {}
  self.power = nil
end

return Poller
