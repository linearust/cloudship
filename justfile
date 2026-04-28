# NOTE: `default` must stay the first recipe — `just` with no args runs
# whichever recipe appears first in the file, regardless of name.

# Default — run cloudship SITL with QGroundControl
default: run


# ============================================================================
# Configuration
# ============================================================================

# QGroundControl
QGC_VERSION  := "v5.0.8"
QGC_APPIMAGE := "apps/QGroundControl.AppImage"
QGC_URL      := "https://github.com/mavlink/qgroundcontrol/releases/download/" + QGC_VERSION + "/QGroundControl-x86_64.AppImage"

# PX4 — pinned to the Aug 2020 commit that introduced the Airship vehicle type
PX4_DIR    := "PX4-Autopilot"
PX4_COMMIT := "fa4818e467"
PX4_TARGET := "px4_sitl gazebo_cloudship"

# Docker image — Ubuntu 18.04 / gazebo9 / gcc 7.5 to match the era of the source
DOCKER_IMAGE := "px4io/px4-dev-simulation-bionic:latest"
CONTAINER    := "cloudship-sim"

# Zellij session
LAYOUT_FILE    := "/tmp/cloudship_layout.kdl"
ZELLIJ_SESSION := "cloudship"


# ============================================================================
# Setup
# ============================================================================

# Clone PX4-Autopilot at the pinned commit, stage cloudship.sdf, fetch QGC
init:
    #!/usr/bin/env bash
    set -e
    if [ ! -d {{PX4_DIR}}/.git ]; then
        echo "Cloning PX4-Autopilot at {{PX4_COMMIT}}..."
        git clone https://github.com/PX4/PX4-Autopilot.git {{PX4_DIR}}
        ( cd {{PX4_DIR}} && git checkout {{PX4_COMMIT}} && git submodule update --init --recursive )
    fi
    # sitl_run.sh at this commit spawns ${model}/${model}.sdf, but the cloudship
    # model only ships cloudship.sdf.jinja and a pre-rendered cloudship-gen.sdf.
    # Stage cloudship.sdf so the spawn step finds it.
    model_dir={{PX4_DIR}}/Tools/sitl_gazebo/models/cloudship
    if [ -f "$model_dir/cloudship-gen.sdf" ] && [ ! -f "$model_dir/cloudship.sdf" ]; then
        cp "$model_dir/cloudship-gen.sdf" "$model_dir/cloudship.sdf"
    fi
    mkdir -p apps
    if [ ! -f {{QGC_APPIMAGE}} ] || [ "$(cat {{QGC_APPIMAGE}}.version 2>/dev/null)" != "{{QGC_VERSION}}" ]; then
        echo "Downloading QGroundControl {{QGC_VERSION}}..."
        wget -qO {{QGC_APPIMAGE}} "{{QGC_URL}}"
        chmod +x {{QGC_APPIMAGE}}
        echo "{{QGC_VERSION}}" > {{QGC_APPIMAGE}}.version
    fi


# ============================================================================
# Simulation
# ============================================================================

# Run cloudship SITL (Docker) + Gazebo Classic + QGroundControl in zellij panes
run: init
    #!/usr/bin/env bash
    set -e
    just _launch \
        "Cloudship" \
        "PX4 (cloudship)" \
        "$(just _docker-cmd)"

