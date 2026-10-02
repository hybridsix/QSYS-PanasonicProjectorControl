# Q-SYS Panasonic Projector Control

Q-SYS Designer plugin for Panasonic **PT-REQ80** and **PT-RQ35K2** projectors, using Panasonic's LAN command protocol (TCP, default port 1024). Targets Q-SYS Designer 10.5.

## Install

Download [PanasonicProjectorControl.qplug](https://github.com/hybridsix/QSYS-PanasonicProjectorControl/releases/latest/download/PanasonicProjectorControl.qplug) (latest [release](https://github.com/hybridsix/QSYS-PanasonicProjectorControl/releases/latest)) and copy it to `%USERPROFILE%\Documents\QSC\Q-SYS Designer\Plugins\`. Restart Designer. The plugin appears under **Panasonic > Projector Control**.

## Build from source

```powershell
npm install        # once; installs the Lua test VM (fengari)
npm run build      # writes dist/PanasonicProjectorControl.qplug
npm test           # builds, then runs the Lua tests
```

## Layout

| Path | Purpose |
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
