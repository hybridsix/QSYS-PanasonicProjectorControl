-- PT-REQ80 (PT-REQ15 / REQ12 family command set).
-- Source: starter model package Panasonic_PT-REQ80_QSYS_Reference.
-- Inputs and lens function codes come from that package; nothing here is
-- invented. Optional SDM inputs are only offered when enabled in properties.
return {
  Id = "PT-REQ80",
  Name = "Panasonic PT-REQ80",
  Family = "REQ15/REQ12",
  DefaultPort = 1024,

  Inputs = {
    { Label = "HDMI 1", Code = "HD1" },
    { Label = "HDMI 2", Code = "HD2" },
    { Label = "DisplayPort", Code = "DP1" },
  },

  OptionalInputs = {
    { Label = "SDM 12G-SDI", Code = "DM1,SD1" },
    { Label = "SDM DIGITAL LINK", Code = "DM1,DL1" },
    { Label = "SDM PressIT", Code = "DM1,WP1" },
    { Label = "SDM Third-Party", Code = "DM1,TP1" },
    { Label = "SDM Optical 1", Code = "DM1,OP1" },
    { Label = "SDM Optical 2", Code = "DM1,OP2" },
  },

  -- Incremental lens function codes: VXX:<code>=<value>
  Lens = {
    HorizontalShift = "LNSI2",
    VerticalShift = "LNSI3",
    Focus = "LNSI4",
    Zoom = "LNSI5",
  },

  Features = {
    LensShift = true,
    Focus = true,
    Zoom = true,
    SelfDiagnosis = true,
    -- Status sensors documented for the REQ80 family only.
    Light2Hours = true, -- QVX:LRTS3=01
    TempOptics = true,  -- QTM:2
    TempLight1 = true,  -- QTM:11
    TempLight2 = true,  -- QTM:12
  },
}