# Close PX4 SITL container, QGroundControl, and the zellij session
close:
    #!/usr/bin/env bash
    echo "Closing cloudship stack..."
    if docker ps -q -f name={{CONTAINER}} | grep -q .; then
        echo "  → Docker container ({{CONTAINER}})"
        docker stop {{CONTAINER}} >/dev/null 2>&1 || true
    fi
    docker rm {{CONTAINER}} >/dev/null 2>&1 || true
    if pgrep -f QGroundControl >/dev/null 2>&1; then
        echo "  → QGroundControl"
        pkill    -f QGroundControl 2>/dev/null || true
        sleep 1
        pkill -9 -f QGroundControl 2>/dev/null || true
    fi
    echo
    echo "✓ Cleanup complete"
    docker ps -q -f name={{CONTAINER}} | grep -q . && echo "⚠ container still running" || echo "✓ container stopped"
    pgrep -f QGroundControl >/dev/null 2>&1 && echo "⚠ QGC still running" || echo "✓ QGC closed"
    # MUST be last: killing the session may also kill this shell if `just close`
    # was invoked from inside a zellij pane.
    zellij kill-session   {{ZELLIJ_SESSION}} >/dev/null 2>&1 || true
    zellij delete-session {{ZELLIJ_SESSION}} --force >/dev/null 2>&1 || true


# ============================================================================
# Maintenance
# ============================================================================

# Remove PX4 build artifacts (build/ files are user-owned via LOCAL_USER_ID)
clean:
    rm -rf {{PX4_DIR}}/build


# ============================================================================
# Private helpers
# ============================================================================

# Print the docker-run command that builds + runs cloudship SITL.
# Forwards WSLg sockets so Gazebo Classic surfaces on the Windows desktop and
# publishes UDP 14550 (GCS) + 14556 (onboard SDK) so QGC and external tools
# can reach the airship via localhost. All values are baked in at generation
# time so the result can be embedded inside a zellij KDL string.
[private]
_docker-cmd:
    #!/usr/bin/env bash
    set -e
    cwd="$(pwd)"
    ccache="${CCACHE_DIR:-$HOME/.ccache}"
    mkdir -p "$ccache"
    display="${DISPLAY:-:0}"
    wayland="${WAYLAND_DISPLAY:-wayland-0}"
    cat <<EOF
    docker run --rm -it --name {{CONTAINER}} -e DISPLAY=$display -e WAYLAND_DISPLAY=$wayland -e XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir -e PULSE_SERVER=/mnt/wslg/PulseServer -e LIBGL_ALWAYS_SOFTWARE=1 -e LOCAL_USER_ID=$(id -u) -e CCACHE_DIR=$ccache -v /tmp/.X11-unix:/tmp/.X11-unix -v /mnt/wslg:/mnt/wslg -v $cwd/{{PX4_DIR}}:$cwd/{{PX4_DIR}}:rw -v $ccache:$ccache:rw -w $cwd/{{PX4_DIR}} -p 14556:14556/udp -p 14550:14550/udp {{DOCKER_IMAGE}} bash -c 'make {{PX4_TARGET}}'
    EOF

# Build the zellij 3-pane layout (PX4 / QGC / Terminal) and launch the session.
# px4_cmd is the bash command for the PX4 pane; qgc_delay is seconds to wait
# before launching QGC (long enough for the docker container to publish 14550).
# QGC runs with --appimage-extract-and-run so it works without libfuse2 installed.
[private]
_launch tab_label pane_label px4_cmd qgc_delay="5":
    #!/usr/bin/env bash
    set -e
    cat > {{LAYOUT_FILE}} <<KDL
    layout {
        tab name="{{tab_label}}" {
            pane split_direction="vertical" {
                pane name="{{pane_label}}" {
                    command "bash"
                    args "-c" "{{px4_cmd}}"
                }
                pane split_direction="horizontal" {
                    pane name="QGC" {
                        command "bash"
                        args "-c" "sleep {{qgc_delay}} && $(pwd)/{{QGC_APPIMAGE}} --appimage-extract-and-run"
                    }
                    pane name="Terminal" focus=true {
                        command "bash"
                    }
                }
            }
        }
    }
    KDL
    # -l with --session attaches-and-adds-tab; --new-session-with-layout always creates fresh.
    zellij delete-session {{ZELLIJ_SESSION}} --force >/dev/null 2>&1 || true
    exec zellij --session {{ZELLIJ_SESSION}} --new-session-with-layout {{LAYOUT_FILE}}
