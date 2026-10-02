-- Transport state machine with a serialized command queue.
--
-- The engine is transport-agnostic. It is driven by:
--   Tick(now)            called periodically (seconds, monotonic)
--   OnConnected()        socket connected
--   OnLine(text)         one received line
--   OnClosed(reason)     socket closed or errored
-- and talks to the outside through deps:
--   send(string), connect(), disconnect(), log(kind, msg), onState(state, detail)
--
-- States: Disconnected, Connecting, Greeting, Ready, AuthRequired.
-- Only one request is ever in flight. UI commands go ahead of queued polls.
local Protocol = require("protocol")

local Engine = {}
Engine.__index = Engine

Engine.Defaults = {
  ResponseTimeout = 2.0, -- seconds to wait for a reply
  GreetingTimeout = 2.0, -- seconds to wait for NTCONTROL before proceeding
  ConnectTimeout = 10.0, -- seconds to wait for the socket to connect
  MaxFailures = 3,       -- consecutive timeouts before reconnecting
  MaxQueue = 50,
  ReconnectMin = 5.0,    -- first reconnect delay; doubles up to ReconnectMax
  ReconnectMax = 30.0,
}

function Engine.New(deps, options)
  local self = setmetatable({}, Engine)
  self.deps = deps
  self.opt = {}
  for k, v in pairs(Engine.Defaults) do self.opt[k] = v end
  for k, v in pairs(options or {}) do self.opt[k] = v end
  self.state = "Disconnected"
  self.queue = {}
  self.inflight = nil
  self.failures = 0
  self.now = 0
  self.nextConnectAt = 0
  self.backoff = self.opt.ReconnectMin
  self.enabled = false
  self.session = false
  return self
end

function Engine:_log(kind, message)
  if self.deps.log then self.deps.log(kind, message) end
end

function Engine:_setState(state, detail)
  self.state = state
  self.detail = detail
  if self.deps.onState then self.deps.onState(state, detail) end
end

function Engine:IsReady()
  return self.state == "Ready"
end

function Engine:Start(now)
  self.enabled = true
  self.now = now or self.now
  self.nextConnectAt = self.now
end

function Engine:Stop()
  self.enabled = false
  if self.session then
    self.deps.disconnect()
    self:_closed("stopped")
  end
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------
function Engine:_resolve(req, ok, value, raw)
  if req.callback then req.callback(ok, value, raw) end
end

