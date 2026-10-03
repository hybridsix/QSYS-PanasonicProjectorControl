-- =============================================================
-- info.lua -- Panasonic Projector Control
--
-- Plugin identity block. Embedded in the .qplug file and read by
-- Q-SYS Designer when loading the plugin.
--
-- Version is injected from package.json by build.js. Do not edit
-- it here.
--
-- Id is a stable GUID that uniquely identifies this plugin.
-- Do not change it after the plugin has been deployed, or
-- existing designs will lose the reference and need to be
-- manually reconnected.
-- =============================================================

PluginInfo = {
  Name = "Displays~Projectors~Panasonic~Projector Control",
  Version = "@VERSION@",
  BuildVersion = "@VERSION@.0",
  Id = "eb89b070-8e63-4d3d-a30a-2234f9da3fc9",
  Author = "Michael King",
  Description = "Control Panasonic PT-REQ80 and PT-RQ35K2 projectors from Q-SYS: power, input, shutter, freeze, menu and lens control over Panasonic LAN command control (TCP), with live status feedback.",
}
