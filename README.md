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
just            # build + launch PX4, Gazebo, and QGroundControl in a zellij session
just close      # stop the container, kill QGC, tear down the session
just clean      # wipe PX4 build artifacts
```

The first `just` run clones `PX4-Autopilot` at the pinned commit, downloads the
QGroundControl AppImage (version pinned in `justfile`), builds the sim, and opens
three panes:

- **PX4 (cloudship)** — build output, then the `pxh>` REPL
- **QGC** — QGroundControl, autoconnecting via `udp://localhost:14550`
- **Terminal** — scratch shell for poking around (mavproxy, log inspection, etc.)

## Flying it

The cloudship airframe (`2507_cloudship`) runs `airship_att_control` only — there is
no position controller and no mission stack. Available flight modes are **MANUAL**
and **STABILIZED**.

The four-output mixer drives starboard/port thrusters, a thrust-tilt servo, and a
tail thruster (yaw), so the natural way to fly is with a USB gamepad configured
under QGC's *Vehicle Setup → Joystick*. Arm in MANUAL, push throttle, fly.
