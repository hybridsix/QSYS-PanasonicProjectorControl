-- Panasonic command protocol: framing, command builders, query parsers.
--
-- Command codes come from the supplied model reference packages. Do not add
-- commands here unless they are verified against Panasonic documentation or a
-- real projector.
local Protocol = {}

-- ---------------------------------------------------------------------------
-- FRAMING - UNVERIFIED
--
-- The model packages list command strings (PON, QPW, ...) but not the LAN
-- wire format. The values below are the assumed non-protect-mode format:
-- "00" prefix, CR terminator. Everything that touches the wire goes through
-- Frame / Unframe / ParseGreeting / ErrorCode, so correcting this after a lab
-- capture is a change to this section only.
-- ---------------------------------------------------------------------------
Protocol.Framing = {
  Prefix = "00",
  Terminator = "\r",
}

function Protocol.Frame(command)
  return Protocol.Framing.Prefix .. command .. Protocol.Framing.Terminator
end

-- Strip line terminators from a received line.
function Protocol.Unframe(line)
  return (tostring(line):gsub("[\r\n]+$", ""))
end

-- The projector greets each connection with "NTCONTROL <mode> ...".
-- Mode 0 is assumed to mean command protect is off; anything else means
-- authentication is required (not implemented in version 1).
function Protocol.ParseGreeting(text)
  local mode = text:match("^NTCONTROL%s+(%S+)")
  if not mode then return nil end
  return { protected = (mode ~= "0") }
end

-- Error replies (patterns assumed, confirm against a real projector). Note
-- that diagnostic replies begin "ERRS1=" and must not match.
function Protocol.ErrorCode(text)
  local code = text:match("^ER(%d%d%d)$")
  if code then return "ER" .. code end
  code = text:match("^ERR(%w)$")
  if code then return "ERR" .. code end
  return nil
end

-- ---------------------------------------------------------------------------
-- Commands (no query feedback). `idempotent` means a retry after a timeout
-- cannot double-trigger anything.
-- ---------------------------------------------------------------------------
Protocol.Commands = {
  PowerOn = { line = "PON", idempotent = true },
  PowerOff = { line = "POF", idempotent = true },
  Menu = { line = "OMN" },
  Enter = { line = "OEN" },
  Up = { line = "OCU" },
  Down = { line = "OCD" },
  Left = { line = "OCL" },
  Right = { line = "OCR" },
  Default = { line = "OST" },
  AutoSetup = { line = "OAS" }, -- PT-RQ35K2 only; gated by Features.AutoSetup
}

-- OSH:1 engages the shutter (image blanked); OSH:0 opens it (image visible).
-- The Q-SYS "Shutter" control follows the same sense: true = image muted.
function Protocol.ShutterCommand(on)
  return { line = "OSH:" .. (on and "1" or "0"), idempotent = true }
end

function Protocol.FreezeCommand(on)
  return { line = "OFZ:" .. (on and "1" or "0"), idempotent = true }
end

function Protocol.InputCommand(code)
  return { line = "IIS:" .. code, idempotent = true }
end

-- Incremental lens movement: VXX:<function>=<signed value>.
-- Slow+ 00000, Slow- 00001, Normal+ 00100, Normal- 00101, Fast+ 00200,
-- Fast- 00201.
Protocol.LensSpeed = { Slow = 0, Normal = 100, Fast = 200 }

function Protocol.LensCommand(functionCode, direction, speed)
  local base = Protocol.LensSpeed[speed] or Protocol.LensSpeed.Normal
  local value = base + (direction < 0 and 1 or 0)
  return { line = string.format("VXX:%s=+%05d", functionCode, value) }
end

-- ---------------------------------------------------------------------------
-- Queries. parse(text) returns the decoded value, or nil if the reply is not
-- in the documented format.
-- ---------------------------------------------------------------------------
local function parseFlag(text)
  if text == "1" then return true end
  if text == "0" then return false end
  return nil
end

local function parseDiagnostic(tag)
  return function(text)
    return text:match("^" .. tag .. "=(.*)$")
  end
end

Protocol.Queries = {
  power = {
    line = "QPW",
    parse = function(text)
      if text == "001" then return "On" end
      if text == "000" then return "Standby" end
      return nil
    end,
  },
  input = {
    line = "QIN",
    parse = function(text)
      if text:match("^[%w,:]+$") then return text end
      return nil
    end,
  },
  shutter = { line = "QSH", parse = parseFlag },
  freeze = { line = "QFZ", parse = parseFlag },
  diag1 = { line = "QVX:ERRS1", parse = parseDiagnostic("ERRS1") },
  diag2 = { line = "QVX:ERRS2", parse = parseDiagnostic("ERRS2") },
}

return Protocol
