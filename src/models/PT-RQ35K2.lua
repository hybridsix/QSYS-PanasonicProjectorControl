-- PT-RQ35K2 (RQ35K2 family command set).
-- Source: starter model package Panasonic_PT-RQ35K2_QSYS_Reference.
-- Optional slot-board inputs are only offered when enabled in properties.
return {
  Id = "PT-RQ35K2",
  Name = "Panasonic PT-RQ35K2",
  Family = "RQ35K2",
  DefaultPort = 1024,

  Inputs = {
    { Label = "HDMI 1", Code = "HD1" },
    { Label = "DIGITAL LINK", Code = "DL1" },
  },

  OptionalInputs = {
    { Label = "Slot 1 HDMI 1", Code = "AU1,HD1" },
    { Label = "Slot 1 HDMI 2", Code = "AU1,HD2" },
    { Label = "Slot 1 DisplayPort 1", Code = "AU1,DP1" },
    { Label = "Slot 1 DisplayPort 2", Code = "AU1,DP2" },
    { Label = "Slot 1 12G-SDI 1", Code = "AU1,SD1" },
    { Label = "Slot 1 Optical 1", Code = "AU1,OP1" },
    { Label = "Slot 2 HDMI 3", Code = "AU2,HD3" },
    { Label = "Slot 2 HDMI 4", Code = "AU2,HD4" },
    { Label = "Slot 2 DisplayPort 3", Code = "AU2,DP3" },
    { Label = "Slot 2 DisplayPort 4", Code = "AU2,DP4" },
    { Label = "Slot 2 12G-SDI 1", Code = "AU2,SD1" },
    { Label = "Slot 2 Optical 1", Code = "AU2,OP1" },
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
    AutoSetup = true, -- OAS
    SelfDiagnosis = true,
  },
}
