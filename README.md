# cloudship

PX4 SITL simulation of the experimental **Cloudship** airship — a vehicle type briefly
added to PX4 in August 2020 and dropped from mainline shortly after. Pinned to commit
`fa4818e467` and built inside the matching Ubuntu 18.04 / Gazebo Classic 9 dev
container so the era-specific build reproduces on a modern host.

## Requirements

- WSL2 with WSLg (the container forwards `/mnt/wslg` so Gazebo's GUI surfaces on Windows)
- Docker
- [just](https://github.com/casey/just)
- [zellij](https://zellij.dev)
- `git`, `wget`
- ~6 GB free disk for PX4 source + first build (cold build is 5–15 min, warm is ~30 s via ccache)

## Run

```sh
just              # build + launch PX4 with Gazebo GUI and QGroundControl in a zellij session
just run-headless # same, without the Gazebo window — see "GUI vs headless" below for why this matters
just close        # stop the container, kill QGC, tear down the session
just clean        # wipe PX4 build artifacts
```

The first `just` run clones `PX4-Autopilot` at the pinned commit, downloads the
QGroundControl AppImage (version pinned in `justfile`), builds the sim, and opens
three panes:

- **PX4 (cloudship)** — build output, then the `pxh>` REPL
- **QGC** — QGroundControl, autoconnecting via `udp://localhost:14550`
- **Terminal** — scratch shell for poking around (mavproxy, log inspection, etc.)

## GUI vs headless

GUI mode is the default because it's what most people expect. But on this stack
the GUI imposes a real cost — Gazebo Classic's renderer becomes the bottleneck
and physics simulation slows to a crawl. The objective comparison, measured on
this machine in two back-to-back runs:

| Property | GUI (`just`) | Headless (`just run-headless`) |
|---|---|---|
| Real-time factor (RTF) | **≈ 0** | **≈ 1.0** |
| `vehicle_status.timestamp` over 5 wall-clock s | stuck at ~16 ms | advances ~5,000,000 µs |
| Gazebo iteration rate | < 50 steps / wall-s | ~250 steps / wall-s |
| `gz topic -e /gazebo/default/world_stats` | sim_time delta ≈ 0 between samples | sim_time delta ≈ wall-clock delta |
| `paused` flag | false (but effectively idle) | false |
| 3D visualization | yes | none |
| QGC connectivity | works | works |
| `pxh>` listeners | values frozen, timestamps duplicate per publish | normal |

**Why GUI is slow:** the bionic container ships **Mesa 18.0** (2018), which
predates WSL's GPU passthrough (`dxgkrnl`/DXG, supported in Mesa 21+). Gazebo's
GUI falls back to software OpenGL via `llvmpipe`, which can't keep up with a
250 Hz physics step. Lock-step coupling (`<enable_lockstep>true</enable_lockstep>`
in `cloudship.sdf`) gates every physics tick on a render frame completing — so
the slow renderer directly throttles physics.

**Verifying which mode you're getting** (works either way):

```text
listener vehicle_status -n 1     # note `timestamp:` value
# wait ~5 seconds
listener vehicle_status -n 1     # in a healthy run, ~5_000_000 µs larger
```

If the second timestamp barely advanced, the sim clock is stalled — that's the
GUI bottleneck and the answer is `just close && just run-headless`.

**Practical guidance:**

- Use **`just`** (GUI) for visual sanity checks: confirming the model loaded,
  watching gross motion. Don't expect simulation time to behave.
- Use **`just run-headless`** for everything else: studying the controller,
  measuring response, recording with meaningful timestamps. Full telemetry is
  still available through QGC and `pxh>` listeners.

## Using the simulation

Treat this as a frozen reproduction of an experimental moment in PX4 history —
useful for studying the airship attitude controller and its Gazebo dynamics
plugin, not as a production flight target. The airframe is intentionally narrow:

- Only `airship_att_control` is loaded; there is no position controller, no
  mission stack, no autonomous nav.
- Useful flight modes are **MANUAL** and **STABILIZED**. POSITION / AUTO / RTL
  exist in the binary but won't behave usefully — there's no position control
  and PX4 has no way to actively change the airship's buoyancy.
- The 4-output mixer drives MAIN1 starboard thruster, MAIN2 port thruster,
  MAIN3 thrust-tilt servo, MAIN4 tail thruster (yaw). Stick mapping: pitch →
  tilt, yaw → tail, throttle → both main thrusters; roll is unused.

### Connecting QGC

Once `just` finishes building and the `pxh>` prompt appears, QGC's autoconnect
picks up the vehicle within a few seconds. Confirm in the PX4 pane:

```text
INFO  [mavlink] partner IP: 127.0.0.1, partner port: <ephemeral>
```

### Driving it

PX4 expects a live `manual_control_setpoint` stream; without one, the
manual-control-loss failsafe trips RTL the moment you arm.

- **Interactive poking:** QGC's virtual joystick. *Application Settings →
  General → Virtual Joystick* (enable), then *Vehicle Setup → Joystick →
  enable*. Two on-screen sticks appear in the flight view. Keep that view in
  focus or the stream stops publishing.
- **Scripted control:** at `pxh>`, `param set COM_RC_IN_MODE 4` to drop the
  stick requirement entirely, then drive via pymavlink / MAVSDK on UDP 14540.

The airship will not naturally fly straight under pure throttle — see the next
section for why.

### Arming and stopping

```text
commander arm           # arms; "Takeoff Detected" fires immediately due to buoyancy lift
commander disarm        # refused while in flight — buoyancy means the land detector may never trip
commander lockdown on   # kill outputs now; clear with `commander lockdown off`
shutdown                # clean PX4 exit; the docker container terminates
```

`just close` from the Terminal pane is the equivalent teardown from outside.

### Observing the autopilot

`listener <topic>` at `pxh>` prints one sample of any uORB topic. Most useful
for this airframe:

```text
listener vehicle_status            # arming_state, nav_state, failsafe flags, MAV_TYPE
listener actuator_outputs          # PWM values driven to MAIN1–4 (900 = disarmed)
listener manual_control_setpoint   # incoming stick values (−1.0 … 1.0)
listener vehicle_attitude          # current attitude quaternion + body rates
```

For a live stream, combine `-r INTERVAL_MS` (the listener's own help text calls
this "rate" but it's actually the minimum interval between deliveries, in
milliseconds — *larger value = slower*) with a large `-n COUNT`. Exit any time
with Ctrl-C, Esc, or Q.

```text
listener actuator_outputs        -r 1000 -n 999999   # ~1 sample/sec, comfortable to read
listener actuator_outputs        -r 200  -n 999999   # ~5 samples/sec
listener manual_control_setpoint -r 100  -n 999999   # ~10 samples/sec for stick study
```

`-r 0` (the default) means no rate limit — the listener prints as fast as the
topic publishes, which in SITL can be thousands of times per second.

## Why pure throttle makes the airship yaw

Pushing only throttle (no yaw stick input) on this airframe causes a
substantial yaw drift. Measured in headless mode by sending `MANUAL_CONTROL`
with `z=600, x=y=r=0` and reading `ATTITUDE` over 6 seconds:

| Axis | Baseline (z=0, ~4 s) | Throttle (z=600, ~6 s) |
|---|---|---|
| yaw rate (mean) | −0.05 rad/s | **−0.53 rad/s** (~30°/s) |
| yaw rate (peak) | 0.06 rad/s | **1.18 rad/s** (~67°/s) |
| roll rate (mean) | −0.01 rad/s | +0.14 rad/s |
| total yaw drift | −0.27 rad over 4 s | **+3.54 rad over 6 s** (~200°) |

This is not a software bug. The two main thrusters counter-rotate (CCW + CW,
`cloudship.sdf:382` and `:451`), so propeller-torque reaction cancels. The
cause is the **Munk moment** — a destabilizing aerodynamic effect that
elongated buoyant bodies experience.

In `Tools/sitl_gazebo/src/gazebo_airship_dynamics_plugin.cpp:291–292`:

```cpp
ignition::math::Vector3d added_mass_moment =
    -am_comp2 - (linear_vel.Cross(munk_comp1)
               + angular_vel.Cross(munk_comp2));
```

The `linear_vel.Cross(munk_comp1)` term ties forward velocity to a
yaw/pitch moment whose sign *amplifies* any non-zero sideslip rather than
damping it. Real airships have this same instability — it's why crewed
airships needed a constant rudder hand from a helmsman, and why early
designs added increasingly elaborate empennages for passive damping.

What this means for flying the cloudship:

- **MANUAL mode:** expect to continuously feed counter-yaw on the rudder
  stick (MAIN4 tail thruster) to stay on heading. This mimics real airship
  piloting.
- **STABILIZED mode** damps yaw *rate* but doesn't hold heading.
- There's no built-in heading-hold mode for this airframe. Implementing one
  on top of `airship_att_control` would be a reasonable extension.

## Source layout

The airship-specific files inside `PX4-Autopilot/`:

| Path | What's there |
|---|---|
| `src/modules/airship_att_control/` | The only flight controller |
| `Tools/sitl_gazebo/models/cloudship/` | Gazebo SDF model + dynamics plugin SDF tags |
| `Tools/sitl_gazebo/src/gazebo_airship_dynamics_plugin.cpp` | Buoyancy + aerodynamics (incl. Munk moment) |
| `ROMFS/px4fmu_common/init.d-posix/airframes/2507_cloudship` | Airframe init script |
| `ROMFS/px4fmu_common/init.d/rc.airship_apps` | Modules to start |
| `ROMFS/px4fmu_common/init.d/rc.airship_defaults` | Default params for vehicle type "airship" |
| `ROMFS/px4fmu_common/mixers/cloudship.main.mix` | Mixer mapping attitude → 4 outputs |

After editing any of these, `just clean && just run` rebuilds.
