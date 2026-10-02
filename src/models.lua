-- Model registry plus data shared by design-time and runtime code.
local Models = {
  ById = {},
  Ids = {},
  Default = "PT-REQ80",
}

for _, id in ipairs({ "PT-REQ80", "PT-RQ35K2" }) do
  Models.ById[id] = require("models." .. id)
  Models.Ids[#Models.Ids + 1] = id
end

function Models.Get(id)
  return Models.ById[id] or Models.ById[Models.Default]
end

-- Boolean plugin property that enables an optional input for a model.
function Models.OptionalPropertyName(opt)
  return "Show " .. opt.Label
end

-- Momentary lens controls: control name, model Lens key, direction,
-- feature flag that gates the control.
--
-- UNVERIFIED: Panasonic's incremental values are documented as "+" / "-" per
-- function. Focus and Zoom map directly to Plus / Minus. For shift, the
-- assumption is H+ = right and V+ = up. Confirm on a real projector and flip
-- the direction here if the lens moves the opposite way.
Models.LensControls = {
  { Name = "LensShiftUp", Function = "VerticalShift", Direction = 1, Feature = "LensShift" },
  { Name = "LensShiftDown", Function = "VerticalShift", Direction = -1, Feature = "LensShift" },
  { Name = "LensShiftLeft", Function = "HorizontalShift", Direction = -1, Feature = "LensShift" },
  { Name = "LensShiftRight", Function = "HorizontalShift", Direction = 1, Feature = "LensShift" },
  { Name = "FocusPlus", Function = "Focus", Direction = 1, Feature = "Focus" },
  { Name = "FocusMinus", Function = "Focus", Direction = -1, Feature = "Focus" },
  { Name = "ZoomPlus", Function = "Zoom", Direction = 1, Feature = "Zoom" },
  { Name = "ZoomMinus", Function = "Zoom", Direction = -1, Feature = "Zoom" },
}

return Models