function Engine:_failAll(reason)
  local pending = {}
  if self.inflight then
    pending[#pending + 1] = self.inflight
    self.inflight = nil
  end
  for _, req in ipairs(self.queue) do pending[#pending + 1] = req end
  self.queue = {}
  for _, req in ipairs(pending) do self:_resolve(req, false, reason) end
end

function Engine:_enqueue(req)
  if self.state ~= "Ready" then
    self:_resolve(req, false, "not connected")
    return false
  end
  -- A request with a key is dropped if one with the same key is pending.
  if req.key then
    if self.inflight and self.inflight.key == req.key then return false end
    for _, queued in ipairs(self.queue) do
      if queued.key == req.key then return false end
    end
  end
  if #self.queue >= self.opt.MaxQueue then
    self:_resolve(req, false, "queue full")
    return false
  end
  if req.kind == "command" then
    -- Commands go after earlier commands but ahead of queued queries.
    local pos = 1
    while pos <= #self.queue and self.queue[pos].kind == "command" do pos = pos + 1 end
    table.insert(self.queue, pos, req)
  else
    self.queue[#self.queue + 1] = req
  end
  self:_dispatch()
  return true
end

-- spec: { line = "PON", idempotent = true }
-- callback(ok, value, raw): ok=false carries a reason string in `value`.
function Engine:Command(key, spec, callback)
  return self:_enqueue({
    key = key,
    line = spec.line,
    kind = "command",
    retries = spec.idempotent and 1 or 0,
    callback = callback,
  })
end

-- spec: { line = "QPW", parse = function(text) -> value|nil }
function Engine:Query(key, spec, callback)
  return self:_enqueue({
    key = key,
    line = spec.line,
    parse = spec.parse,
    kind = "query",
    retries = 1,
    callback = callback,
  })
end

function Engine:_dispatch()
  if self.state ~= "Ready" or self.inflight then return end
  local req = table.remove(self.queue, 1)
  if not req then return end
  req.attempts = (req.attempts or 0) + 1
  req.sentAt = self.now
  self.inflight = req
  self:_log("tx", req.line)
  self.deps.send(Protocol.Frame(req.line))
end

function Engine:_checkTimeout()
  local req = self.inflight
  if not req or self.now - req.sentAt < self.opt.ResponseTimeout then return end
  self.inflight = nil
  self.failures = self.failures + 1
  self:_log("warn", "timeout waiting for " .. req.line)
  if self.failures >= self.opt.MaxFailures then
    self:_resolve(req, false, "timeout")
    self.deps.disconnect()
    self:_closed("no response")
    return
  end
  if req.attempts <= req.retries then
    table.insert(self.queue, 1, req)
  else
    self:_resolve(req, false, "timeout")
  end
  self:_dispatch()
end

-- ---------------------------------------------------------------------------
-- Connection lifecycle
-- ---------------------------------------------------------------------------
function Engine:_closed(reason)
  if not self.session then return end
  self.session = false
  if self.state ~= "AuthRequired" then
    self:_setState("Disconnected", reason)
  end
  self:_failAll(reason)
  self.failures = 0
  self.nextConnectAt = self.now + self.backoff
  self:_log("info", string.format("reconnect in %.0fs (%s)", self.backoff, tostring(reason)))
  self.backoff = math.min(self.backoff * 2, self.opt.ReconnectMax)
end

function Engine:_ready()
  self:_setState("Ready")
  self:_dispatch()
end

function Engine:_authRequired()
  self:_log("warn", "projector requires authentication (command protect is on)")
  self.backoff = self.opt.ReconnectMax
  self:_setState("AuthRequired", "command protect enabled")
  self.deps.disconnect()
  self:_closed("auth required")
end

function Engine:OnConnected()
  self.session = true
  self.failures = 0
  self.greetingDeadline = self.now + self.opt.GreetingTimeout
  self:_setState("Greeting")
end

function Engine:OnClosed(reason)
  self:_closed(reason or "closed")
end

function Engine:Tick(now)
  self.now = now
  local state = self.state
  if state == "Disconnected" or state == "AuthRequired" then
    if self.enabled and now >= self.nextConnectAt then
      self.session = true
      self.connectDeadline = now + self.opt.ConnectTimeout
      self:_setState("Connecting")
      self.deps.connect()
    end
  elseif state == "Connecting" then
    if now >= self.connectDeadline then
      self.deps.disconnect()
      self:_closed("connect timeout")
    end
  elseif state == "Greeting" then
    if now >= self.greetingDeadline then
      self:_log("warn", "no NTCONTROL greeting; proceeding")
      self:_ready()
    end
  elseif state == "Ready" then
    self:_checkTimeout()
    self:_dispatch()
  end
end

-- ---------------------------------------------------------------------------
-- Receive path
-- ---------------------------------------------------------------------------
function Engine:OnLine(raw)
  local text = Protocol.Unframe(raw)
  if text == "" then return end
  self:_log("rx", text)

  local greeting = Protocol.ParseGreeting(text)
  if greeting then
    if self.state == "Greeting" then
      if greeting.protected then self:_authRequired() else self:_ready() end
    end
    return
  end

  local req = self.inflight
  if not req then
    self:_log("warn", "unsolicited reply: " .. text)
    return
  end
  self.inflight = nil

  -- Any reply, even an error, proves the link works.
  self.failures = 0
  self.backoff = self.opt.ReconnectMin

  local errorCode = Protocol.ErrorCode(text)
  if errorCode then
    self:_resolve(req, false, errorCode, text)
  elseif req.parse then
    local value = req.parse(text)
    if value == nil then
      self:_resolve(req, false, "unexpected reply", text)
    else
      self:_resolve(req, true, value, text)
    end
  else
    self:_resolve(req, true, nil, text)
  end
  self:_dispatch()
end

return Engine
