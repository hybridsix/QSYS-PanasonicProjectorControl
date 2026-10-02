# Panasonic Projector Control - Q-SYS Plugin

**Author:** Michael King / Hybridsix  **Version:** 0.1.0  **Platform:** Q-SYS Designer 10.5, Panasonic PT-REQ80 / PT-RQ35K2

A Q-SYS plugin that gives your Core direct control over a Panasonic PT-REQ80 or PT-RQ35K2 projector on the local network - power, input, shutter, freeze, menu, lens, and live status, all from the schematic.

## Features

- Power on / off with live power state feedback
- Input selection (model-specific list; optional slot-board and SDM inputs can be enabled in Properties)
- Shutter (image mute) and Freeze
- Menu navigation: Menu, Up, Down, Left, Right, Enter, Default
- Lens shift, focus and zoom (model-dependent), with a configurable lens speed
- Auto Setup (PT-RQ35K2 only)
- Live status polling - connection, power, input, shutter and freeze are kept in sync with the projector
- Automatic reconnect if the projector or network drops
- Raw `ERRS1` / `ERRS2` diagnostic readout for commissioning

## How it works

```
Q-SYS Core  ---- TCP :1024 ---->  Projector
            <--- replies, state --
```

The plugin opens one TCP connection to the projector and talks Panasonic's LAN command protocol. All control handlers only queue a request; a single engine sends one request at a time, parses the reply, and updates the controls from what the projector actually reports. Polling is conservative and driven by power state.

## Requirements

Q-SYS Core side:

- Q-SYS Designer 10.5
- Core must be able to reach the projector on TCP port 1024 (same LAN or routed)

Projector side:

- Panasonic PT-REQ80 or PT-RQ35K2
- LAN control enabled on the projector
- Command protect (authentication) disabled - see **Not in version 1**

## Installation

### 1. Q-SYS Designer setup

1. Download [PanasonicProjectorControl.qplug](https://github.com/hybridsix/QSYS-PanasonicProjectorControl/releases/latest/download/PanasonicProjectorControl.qplug) from the latest [release](https://github.com/hybridsix/QSYS-PanasonicProjectorControl/releases/latest)
2. Copy it to: `%USERPROFILE%\Documents\QSC\Q-Sys Designer\Plugins\QSYS Panasonic Projector Control\`
3. Restart Q-SYS Designer (or use Manage Plugins to reload)
4. Drag Hybridsix Software -> Panasonic Projector Control from the component library onto your schematic
5. Open the plugin's Properties panel and fill in:

| Property | Description |
|---|---|
| Model | PT-REQ80 or PT-RQ35K2 |
| IP Address | The projector's IP address |
| Port | Must match the projector's command port (default 1024) |
| Lens Speed | Slow / Normal / Fast |
| Optional inputs | One switch per optional input for the selected model |
| Debug Print | None / Tx/Rx / All - use Tx/Rx when commissioning |

## Controls and pins

All pins are available in the Control Pins section of the Properties panel.

| Control | Direction | Type | Description |
|---|---|---|---|
| Power On / Power Off | Input | Button | Power the projector on / off |
| Power State | Output | LED | true when the projector is on |
| Power State Text | Output | Text | Current power state |
| Input | Both | Combo box | Select / report the active input |
| Shutter (Image Mute) | Both | Toggle button | true = shutter engaged, image blanked (`OSH:1`); false = image visible (`OSH:0`) |
| Freeze | Both | Toggle button | Freeze the image |
| Menu, Up, Down, Left, Right, Enter, Default | Input | Button | Projector menu navigation |
| Auto Setup | Input | Button | PT-RQ35K2 only |
| Lens Shift, Focus, Zoom | Input | Momentary button | Lens control (model-dependent) |
| Connected | Output | LED | true when the projector is reachable |
| Status | Output | Status | Connection state |
| Model, IP Address | Output | Text | What this block is talking to |
| Detail, ERRS1, ERRS2, Last Reply | Output | Text | Diagnostics |

## Troubleshooting

| Problem | Fix |
|---|---|
| Status never reaches Connected | Ping the projector from another device. Check the IP Address and Port properties. Confirm LAN control is enabled on the projector. |
| Status shows a command-protect message | Command protect (authentication) is enabled on the projector. Disable it; authentication is not supported yet. |
| Commands are ignored or time out | Set Debug Print to Tx/Rx and compare the traffic with the projector's documentation. |
| Lens moves the wrong way | Direction is not yet verified on hardware - see **Not yet verified on a real projector**. |

## Build from source

```powershell
npm install        # once; installs the Lua test VM (fengari)
npm run build      # writes dist/PanasonicProjectorControl.qplug
npm test           # builds, then runs the Lua tests
```

## File reference

| File | Purpose |
|---|---|
| `src/info.lua` | `PluginInfo` (version injected from `package.json`) |
| `src/plugin.lua` | Design-time: properties, controls, layout, pages |
| `src/runtime.lua` | Runtime wiring between controls, engine and socket |
| `src/engine.lua` | Connection state machine, serialized queue, timeouts, reconnect |
| `src/poller.lua` | Conservative polling schedule driven by power state |
| `src/protocol.lua` | Framing, command builders, reply parsers |
| `src/models/*.lua` | Per-model inputs, lens function codes, features |
| `build.js` | Bundles `src/` into one `.qplug` |
| `test/` | Lua tests, run under fengari (no Lua install needed) |

Q-SYS plugins are a single Lua file, so `build.js` wraps each module and provides a local `require`.

## Design rules

- One shared engine; model differences live in `src/models/`.
- Control handlers only enqueue. One request is in flight at a time.
- Feedback is parsed, never assumed. Non-idempotent commands are not retried.
- Only commands from the supplied Panasonic model references are used.

## Not yet verified on a real projector

Settle these in the lab; each is isolated so the fix is local.

1. **LAN framing** (`src/protocol.lua`, `Protocol.Framing`): `00` prefix and CR terminator are assumed. Set **Debug Print** to `Tx/Rx` to see the traffic.
2. **Greeting and error replies**: `NTCONTROL <mode>` and the `ER...` patterns are assumed (`Protocol.ParseGreeting`, `Protocol.ErrorCode`).
3. **Lens direction** (`Models.LensControls` in `src/models.lua`): shift up/right are assumed to be `+`. Flip `Direction` if reversed.
4. **Lens repeat** (`LENS_REPEAT` in `src/runtime.lua`): whether a move command is one step or continuous while repeated.
5. **Slot-input replies** to `QIN`: matched exactly, then by the part after the comma. Unrecognized replies are shown raw.
6. **Socket reconnect**: the plugin sets `ReconnectTimeout = 0` and reconnects from the engine. Confirm that disables the socket's own reconnect in Designer 10.5.
7. **Layout styles**: the `Status` indicator uses `Style = "Text"` and the input uses `ComboBox`; confirm they render correctly in Designer.

## Not in version 1

- **Command protect authentication.** The projector must have command protect disabled. If it is on, the plugin shows a clear status and retries every 30 seconds.
- **`ERRS1` / `ERRS2` decoding.** Raw replies are shown; no Warning/Fault indicator is derived until Panasonic's error tables are validated.
- Absolute lens positions, lens memory, picture modes, Active Focus Optimizer, REQ80 periphery focus, projector images/icons.

## License

MIT - see repository for details.
