<p align="center">
  <img src="icons/Logo-Arm-WhiteOrange-372x372-1.png" alt="Mechatronics Academy" width="140">
</p>

# rover_docker

Docker files to build the ARM64 balena application release for the Rover A1.
The application uses ROS 2 Lyrical on Ubuntu 26.04; the balenaOS host image
is managed separately.

Four services are deployed to the balenaCloud fleet `g_potlog_radu/rovera1`.
Each has its own folder holding its Dockerfile and any scripts, which is the
service's build context in `docker-compose.yml`:

| Service            | Folder              | Contents                                                                   |
|--------------------|---------------------|----------------------------------------------------------------------------|
| `rover-a1-zenoh-router`  | `rover_a1_zenoh_router/`  | Ubuntu 26.04 + `rmw_zenoh_cpp` only: the Zenoh router (`rmw_zenohd`) on 7447 that every ROS process connects to, as the container's only process. Its own service so platform restarts and releases leave the ROS graph up. See [ROS 2 over the rover LAN](#ros-2-over-the-rover-lan-zenoh) |
| `rover-a1-platform`      | `rover_a1_platform/`      | Ubuntu 26.04 + ROS 2 Lyrical + rover firmware (sshd, `rover_bringup`, rosbridge, foxglove_bridge); `start.sh` is the entrypoint |
| `rover-a1-orchestrator` | `rover_a1_orchestrator/` | Ubuntu 26.04 + ROS 2 Lyrical + [`rover_orchestrator`](https://github.com/RaduPotlog/rover_orchestrator) — the autonomy stack (Nav 2 via `rover_navigation`, plus `rover_mission_manager`), plus an sshd on port 24 and the Claude Code CLI with `ros-mcp` registered; `start.sh` is the entrypoint. Idle unless enabled, see [Where the orchestrator runs](#where-the-orchestrator-runs) |
| `rover-a1-sensors` | `rover_a1_sensors/` | Ubuntu 26.04 + ROS 2 Lyrical + [`rover_sensors`](https://github.com/RaduPotlog/rover_sensors) — the sensor payload: RUTX11 GNSS driver (`gps/fix`) and RoboSense RS16 lidar driver (`scan`, `rslidar_points`), with their diagnostics, plus an sshd on port 23 and the Claude Code CLI with `ros-mcp` registered. Drivers only publish, so a different sensor changes this image only; `start.sh` is the entrypoint |
| `rover-a1-drive-interface` | `rover_a1_drive_interface/` | nginx + [`rover_drive_interface`](https://github.com/RaduPotlog/rover_drive_interface) — Boxer / IndoorNav-style drive UI on port 5000 behind a login; nginx proxies `/ws` to foxglove_bridge (no ROS inside). Plus an sshd on port 25 and the Claude Code CLI with `ros-mcp` registered. See [Drive interface](#drive-interface) |
| `rover-a1-vda5050` | `rover_a1_vda5050/` | Ubuntu 26.04 + ROS 2 Lyrical + [`rover_vda5050`](https://github.com/RaduPotlog/rover_vda5050) — the VDA 5050 2.0 fleet interface (InOrbit's MQTT connector, vendored, driving the rover through `rover_mission_manager`), an optional Mosquitto broker (1883, WebSockets 9001), plus an sshd on port 26 and the Claude Code CLI with `ros-mcp` registered. Idle unless enabled, see [VDA 5050](#vda-5050) |
| `rover-a1-follow-me` | `rover_a1_follow_me/` | Ubuntu 26.04 + ROS 2 Lyrical + [`rover_follow_me`](https://github.com/RaduPotlog/rover_follow_me) — follow-me: an algorithm tracks a person (`fmoc`: ADBSCAN on the RealSense depth cloud) and the `follow_me` node runs following as a goal of Nav 2's Following server (in `rover-a1-orchestrator`), plus an sshd on port 27 and the Claude Code CLI with `ros-mcp` registered. Never publishes `cmd_vel`. Idle unless enabled, see [Follow-me](#follow-me) |
| `rover-a1-network` | `rover_a1_network/` | Python + [`rover_networking`](https://github.com/RaduPotlog/rover_networking) (`rutx11/`): web page on port 5080 (behind a login) that switches the RUTX11's Wi-Fi uplink in place and keeps the router's firewall/NAT consistent (no ROS, no sshd). See [Network uplink page](#network-uplink-page) |

```
rover_docker/
├── docker-compose.yml
├── rover_a1_zenoh_router/
│   ├── Dockerfile
│   ├── healthcheck.sh
│   └── start.sh
├── rover_a1_platform/
│   ├── Dockerfile
│   └── start.sh
├── rover_a1_orchestrator/
│   ├── Dockerfile
│   └── start.sh
├── rover_a1_sensors/
│   ├── Dockerfile
│   └── start.sh
├── rover_a1_drive_interface/
│   ├── Dockerfile
│   ├── nginx.conf.template
│   ├── healthcheck.sh
│   └── start.sh
└── rover_a1_network/
    ├── Dockerfile
    ├── healthcheck.sh
    └── start.sh
```

## Build and validate for ARM64

Run commands from `rover_docker/`. Use a Docker Buildx builder that supports
`linux/arm64`, either natively or through emulation. In WSL, enable Docker
Desktop integration for the distribution first.

```bash
bash -n rover_a1_platform/start.sh
bash -n rover_a1_orchestrator/start.sh
bash -n rover_a1_sensors/start.sh
bash -n rover_a1_drive_interface/start.sh
bash -n rover_a1_drive_interface/healthcheck.sh
docker compose config --quiet
docker buildx inspect --bootstrap
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rover-a1-platform:lyrical ./rover_a1_platform
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rover-a1-orchestrator:lyrical ./rover_a1_orchestrator
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rover-a1-sensors:lyrical ./rover_a1_sensors
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rover-a1-drive-interface:lyrical ./rover_a1_drive_interface
```

The application build defaults to the `rover_ros` **master** branch and
imports its `hardware_deps.repos`, including the receiver and transport
dependencies. `ROS_DISTRO=lyrical` is baked into the image and
used for package installation, rosdep, compilation, and startup; do not
override it with a different distribution at runtime.

Check the built image without starting hardware bringup:

```bash
docker run --rm --platform linux/arm64 --entrypoint /bin/bash \
  rover-a1-platform:lyrical -ec '
    test "$(dpkg --print-architecture)" = arm64
    test "$ROS_DISTRO" = lyrical
    source /opt/ros/$ROS_DISTRO/setup.bash
    source /root/ros2_ws/rover_a1/install/setup.bash
    for package in rover_bringup rmw_zenoh_cpp rosbridge_server rosapi foxglove_bridge; do
      ros2 pkg prefix "$package"
    done
  '
```

The orchestrator image builds `rover_orchestrator` (plus the parts of `rover_ros` it
depends on) with `colcon build --packages-up-to rover_autonomy`, so the hardware packages
are never compiled there. Every `nav2_*` package, `nav2_smac_planner` included, comes from
the arm64 debs, so its prefix below is `/opt/ros/lyrical`. Check it the same way:

```bash
docker run --rm --platform linux/arm64 --entrypoint /bin/bash \
  rover-a1-orchestrator:lyrical -ec '
    test "$(dpkg --print-architecture)" = arm64
    source /opt/ros/$ROS_DISTRO/setup.bash
    source /root/ros2_ws/rover_a1/install/setup.bash
    for package in rover_autonomy rover_navigation rover_mission_manager \
                   nav2_lifecycle_manager nav2_smac_planner slam_toolbox \
                   spatio_temporal_voxel_layer rmw_zenoh_cpp; do
      ros2 pkg prefix "$package"
    done
    ros2 launch rover_navigation bringup.launch.py --show-args > /dev/null
  '
```

Before deployment, smoke-test `rmw_zenohd`, rosbridge, and Foxglove in an
isolated container with the entrypoint overridden (no hardware bringup),
and check workspace shared libraries with `ldd` for missing dependencies.
On the rover, verify hardware bringup, the LAN Zenoh connection, and bridge ports after
deployment. A successful image build alone does not validate hardware.

See the [Docker multi-platform build documentation](https://docs.docker.com/build/building/multi-platform/)
for builder setup.

## Deploy

The fleet must use an ARM64 device type. This command builds and deploys
all services to the fleet; local validation above does not deploy them.

```bash
balena push g_potlog_radu/rovera1 --nocache
```

`--nocache` matters: every service fetches its application source with
`git clone` during the build (`rover_ros`; `rover_ros` + `rover_orchestrator`;
`rover_sensors`; `rover_drive_interface`; and
`rover_networking` respectively). Those
clones sit in cached layers, so a plain `balena push` will happily ship stale application
code.

Select specific application commits instead of branch tips with:

```bash
balena push g_potlog_radu/rovera1 \
  --build-arg ROVER_ROS_REF=<sha> \
  --build-arg ROVER_ORCHESTRATOR_REF=<sha> \
  --build-arg ROVER_SENSORS_REF=<sha> \
  --build-arg ROVER_NETWORKING_REF=<sha>
```

`ROVER_ROS_REF` is consumed by both `rover-a1-platform` and `rover-a1-orchestrator`, so the
two stay on the same `rover_ros` commit. `ROVER_SENSORS_REF` pins `rover_sensors` in
`rover-a1-sensors`. The sensors and the platform share only topic names (`gps/fix`, `scan`,
`rslidar_points`, `diagnostics`), so their commits can move independently as long as that
contract holds.

> **Renaming note.** `rover-a1-platform` was previously the service `rovera1-app`. balena
> treats a renamed service as a new one, so any *service-scoped* device or fleet variable
> that was set on `rovera1-app` no longer applies. Re-create them against
> `rover-a1-platform` (`balena env set … --service rover-a1-platform`) or promote them to
> all-services variables. The old service and its image are removed from the device on the
> next push.

Use a Lyrical-compatible commit for `ROVER_ROS_REF`. These overrides pin
only the application repositories: imported dependency branches, base
image tags, apt packages, and npm/uv tool versions can still change. Use
`--nocache` when refreshing those dependencies even with pinned application
commits.

## Ports

All containers use host networking, so these bind directly to the device:

| Port   | Service                        |
|--------|--------------------------------|
| 22     | sshd (`rover-a1-platform`)           |
| 23     | sshd (`rover-a1-sensors`)            |
| 24     | sshd (`rover-a1-orchestrator`)       |
| 25     | sshd (`rover-a1-drive-interface`)    |
| 26     | sshd (`rover-a1-vda5050`)            |
| 27     | sshd (`rover-a1-follow-me`)          |
| 1883   | MQTT, VDA 5050 (`rover-a1-vda5050`'s Mosquitto, with `ROVER_VDA5050_LOCAL_BROKER=true`; anonymous, LAN only) |
| 5000   | Drive interface (`rover-a1-drive-interface`, plain http, basic-auth login; `/ws` is proxied to 8765) |
| 5080   | Network page: switch the router's Wi-Fi uplink (`rover-a1-network`, plain http, basic-auth login) |
| 7447   | Zenoh router (`rover-a1-zenoh-router`; loopback + rover LAN only, see below) |
| 8765   | foxglove_bridge                |
| 9001   | MQTT over WebSockets (`rover-a1-vda5050`'s Mosquitto), for browser tools such as vda5050_visualizer |
| 9090   | rosbridge websocket (ros-mcp-server only; dashboards use 8765) — served by `rover-a1-platform`, used by the `ros-mcp` in **every** container |
| 10110/udp | RUTX11 NMEA forwarding → GNSS driver (`rover-a1-sensors`) |
| 10111/udp | RUTX11 Serial Utilities → ELRS CRSF → RC teleop (`rover-a1-platform`, `rover_crsf_udp_receiver`; accepts `192.168.1.1` only) |
| 6699/udp, 7788/udp | RoboSense RS16 MSOP / DIFOP → lidar driver (`rover-a1-sensors`) |
| 48484  | balena supervisor              |

Host networking gives every container a single port space, so each sshd has its own port —
platform **22**, sensors **23**, orchestrator **24**, drive-interface **25**, vda5050 **26**.
No ROS container runs a Zenoh router of its own: they all join `rover-a1-zenoh-router` on 7447 (see
[ROS 2 over the rover LAN](#ros-2-over-the-rover-lan-zenoh)).

That sshd takes the same credentials as `rover-a1-platform`'s — root password login, baked
into the image. Only the port differs: `ssh -p 24 root@<rover-lan-ip>`. See
[Orchestrator SSH](#orchestrator-ssh).

## Orchestrator SSH

`rover-a1-orchestrator` runs its own sshd on **24**, configured in the image
(`rover_a1_orchestrator/Dockerfile`) exactly as `rover-a1-platform`'s is on 22 — `root:root`,
`PermitRootLogin yes`, `UsePAM no` — through a `/etc/ssh/sshd_config.d/` drop-in.

```bash
ssh root@<rover-lan-ip>             # 22  platform: drivers, bringup, web bridges
ssh -p 23 root@<rover-lan-ip>       # 23  sensors: GNSS + lidar drivers
ssh -p 24 root@<rover-lan-ip>       # 24  orchestrator: Nav 2 + mission manager
ssh -p 25 root@<rover-lan-ip>       # 25  drive interface: nginx
ssh -p 26 root@<rover-lan-ip>       # 26  vda5050: VDA 5050 connector + Mosquitto
```

`start.sh` starts sshd ahead of the enable/disable gate, so the container is reachable even
when the autonomy stack is idling — which is when a shell is most useful. sshd is supervised
alongside Nav 2: if it dies the service tears down and `restart: always` brings it back.

Two caveats, both inherited from `rover-a1-platform` and neither specific to this port:

- The password is the image default. Anything that can reach the rover LAN can reach both
  shells, so treat that LAN as the security boundary, and change the password in the
  Dockerfile before any deployment that is not on a trusted network.
- Host keys are generated when `openssh-server` installs at **build** time, so every device
  from one image build shares them. Regenerating per device (`rm -f /etc/ssh/ssh_host_*` in
  the Dockerfile plus `ssh-keygen -A` in `start.sh`) is the fix if that matters.

Neither is a regression — it is the arrangement port 22 has always had — but every extra
shell (23–26) widens the surface, so it is worth stating.

After an image rebuild the host keys change, so `ssh` warns "host key changed" once per port;
clear the old entry with `ssh-keygen -R '[<rover-lan-ip>]:<port>'` (plain `<rover-lan-ip>` for 22).

### Claude Code and ros-mcp on every shell

Every image carries the same Claude tooling: the `@anthropic-ai/claude-code` CLI plus `ros-mcp`
(with the `fastmcp<4` pin), registered at user scope at build time. So `claude` works
identically on all five SSH shells: platform 22, sensors 23, orchestrator 24,
drive-interface 25 and vda5050 26. Use the shell of the container you are debugging:
- port 24 for Nav 2, the costmaps or the mission manager;
- port 23 for the GNSS or lidar payload;
- port 22 for the drivers and bringup.

- **One-time login.** `claude` prompts for authentication on first run. The credential is
  written to `/root/.claude.json` **inside the container**, so it does not survive a container
  recreate — every balena release means logging in again. If that friction bites, declare an
  unset `ANTHROPIC_API_KEY` on every service in `docker-compose.yml` and set it as a
  balenaCloud variable instead.
- **ros-mcp needs `rover-a1-platform` running.** It reaches rosbridge at `127.0.0.1:9090`,
  which is served by that container — host networking gives every service one namespace,
  which is why no other container runs a rosbridge of its own. With the
  platform stopped, `claude mcp list` shows ros-mcp failing to connect.

## Sensors SSH

`rover-a1-sensors` runs its own sshd on **23**, set up like the orchestrator's (same
`root:root` credentials, `/etc/ssh/sshd_config.d/` drop-in); only the port differs.

```bash
ssh -p 23 root@<rover-lan-ip>       # sensors: GNSS + lidar drivers
```

As in the orchestrator, `start.sh` starts sshd ahead of the `ROVER_START_SENSORS` gate, so the
shell is up while the payload idles, and a dead sshd restarts the service. The caveats above
(image-default password, host keys shared per build) apply here too, as does everything in
[Claude Code and ros-mcp on every shell](#claude-code-and-ros-mcp-on-every-shell): this image
carries the same `claude` and `ros-mcp` as the others.

## Drive interface

`rover-a1-drive-interface` serves a Clearpath Boxer / IndoorNav-style drive UI from
[`rover_drive_interface`](https://github.com/RaduPotlog/rover_drive_interface). Open
`http://<rover-lan-ip>:5000/` (the Boxer's OTTO App and IndoorNav use the same port) and log
in. It is built for one rover and indoor navigation.

- **Transport:** nginx serves the page and proxies the same-origin websocket `/ws` to
  foxglove_bridge on `127.0.0.1:8765`. Both sit behind the same basic-auth login, because
  foxglove_bridge itself has no authentication. The container runs no ROS.
- **Driving modes** (owned by `rover_drive_mode` in `rover-a1-orchestrator`, shared by every
  browser; the rover boots in `ROVER_DRIVE_DEFAULT_MODE`, `assisted` by default):
  - **Manual:** the joystick goes straight to the platform, no obstacle check.
  - **Assisted:** the joystick goes through a lidar collision monitor that slows the rover
    down and then stops it in front of an obstacle. With no lidar data it blocks all motion.
  - **Automatic:** Nav 2 drives (**Go to**). Moving the joystick takes over: the rover
    switches to Assisted and the mission is cancelled.
  The joystick publishes `<ns>/teleop_web_cmd_vel_stamped` at 10 Hz; `rover_drive_mode`
  routes it onto `<ns>/teleop_driver_interface_cmd_vel_stamped` (twist_mux priority 8). The RC
  transmitter and the Foxglove joystick bypass the modes and always override.
- **Joystick on/off:** per browser, the page starts with the joystick off and publishes
  nothing. Hiding the tab, losing focus or losing the connection stops publishing and turns
  it off again; twist_mux's timeout stops the rover.
- **Gamepad:** a pad drives only while L1/LB is held.
- **Other controls:** e-stop buttons call the `hardware_interface/sw_*` Trigger services.
- **Top bar:** safety (e-stop, latch, `motion_lock`), diagnostics, battery and
  link latency (a round trip through `/rosapi/get_time`).
- **Map view:** shows the occupancy map, the lidar scan, the Nav 2 plan and the rover. Tools:
  **Set pose** (AMCL `initialpose`) and **Go to** (`rover_mission_manager` `set_mission`), plus
  **Stop**. These need `ROVER_START_NAVIGATION=true` and `ROVER_START_MISSION_MANAGER=true`,
  and Go to needs the Automatic driving mode.
- **Places and Facility** (indoor mode only, `ROVER_LOCALIZATION_SOURCE=indoor`):
  1. Record a map with **Start mapping**.
  2. **Save map as…** a name.
  3. **Load** it (AMCL).
  4. Save named places on it, then send the rover to one place or run a workflow through
     several.

### Drive interface SSH

`rover-a1-drive-interface` runs its own sshd on **25**. It is set up like the other containers'
(same `root:root` credentials, `/etc/ssh/sshd_config.d/` drop-in); only the port differs.

```bash
ssh -p 25 root@<rover-lan-ip>       # drive interface: nginx, /tmp/nginx.conf, /tmp/drive-config.json
```

`start.sh` starts sshd before its gates and supervises it together with nginx: if either
exits, the container restarts.

When `ROVER_DRIVE_ENABLE=false`, or `ROVER_DRIVE_PASSWORD` is unset, the container **idles**
with only sshd running instead of exiting. It leaves `/tmp/drive-interface-idle`, which the
healthcheck accepts, so balenaEngine does not restart the idle container as unhealthy. The
caveats of the other shells apply here too: an image-default password, and host keys shared
per build. The image runs no ROS itself, but carries `claude` and `ros-mcp` like the others (see [Claude Code and ros-mcp on every shell](#claude-code-and-ros-mcp-on-every-shell)).

### Drive interface variables

| Variable | Default | Effect |
|----------|---------|--------|
| `ROVER_DRIVE_ENABLE` | `true` | `false` = the container idles (sshd on 25 only). |
| `ROVER_DRIVE_PORT` | `5000` | Port nginx binds (plain http). |
| `ROVER_DRIVE_USER` | `rover` | Login user. |
| `ROVER_DRIVE_PASSWORD` | *(unset)* | Required. Without it nginx is not started and the container idles (sshd only), logging an error. |
| `ROVER_DRIVE_MAX_LINEAR` / `_ANGULAR` | `1.0` / `1.0` | 100 % speed preset in m/s / rad/s; the presets are 20/50/80/100 % of it. The drive controller clamps at 1.2 m/s, 1.0 rad/s. |
| `ROVER_DRIVE_MAX_RIM_SPEED` / `_TRACK_WIDTH` | `1.7` / `1.0204` | Outer-wheel rim-speed budget (m/s) and effective track width (m), as `max_wheel_rim_speed` / `effective_track_width` in rover_crsf_teleop.yaml: above the budget v and w are scaled together, keeping the arc. `0` disables the limit. |
| `ROVER_DRIVE_EXPO_LINEAR` / `_ANGULAR` | `0.3` / `0.5` | Stick expo per axis, `0` (linear) to `1` (softest): small stick moves give much less speed, full stick is still full speed. Out-of-range values fall back to the default. |
| `ROVER_DRIVE_AUX_OUTPUT_NAMES` / `ROVER_DRIVE_AUX_INPUT_NAMES` | unset | Names for the six aux outputs (PLC DIO00..05) and inputs (DIO06..11) in the Aux IO popup, comma-separated in order, e.g. `Beacon,Tool power,,,,`. A blank or missing entry keeps the default name ("Output 3" and so on). |

Limitations:

- The balena Public Device URL only forwards port 80, which nothing serves, so the drive
  interface is reachable on the rover LAN only.
- A page served over https would need `wss`; nginx already builds the websocket URL from the
  page scheme, so a TLS proxy in front of port 5000 works unchanged.

## Network uplink page

`rover-a1-network` serves `http://<rover-lan-ip>:5080/`, with login `rover` and
`NETUI_PASSWORD`. The page switches the RUTX11's Wi-Fi uplink to another network **in place**,
keeping the router's firewall zones, NAT and forwarding valid, so the wired LAN and the rover AP
keep internet. It also repairs the damage a RutOS *Scan → Join* does. Every change is rolled
back by the router itself if the new uplink doesn't come up.

The application and all its documentation live in the `rutx11/` folder of
[rover_networking](https://github.com/RaduPotlog/rover_networking/tree/master/rutx11): usage,
checks, the rollback design, running it from a laptop, and troubleshooting. This directory
holds only the container glue. The Dockerfile clones rover_networking at
`ROVER_NETWORKING_REF` (default `master`), runs the tests in `rutx11/`, and fails the build if
any test fails.

Set both passwords as **service** variables of `rover-a1-network`. Don't set them fleet-wide,
or every container would see the router's root password:

```bash
balena env set RUTX11_PASSWORD '<router root password>' --device <uuid> --service rover-a1-network
balena env set NETUI_PASSWORD '<page password>' --device <uuid> --service rover-a1-network
```

| Variable | Default | Effect |
|----------|---------|--------|
| `ROVER_NETWORK_ENABLE` | `true` | `false` = the container idles. |
| `NETUI_PORT` / `NETUI_USER` | `5080` / `rover` | Port and login user. |
| `NETUI_PASSWORD` | *(unset)* | Required; without it the container idles and logs an error. |
| `RUTX11_HOST` / `RUTX11_USER` / `RUTX11_PASSWORD` | `192.168.1.1` / `root` / *(unset)* | Router SSH login; the password is required. |
| `UPLINK_IFACE` | `auto` | uci network of the Wi-Fi uplink; `auto` detects it (RutOS names it `WWAN1`, `wan1`, …). |
| `UPLINK_ZONE` / `LAN_ZONE` / `CLIENT_NETS` | `wwan` / `lan` / `lan WWAN` | Zones and the client networks that must reach the internet. |

The router's host key and the job log persist in the volume `rover-network` (`/data`).
Without either password the container idles and leaves `/tmp/network-idle`, which the
healthcheck accepts. The service runs as an unprivileged user and has no sshd.

## Device variables

Every variable below is declared on **every** service in `docker-compose.yml`, so a fleet or
device variable reaches whichever container reads it. The *read by* column names the services
that actually act on the value; the others simply carry it. Defaults come from
`docker-compose.yml` or from each service's `start.sh`. Override them per device
(balenaCloud → device → **Device Variables**) or per fleet (**Fleet Variables**).

Booleans accept `true`/`1`/`yes`/`on` in any case; anything else means false.

### Stack toggles

| Variable | Default | Read by | Effect |
|----------|---------|---------|--------|
| `ROVER_START_ROS_PLATFORM` | `true` | platform, orchestrator | `false` skips `ros2 launch rover_bringup rover_bringup.launch.py`. sshd and the web bridges still run (and the Zenoh router, in its own service). The orchestrator also stays idle, since there is no platform to drive. |
| `ROVER_START_NAVIGATION` | `false` | orchestrator | `true` starts the autonomy stack (`rover_navigation` → Nav 2) on this device. Requires `ROVER_START_ROS_PLATFORM=true`. Leave `false` when a companion controller runs the stack. |
| `ROVER_START_MISSION_MANAGER` | `false` | orchestrator | `true` also starts `rover_mission_manager` on top of Nav 2. Only consulted when the orchestrator stack starts at all. The Automatic driving mode is refused without it. |
| `ROVER_START_DRIVE_MODE` | `true` | orchestrator | Starts `rover_drive_mode` (driving modes + the Assisted lidar guard), even when `ROVER_START_NAVIGATION=false`. `false` leaves the drive UI's joystick connected to nothing. Requires `ROVER_START_ROS_PLATFORM=true`. |
| `ROVER_DRIVE_DEFAULT_MODE` | `assisted` | orchestrator | Driving mode at boot: `assisted` or `manual`. Never `automatic`. |
| `ROVER_START_SENSORS` | `false` | sensors | `true` starts the sensor payload in `rover-a1-sensors` (GNSS with `ROVER_USE_GPS`, lidar with `ROVER_USE_LIDAR`). `false` idles the container. It also idles when both `ROVER_USE_GPS` and `ROVER_USE_LIDAR` are false, since there is no driver to run. |

### VDA 5050

| Variable | Default | Read by | Effect |
|----------|---------|---------|--------|
| `ROVER_START_VDA5050` | `false` | vda5050 | `true` starts the VDA 5050 connector. Orders drive through `rover_mission_manager`, so they also need `ROVER_START_NAVIGATION=true` and `ROVER_START_MISSION_MANAGER=true` on the orchestrator, and the rover in the Automatic driving mode. |
| `ROVER_VDA5050_LOCAL_BROKER` | `true` | vda5050 | Run Mosquitto in the container (1883, WebSockets 9001, anonymous). `false` when master control brings its own broker. |
| `ROVER_VDA5050_BROKER_HOST` / `_PORT` | `127.0.0.1` / `1883` | vda5050 | The broker the connector uses. |
| `ROVER_VDA5050_BROKER_USER` / `_PASSWORD` | unset | vda5050 | Broker login. A user also switches the connector to TLS (CA bundle from `VDA5050_CONNECTOR_TLS_CA_CERT`, default the system bundle). |
| `ROVER_VDA5050_BROKER_TLS` | `auto` | vda5050 | `auto`: TLS when a user is set. `false`: user/password without TLS, for a broker reached through WireGuard. `true`: always TLS. |
| `ROVER_VDA5050_MANUFACTURER` / `_SERIAL_NUMBER` | `MechatronicsAcademy` / `rover_a1` | vda5050 | VDA 5050 identity; topics are `uagv/v2/<manufacturer>/<serial>/…`. |
| `ROVER_VDA5050_MAP_FRAME` | unset | vda5050 | Nav 2 frame the order coordinates are in (prefixed with the namespace). Unset follows the orchestrator's localization source like its `start.sh` does: `odom` for odom, `map` for gps/slam/amcl/indoor. |

See [VDA 5050](#vda-5050) for what the interface supports.

### Follow-me

| Variable | Default | Read by | Effect |
|----------|---------|---------|--------|
| `ROVER_START_FOLLOW_ME` | `false` | follow-me | `true` starts follow-me (`fmoc` and the `follow_me` node). Following drives through Nav 2's Following server, so it needs `ROVER_START_NAVIGATION=true` and `ROVER_START_MISSION_MANAGER=true` on the orchestrator (AUTOMATIC needs the mission manager); the container warns when either is off. |
| `ROVER_FOLLOW_ME_ALGO` | `fmoc` | follow-me | The follow-me algorithm. `fmoc` (follow-me on camera) needs `ROVER_USE_CAMERA=true` and the depth cloud (`ROVER_CAMERA_DEPTH_CLOUD`, on by default). |

See [Follow-me](#follow-me).

### Robot configuration

| Variable | Default | Read by | Effect |
|----------|---------|---------|--------|
| `ROVER_NAMESPACE` | `rover` | all | ROS namespace (see [ROS namespace](#ros-namespace)). Keep it equal across services. |
| `ROVER_ZENOH_MODE` | platform `peer`, orchestrator and sensors `client` | platform, orchestrator, sensors | How each container's ROS processes join the graph. `peer`: direct links between processes, plus one to the router. `client`: one link each, to `rover-a1-zenoh-router`. The split keeps the platform's control loops independent of the router, which stalls for up to a minute while cleaning up after an orchestrator restart. See [ROS 2 over the rover LAN](#ros-2-over-the-rover-lan-zenoh) before changing it. |
| `ROVER_USE_GPS` | `false` | sensors, platform, orchestrator | One switch for GPS. `true`: `rover-a1-sensors` starts the RUTX11 GNSS driver (`gps/fix`, `GPS fix` diagnostics) and the platform fuses it (`rover_gps_heading` alignment, `navsat_transform`, global EKF; it publishes `map → odom` only with `ROVER_GPS_PUBLISH_MAP_TF=true`). `false`: no GPS driver, EKF on wheel odometry + IMU only. In the orchestrator it selects Nav 2's `localization_source` (`gps` vs `odom`). |
| `ROVER_GPS_PUBLISH_MAP_TF` | `false` | platform, orchestrator | Only matters with `ROVER_USE_GPS=true`. `true`: the global EKF broadcasts `map → odom`. `false`: it keeps fusing GPS and publishing `odometry/global` but leaves `map → odom` to slam_toolbox or AMCL. The orchestrator warns when this is `false` with `localization_source=gps`, since then nothing publishes `map → odom`. Set it as an all-services variable. |
| `ROVER_USE_LIDAR` | `false` | sensors, orchestrator | Starts the RoboSense RS16 driver in `rover-a1-sensors`. Leave `false` on rovers with no lidar fitted. The orchestrator logs a warning when it is false: both Nav 2 costmaps mark and clear from `<namespace>/scan`, so navigation would drive blind. |
| `ROVER_USE_CAMERA` | `false` | sensors, orchestrator | Starts the RealSense D435i driver and the camera perception nodes in `rover-a1-sensors` (see [rover_perception](../src/rover_perception/README.md)), and publishes its depth cloud (`camera/depth/points`). It does not change Nav 2: the cloud joins the costmap only with `ROVER_NAV_USE_CAMERA`; the orchestrator reads this variable just to warn about that combination. Counts as a driver for `ROVER_START_SENSORS`, so a camera-only payload does not idle. Needs USB access to the camera in the container. |
| `ROVER_NAV_USE_CAMERA` | `false` | orchestrator | Adds the depth cloud (`camera/depth/points`) as a second source of the **local** Nav 2 costmap. Needs `ROVER_USE_CAMERA=true` (the orchestrator warns otherwise). Leave it off until the camera mount (`ROVER_CAMERA_*`) is measured: with a wrong mount the camera marks obstacles in the wrong place. `false` keeps the lidar scan as the only source. |
| `ROVER_CAMERA_DEPTH_CLOUD` | `true` | sensors | With `ROVER_USE_CAMERA=true`: publish the depth image as a `PointCloud2` (`camera/depth/points`), for the costmap with `ROVER_NAV_USE_CAMERA` (CPU only). |
| `ROVER_CAMERA_FIDUCIALS` | `false` | sensors | With `ROVER_USE_CAMERA=true`: AprilTag (36h11) detection on the colour stream. The tag size in `rover_perception_bringup/config/apriltag.yaml` is an assumption until measured. |
| `ROVER_CAMERA_DETECTION` | `false` | sensors | With `ROVER_USE_CAMERA=true`: YOLO object detection on the colour stream (`detections`, `vision_msgs/Detection2DArray`). Needs `ROVER_CAMERA_DETECTION_MODEL`. |
| `ROVER_CAMERA_DETECTION_MODEL` | *(unset)* | sensors | Path inside the container of a YOLOv8/v11 `.onnx` file, for example on a volume. Without it the detector refuses to configure and logs why. |
| `ROVER_CAMERA_DETECTION_GPU` | `false` | sensors | `true` asks ONNX Runtime for CUDA. The rover image ships CPU `onnxruntime` only, so this is for a GPU host. |
| `ROVER_USE_TERRAIN` | `false` | sensors | Ground slope from the lidar cloud (`terrain/incline`, `terrain/ground_confidence`). Independent of the camera; needs `ROVER_USE_LIDAR=true`. |
| `ROVER_CAMERA_FPS` | `15` | sensors | Frame rate of the colour and depth streams; the D435i only accepts `6`, `15` or `30` at these resolutions. The first knob to lower on a loaded controller, since every consumer scales with it. On the dev laptop `6` with `ROVER_CAMERA_FIDUCIALS_DECIMATE=4.0` cut the stack from 20.6 % to 7.0 % of one core. |
| `ROVER_CAMERA_DEPTH_PROFILE` | `424x240` | sensors | Depth resolution. The point cloud, and with it the Nav 2 costmap work (with `ROVER_NAV_USE_CAMERA`), grows with the pixel count: `424x240` is about 100 k points, `848x480` four times that. |
| `ROVER_CAMERA_FIDUCIALS_DECIMATE` | `2.0` | sensors | AprilTag image decimation; higher is cheaper and detects at shorter range. About half a core on a Pi 5 at 15 fps and `2.0` (estimate). |
| `ROVER_CAMERA_DETECTION_MAX_RATE` | `10.0` | sensors | Upper bound on detections per second (Hz). Use `2`-`3` on a CPU-only controller. The input resolution comes from the exported `.onnx` model, so export a 320 px model for a cheaper detector. |
| `ROVER_FOXGLOVE_TOPIC_WHITELIST` | *(unset)* | platform | `foxglove_bridge`'s `topic_whitelist`. Unset: only the topics the drive UI uses (listed in `rover_bringup/launch/rover_web_bridges.launch.py`), because anything a browser subscribes to crosses the Zenoh router at full rate. Set `['.*']` to see the whole graph in Foxglove Studio while debugging. |
| `ROVER_FOXGLOVE_SERVICE_WHITELIST` | *(unset)* | platform | `foxglove_bridge`'s `service_whitelist`. Unset: only the services the drive UI calls (listed in `rover_bringup/launch/rover_web_bridges.launch.py`). Otherwise the bridge advertises every service on the graph and logs a warning for each one whose package isn't in the platform image (slam_toolbox, the voxel layer). A UI can only call a service the bridge advertises. Set `['.*']` to reach every service from Foxglove Studio while debugging. |
| `ROVER_LAN_IP` | `192.168.1.201` | zenoh-router | Rover LAN address the Zenoh router binds. Not in `docker-compose.yml`; set it in balenaCloud to change it. |
| `ROVER_LOCALIZATION_SOURCE` | *(unset)* | orchestrator | Optional. `odom`, `gps`, `slam`, `amcl` or `indoor`, overriding the `ROVER_USE_GPS` mapping. `slam` (slam_toolbox), `amcl` (nav2_amcl) and `indoor` all require `ROVER_USE_GPS=false` or `ROVER_GPS_PUBLISH_MAP_TF=false` — exactly one process may publish `map → odom`. `amcl` localizes on a fixed `ROVER_NAV_MAP` and needs `ROVER_USE_LIDAR=true`. **`indoor`** is the mode for the [drive interface](#drive-interface): `rover_indoor_nav_manager` runs slam_toolbox while you record a map and map_server + AMCL on a saved one, switching at runtime; maps, places and the last pose live in the `rover-maps` volume (`/maps/<name>/`), and `ROVER_NAV_MAP` / `ROVER_AMCL_INITIAL_POSE_*` are ignored. An unrecognized value is ignored with a warning. |
| `ROVER_NAV_MAP` | *(unset)* | orchestrator | Optional path to a map yaml inside the container; defaults to `rover_navigation`'s `empty_world.yaml`. **Required with `ROVER_LOCALIZATION_SOURCE=amcl`** — AMCL cannot localize against the empty default, so build a map with `=slam` first and point this at `/maps/map.yaml`. |
| `ROVER_AMCL_INITIAL_POSE_X` / `_Y` / `_YAW` | `0.0` | orchestrator | Pose AMCL is seeded with at startup, in the map frame. The default is correct only when the map origin is where the rover parks, i.e. the slam run started there. Find it with `ros2 run tf2_ros tf2_echo rover/map rover/base_link`. |

### Sensor mount poses

Read by `rover_description` in `rover-a1-platform`, relative to `body_link`
(x forward, y left, z up). Declared in `docker-compose.yml` but left **unset**, so the URDF
defaults apply until a balenaCloud variable defines one. A non-numeric value is ignored with a
warning in `/tmp/rover_bringup.log`.

| Variable | Default |
|----------|---------|
| `ROVER_IMU_LOCALIZATION_X` / `_Y` / `_Z` [m] | `-0.09` / `0.0` / `0.2` |
| `ROVER_IMU_ORIENTATION_R` / `_P` / `_Y` [rad] | `0` |
| `ROVER_GPS_LOCALIZATION_X` / `_Y` / `_Z` [m] | `0` |
| `ROVER_GPS_ORIENTATION_R` / `_P` / `_Y` [rad] | `0` |
| `ROVER_LIDAR_LOCALIZATION_X` / `_Y` / `_Z` [m] | `0` |
| `ROVER_LIDAR_ORIENTATION_R` / `_P` / `_Y` [rad] | `0` |
| `ROVER_CAMERA_LOCALIZATION_X` / `_Y` / `_Z` [m] | `0.25` / `0.0` / `0.2` (assumed, not measured) |
| `ROVER_CAMERA_ORIENTATION_R` / `_P` / `_Y` [rad] | `0` |

```bash
balena env set ROVER_START_ROS_PLATFORM false --device <device-uuid> --service rover-a1-platform
balena env set ROVER_START_NAVIGATION true --device <device-uuid> --service rover-a1-orchestrator
```

Changing a variable restarts the affected containers automatically, and `start.sh` re-reads
the value on the next start. There is no image rebuild, but expect roughly 15–30 s of downtime
for `rover-a1-platform`, with its web bridges down during that time. A variable scoped to one
service restarts only that service; an all-services device variable restarts every service.

Note that `ROVER_START_ROS_PLATFORM` is read by two services. Scoping it to `rover-a1-platform`
alone stops the bringup but leaves the orchestrator believing it is still running — set it as
an all-services variable, or set `ROVER_START_NAVIGATION=false` alongside it.
`ROVER_USE_GPS` is read by three services (sensors: driver, platform: fusion, orchestrator:
`localization_source`); set it as an all-services variable so they agree.

With the defaults only `rover-a1-platform` runs its stack; the orchestrator and the sensor
payload idle until `ROVER_START_NAVIGATION` / `ROVER_START_SENSORS` are set to `true`.

## Where the orchestrator runs

`rover-a1-orchestrator` holds the autonomy stack from
[`rover_orchestrator`](https://github.com/RaduPotlog/rover_orchestrator): `rover_navigation`
(Nav 2 configuration — costmaps, MPPI controller, Smac 2D planner, behavior trees, map
server, SLAM map autosaver) and `rover_mission_manager` (behavior-tree mission supervision
dispatching Nav 2 actions).

It also holds `rover_drive_mode`, the driving modes the drive UI switches between (Manual,
Assisted, Automatic). That starts whenever `ROVER_START_ROS_PLATFORM` and
`ROVER_START_DRIVE_MODE` (default `true`) are both true, independent of Nav 2, because the drive
UI's joystick reaches the platform only through it. Nav 2 starts only when **both** hold:

| `ROVER_START_ROS_PLATFORM` | `ROVER_START_NAVIGATION` | Result |
|---|---|---|
| `true` | `true` | Nav 2 starts (+ mission manager with `ROVER_START_MISSION_MANAGER=true`) |
| `true` | `false` | drive modes only — Manual and Assisted work, Automatic is refused. When a companion controller runs the stack, run `rover_drive_mode` on exactly one of the two devices (`ROVER_START_DRIVE_MODE=false` on the other): two managers would both route the joystick |
| `false` | *any* | idle — no platform bringup to drive or navigate with |

The table assumes `ROVER_START_DRIVE_MODE=true` (the default). With it `false`, the second row
idles too, and the first runs Nav 2 without driving modes: the drive UI cannot drive, and the
mission manager refuses every mission, because nothing ever reports AUTOMATIC.

When idle the container does **not** exit — it sleeps, so `restart: always` cannot crash-loop
it, and the balena logs carry a single line naming the reason. sshd starts ahead of that
gate, so an idle container is still reachable on 24 — which is when a shell tends to be
most useful. Changing any of the variables restarts the container, which re-evaluates them.

To run the stack on a companion controller, leave `ROVER_START_NAVIGATION=false` on the rover,
then build and run `rover_autonomy` on the companion computer and join the rover's Zenoh
router over the rover LAN (see [ROS 2 over the rover LAN](#ros-2-over-the-rover-lan-zenoh)). Keep `ROVER_NAMESPACE` and the
chosen `localization_source` identical on both sides.

The container runs no Zenoh router of its own: host networking puts it in the same network
namespace as `rover-a1-zenoh-router`, so `rmw_zenoh_cpp` connects to `tcp/127.0.0.1:7447`.
`start.sh` waits up to 60 s for that port before launching (`depends_on` orders the start, but
not readiness).

## VDA 5050

`rover-a1-vda5050` connects Rover A1 to a VDA 5050 **2.0** master control over MQTT. The code lives
in [`rover_vda5050`](https://github.com/RaduPotlog/rover_vda5050): InOrbit's open-source
connector ([`ros_amr_interop`](https://github.com/inorbit-ai/ros_amr_interop), vendored as a git
subtree with a short list of patches) plus the rover's adapter plugins. Orders become
`rover_mission_manager` missions, so every guard GoTo has applies to them too: the Automatic
driving mode, the motion lock, a dead lidar, low battery. See that repository's README for the
supported actions, the state mapping and how to test with its `fake_master.py`.

Enable it with `ROVER_START_VDA5050=true` on a rover that also runs
`ROVER_START_NAVIGATION=true` and `ROVER_START_MISSION_MANAGER=true`, then put the rover in
Automatic from the drive UI. Master control publishes to `uagv/v2/<manufacturer>/<serial>/order`
on the rover's broker (port 1883), or on its own broker with `ROVER_VDA5050_LOCAL_BROKER=false` and
`ROVER_VDA5050_BROKER_HOST`. SSH: `ssh -p 26 root@<rover-lan-ip>`; the connector logs to
`/tmp/rover_vda5050.log`, Mosquitto to `/tmp/rover_mosquitto.log`.

The rover's broker is anonymous and unencrypted: fine on the rover LAN, not beyond it.

## Follow-me

`rover-a1-follow-me` runs [`rover_follow_me`](https://github.com/RaduPotlog/rover_follow_me): a
follow-me algorithm tracks a person (`fmoc`, a Python port of Intel's ADBSCAN follow-me clustering
on the RealSense depth cloud), and the `follow_me` node runs following as one `FollowObject` goal
of Nav 2's Following server, which runs with Nav 2 in `rover-a1-orchestrator`. The server keeps
1.2 m from the person, turning to face them, and its velocity goes through the velocity smoother,
the collision monitor, drive mode and the motion lock like any Nav 2 motion; follow-me never
publishes `cmd_vel`.

Enable it with `ROVER_START_FOLLOW_ME=true` and `ROVER_USE_CAMERA=true` on a rover that runs Nav 2
and the mission manager, in Automatic. Stand about 1.5 m in front of the stopped rover, then start
following from the drive UI (Navigate tab, *Follow me*), with the VDA 5050 instant action
`startFollowing` from fleet control, or with
`ros2 service call /rover/follow_me/start std_srvs/srv/Trigger`. Following stops on
`follow_me/stop` (or `stopFollowing`), when the rover leaves Automatic, when a mission starts, and
when the Following server gives up searching for a lost person. `follow_me/status` says what it is
doing. SSH: `ssh -p 27 root@<rover-lan-ip>`; logs in `/tmp/rover_follow_me.log`.

## ROS namespace

`rover-a1-platform` runs every rover node under the namespace in `ROVER_NAMESPACE`
(default `rover`, set in `docker-compose.yml`, overridable as a balenaCloud
variable), so rover topics and services are `/rover/cmd_vel`,
`/rover/odom`, `/rover/led/state`, `/rover/hardware_interface/gpio_state`, …
and TF frames are `rover/odom`, `rover/base_link`. `/tf`, `/tf_static`,
`/rosout` and `/parameter_events` stay global, as do the web bridges
(`/rosapi/*`, `/client_count`). `rover-a1-orchestrator` and
`rover-a1-sensors` read the same variable as the platform, so change it on all three together — an
all-services balenaCloud variable is the safe way to do that.

## ROS 2 over the rover LAN (Zenoh)

The ROS 2 graph runs on `rmw_zenoh_cpp`. The Zenoh router runs in its own service,
`rover-a1-zenoh-router`, as that container's only process. A platform restart or a balena
release that doesn't touch its image leaves it (and so the graph) up. It listens on loopback
and on the rover LAN address only (default `192.168.1.201`, override with the balenaCloud
variable `ROVER_LAN_IP`). balenaVPN and GSM are deliberately not bound. The router has no
authentication, so any host on the rover LAN can join the graph. It is configured with
`ZENOH_CONFIG_OVERRIDE` on top of `rmw_zenoh_cpp`'s packaged router defaults, not with a json5
file, which would replace those defaults wholesale.

If the LAN address isn't on the device within ~10 s of startup, the router
falls back to loopback-only (logged as a `WARNING`) until the container
restarts.

The rover mixes the two ways a ROS process can join Zenoh, per container
(`ROVER_ZENOH_MODE`):

- **`rover-a1-platform`: `peer`** (rmw_zenoh's default). Its processes link directly to each
  other, so the control loops (IMU → EKF, `cmd_vel` → twist_mux → ros2_control, safety) never
  wait on the router. They also link to the router, for everything crossing containers.
- **`rover-a1-orchestrator`, `rover-a1-sensors`: `client`.** One TCP link each, to the router,
  which carries all their traffic. These are the containers whose processes come and go (Nav 2
  restarts, indoor mapping ↔ localization switches). When a group of clients stops, only the
  router cleans up after it, not every process on the rover.

Why the split, measured on the rover on 2026-09-26. After an orchestrator restart the router
spends up to a minute at 100 % of one core cleaning up. It forwards nothing meanwhile.

| Setup | Platform topics (`imu/data`, `odom`, `/tf`) during an orchestrator restart |
|---|---|
| All peers (the old default) | 1–4 s stalls; ~600 loopback links |
| All clients | stopped for 31–58 s |
| Platform peers, the rest clients | worst gap 0.15 s; 0.13 s over six mapping ↔ localization switches |

Traffic between containers still waits on the router during such a restart (`scan` into Nav 2,
Nav 2's `cmd_vel`), which only matters while navigation is down anyway.

`start.sh` exports the client settings as `ZENOH_CONFIG_OVERRIDE` for everything it launches in
client mode:

- `connect/timeout_ms=-1`: a process started before the router waits for it rather than
  aborting with `RCLBadAlloc` (peers wait by default).
- `connect/retry` backs off from 0.5 s to 2 s, so after a router restart every process
  reconnects and re-declares its publishers and subscriptions. Platform peers keep talking to
  each other meanwhile; cross-container traffic resumes when the router is back.

`ros2` in an SSH shell is always a client, with a 5 s timeout, in every container: a command
fails fast while the router is down and stays out of the platform's mesh. `.bashrc` sources it
from `/tmp/rover_zenoh_cli.env`, which `start.sh` writes. Count the links with
`awk 'FNR>1 && $4=="01"' /proc/net/tcp /proc/net/tcp6 | wc -l`: about 390 socket ends with the
default split, and 70 if every process were a client.

To join from a LAN host running ROS 2 Lyrical with `rmw_zenoh_cpp`, run a local
router that dials the rover, then start nodes as usual:

```bash
# on the LAN host
source /opt/ros/lyrical/setup.bash
cat > ~/rover_router.json5 << 'CFG'
{
  mode: "router",
  listen:  { endpoints: ["tcp/127.0.0.1:7447"] },
  connect: { endpoints: ["tcp/192.168.1.201:7447"] },
  scouting: { multicast: { enabled: false } }
}
CFG
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
ZENOH_ROUTER_CONFIG_URI=~/rover_router.json5 ros2 run rmw_zenoh_cpp rmw_zenohd &
ros2 topic list   # in another shell with RMW_IMPLEMENTATION set
```

`ROS_DOMAIN_ID` must match on both sides (the rover uses the default, `0`).

## Remote access over WireGuard

For remote work, SSH, the web UIs, Foxglove and MQTT reach the controller through a WireGuard
VPN. Nothing VPN-related runs on the device. The RUTX11 is a WireGuard peer and routes into
the rover LAN, so the controller is reached at its usual LAN address, `192.168.1.201`.

```
laptop 10.8.0.4 ──wg──> server 10.8.0.1 ──wg──> RUTX11 10.8.0.5 ──firewall──> controller 192.168.1.201
```

- **Server** (`/etc/wireguard/wg0.conf`): the RUTX11 peer has
  `AllowedIPs = 10.8.0.5/32, 192.168.1.0/24`, and `PostUp` allows forwarding `wg0 → wg0`.
- **RUTX11**: interface `wg0`, peer `roverser`. Its settings:
  - Split tunnel: `allowed_ips=10.8.0.0/24`, so the rover's internet traffic doesn't go through
    the server.
  - `route_allowed_ips=1`, which gives the controller's replies a way back. The controller's
    default route is the RUTX11.
  - `mtu=1380`, `persistent_keepalive=25`.
- **Laptop peer**: `AllowedIPs = 10.8.0.0/24, 192.168.1.201/32`, `MTU = 1380`. Turn the tunnel
  off while on the rover LAN or AP, or rover traffic hairpins through the server.

The RUTX11 firewall zone `wireguard` lets only the laptop (`10.8.0.4`) through, and only to
these ports on `192.168.1.201`:

| Port | Service |
|---|---|
| 22–26 | SSH into the containers |
| 80, 5000 | Drive UI (`ROVER_DRIVE_PORT`; the fleet variable sets 80) |
| 5080 | Uplink page |
| 8765 | foxglove_bridge |
| 1883, 9001 | MQTT, MQTT over WebSockets |
| ICMP echo | ping |

The router itself answers ping, SSH (22) and HTTPS (443) on `10.8.0.5`. A final rule,
`VPN-reject-everything-else`, rejects the rest, Zenoh 7447 and rosbridge 9090 included. It is
required: RutOS's default forward policy is ACCEPT, and the zone's `forward=REJECT` only covers
traffic leaving `wg0`. To let in another VPN peer or port, copy a `VPN-laptop-ctrl-*` rule and
`uci reorder` it before the reject.

On the SIM uplink, keep data down:

- Foxglove sends exactly what a panel subscribes to. Leave point clouds, images and costmaps
  closed.
- Subscribe MQTT to specific topics, not `#`.
- Deploy (`balena push` image pulls) only on Wi-Fi.
