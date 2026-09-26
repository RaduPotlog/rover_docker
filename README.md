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
| `rover-cockpit`    | `rover_cockpit/`    | Cockpit + [`rover_cockpit_ros2_diagnostics`](https://github.com/RaduPotlog/rover_cockpit_ros2_diagnostics) — ROS 2 Diagnostics / Networking / LEDs web page on port 80 (no ROS inside; the browser talks to foxglove_bridge, and the Networking tab pings the rover's devices), plus an sshd on port 26 and the Claude Code CLI with `ros-mcp` registered |
| `rover-a1-drive-interface` | `rover_a1_drive_interface/` | nginx + [`rover_drive_interface`](https://github.com/RaduPotlog/rover_drive_interface) — Boxer / IndoorNav-style drive UI on port 5000 behind a login; nginx proxies `/ws` to foxglove_bridge (no ROS inside). Plus an sshd on port 25 and the Claude Code CLI with `ros-mcp` registered. See [Drive interface](#drive-interface) |

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
├── rover_cockpit/
│   ├── Dockerfile
│   ├── cockpit.conf
│   ├── healthcheck.sh
│   └── start.sh
└── rover_a1_drive_interface/
    ├── Dockerfile
    ├── nginx.conf.template
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
bash -n rover_cockpit/start.sh
bash -n rover_cockpit/healthcheck.sh
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
  -t rover-cockpit:lyrical ./rover_cockpit
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
Start the Cockpit
image with `-e ROVER_COCKPIT_PASSWORD=<test> --network host`, check
`curl -fsS http://127.0.0.1/ping`, and log in at `http://localhost/`;
without `ROVER_COCKPIT_PASSWORD` it must exit with an error. On the rover,
verify hardware bringup, the LAN Zenoh connection, and bridge ports after
deployment. A successful image build alone does not validate hardware.

Through the balenaCloud Public Device URL, balena's proxy terminates TLS, so
Cockpit takes the https scheme from its `X-Forwarded-Proto` header
(`ProtocolHeader` in `cockpit.conf`). If login still ends in "Connection
failed" (`bad Origin` in the `rover-cockpit` log), set `ROVER_COCKPIT_ORIGINS`
to the space-separated list of allowed origins; it replaces Cockpit's default,
so include the LAN origins you use too. The Cockpit container also runs its own
private system D-Bus (not the host's): without one, `cockpit-bridge` crashes on
a page reload and the session ends in "Connection failed".

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
`rover_sensors`; and `rover_cockpit_ros2_diagnostics` respectively). Those
clones sit in cached layers, so a plain `balena push` will happily ship stale application
code.

> **Temporary branch defaults (Clean Architecture + Zenoh client mode).** On the
> `rover-clean-arch-ultra-code-effort-01` branch of this repo, the Dockerfiles default `ROVER_ROS_REF`
> (platform and orchestrator, kept equal), `ROVER_ORCHESTRATOR_REF`, `ROVER_SENSORS_REF` and
> `ROVER_COCKPIT_REF` to `rover-clean-arch-ultra-code-effort-01` instead of `master`, and
> rover_orchestrator's branch of that name points `autonomy_deps.repos` at the same branch of
> rover_pointcloud_crop_box. In rover_ros that branch carries the Clean Architecture fixes with
> `rover_zenoh_improvements` merged in; in the other repositories it starts at their
> `rover_zenoh_improvements` tip. All of those branches must exist on GitHub before a build. Set the
> defaults back to `master` once they are merged.

Select specific application commits instead of branch tips with:

```bash
balena push g_potlog_radu/rovera1 \
  --build-arg ROVER_ROS_REF=<sha> \
  --build-arg ROVER_ORCHESTRATOR_REF=<sha> \
  --build-arg ROVER_SENSORS_REF=<sha> \
  --build-arg ROVER_COCKPIT_REF=<sha>
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
| 26     | sshd (`rover-cockpit`)               |
| 80     | Cockpit: ROS 2 Diagnostics / Networking / LEDs (`rover-cockpit`, plain http) |
| 5000   | Drive interface (`rover-a1-drive-interface`, plain http, basic-auth login; `/ws` is proxied to 8765) |
| 7447   | Zenoh router (`rover-a1-zenoh-router`; loopback + rover LAN only, see below) |
| 8765   | foxglove_bridge                |
| 9090   | rosbridge websocket (ros-mcp-server only; dashboards use 8765) — served by `rover-a1-platform`, used by the `ros-mcp` in **every** container |
| 10110/udp | RUTX11 NMEA forwarding → GNSS driver (`rover-a1-sensors`) |
| 6699/udp, 7788/udp | RoboSense RS16 MSOP / DIFOP → lidar driver (`rover-a1-sensors`) |
| 48484  | balena supervisor              |

Host networking gives every container a single port space, so each sshd has its own port —
platform **22**, sensors **23**, orchestrator **24**, drive-interface **25**, cockpit **26**.
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
ssh -p 26 root@<rover-lan-ip>       # 26  cockpit
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
drive-interface 25 and cockpit 26. Use the shell of the container you are debugging:
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

## Cockpit SSH

`rover-cockpit` runs its own sshd on **26** — the same `root:root` drop-in arrangement as the
others. It is a root maintenance shell, separate from Cockpit's own web login
(`ROVER_COCKPIT_USER` on port 80, which refuses root).

```bash
ssh -p 26 root@<rover-lan-ip>       # cockpit: cockpit-ws, /etc/cockpit, the private D-Bus
```

`start.sh` starts sshd first and supervises it together with `cockpit-ws`; if either exits the
container restarts. Without `ROVER_COCKPIT_PASSWORD` (or with `ROVER_COCKPIT_USER=root`) the
container now **idles** with only sshd running instead of exiting, and leaves
`/tmp/rover-cockpit-idle`, which the healthcheck accepts, so the shell stays reachable to fix it.
It carries `claude` and `ros-mcp` like every other container.

## ROS 2 diagnostics (Cockpit)

`rover-cockpit` serves the Cockpit web console with only the
[ROS 2 diagnostics plugin](https://github.com/RaduPotlog/rover_cockpit_ros2_diagnostics)
installed. Open `http://<rover-lan-ip>/` (e.g. `http://192.168.1.201/`; Cockpit
listens on port 80, plain http, no TLS for now), log in, and the diagnostics page
opens directly. It replaces the former `rover-web-server` dashboard. It has three tabs:

- **ROS 2 Diagnostics** (`#/`) — the aggregated diagnostics tree (below).
- **ROS 2 Networking** (`#/networking`) — ICMP status, round-trip time and 60-probe
  history of every interface in the rover topology, pinged every 5 s by `ping` in
  the `rover-cockpit` container (host network, `CAP_NET_RAW`) while the tab is open.
  The device list and topology are compiled into the plugin
  (`src/networking/devices.json`, `topology.json`).
- **ROS 2 LEDs** (`#/leds`) — live `rover_led` state through foxglove_bridge
  (`<ns>/led/state`, `<ns>/led/animations`, `<ns>/led/channel_{1,2}_frame`), plus
  controls that call `<ns>/led/set_animation` and `<ns>/led/set_brightness`.
  Any logged-in Cockpit user can use them.

- **Login:** set the balenaCloud service variable `ROVER_COCKPIT_PASSWORD` for
  `rover-cockpit` (required — without it the container idles with only sshd on 26). The user name is
  `ROVER_COCKPIT_USER` (default `rover`; `root` is refused). Both are re-applied on
  every container start.
- **Data path:** the page runs in the browser, but it does not connect to
  foxglove_bridge itself: the Cockpit bridge in `rover-cockpit` opens a TCP stream to
  `127.0.0.1:8765` on the rover (foxglove_bridge in `rover-a1-platform`, same host
  network) and the page speaks the WebSocket protocol over that stream, inside the
  Cockpit session on port 80. It subscribes to
  `/rover/diagnostics_agg` (`<ROVER_NAMESPACE>/diagnostics_agg`; the container
  writes the namespace to `/etc/clearpath/robot.yaml`, where the plugin reads it).
  That topic is published by the `rover_diagnostic_aggregator`
  that `rover_diag_manager`'s `system_diag.launch.py` starts as part of
  `rover_bringup`; its groups are configured in
  `rover_diag_manager/config/diagnostic_aggregator.yaml`.
- **Where it works:** on the rover LAN (`http://<rover-lan-ip>/`) and through the
  balena Public Device URL (`https://<uuid>.balena-devices.com`), since everything
  travels over the one Cockpit connection on port 80. Port 8765 never has to be
  reachable from the browser.
- The container needs no ROS, no Zenoh access and no privileges beyond
  `CAP_NET_RAW` (for the Networking tab's `ping`); if the page shows
  "disconnected", check foxglove_bridge on port 8765 in `rover-a1-platform`
  (`ss -ltnp | grep 8765` on the host).

## Drive interface

`rover-a1-drive-interface` serves a Clearpath Boxer / IndoorNav-style drive UI from
[`rover_drive_interface`](https://github.com/RaduPotlog/rover_drive_interface). Open
`http://<rover-lan-ip>:5000/` (the Boxer's OTTO App and IndoorNav use the same port) and log
in. It is built for one rover and indoor navigation.

- **Transport:** nginx serves the page and proxies the same-origin websocket `/ws` to
  foxglove_bridge on `127.0.0.1:8765`. Both sit behind the same basic-auth login, because
  foxglove_bridge itself has no authentication. The container runs no ROS.
- **Neutral / Manual:** the page starts in **Neutral** and publishes nothing. **Manual**
  publishes `<ns>/teleop_foxglove_cmd_vel_stamped` at 10 Hz (twist_mux priority 100, above
  Nav 2). It sends zeros while the stick is centred, so the UI holds the base.
- **Deadman:** hiding the tab, losing focus or losing the connection stops publishing,
  and twist_mux's 0.5 s timeout stops the rover. Hiding the tab or a lost connection also drops
  the page back to Neutral.
- **Gamepad:** a pad drives only while L1/LB is held.
- **Other controls:** e-stop buttons call the `hardware_interface/sw_*` Trigger services.
- **Top bar:** safety (e-stop, latch, `motion_lock`), diagnostics, battery and
  link latency (a round trip through `/rosapi/get_time`).
- **Map view:** shows the occupancy map, the lidar scan, the Nav 2 plan and the rover. Tools:
  **Set pose** (AMCL `initialpose`) and **Go to** (`rover_mission_manager` `set_mission`), plus
  **Stop**. These need `ROVER_START_NAVIGATION=true` and `ROVER_START_MISSION_MANAGER=true`.
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

- The balena Public Device URL only forwards port 80, which is Cockpit, so the drive
  interface is reachable on the rover LAN only.
- A page served over https would need `wss`; nginx already builds the websocket URL from the
  page scheme, so a TLS proxy in front of port 5000 works unchanged.

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
| `ROVER_START_MISSION_MANAGER` | `false` | orchestrator | `true` also starts `rover_mission_manager` on top of Nav 2. Only consulted when the orchestrator stack starts at all. |
| `ROVER_START_SENSORS` | `false` | sensors | `true` starts the sensor payload in `rover-a1-sensors` (GNSS with `ROVER_USE_GPS`, lidar with `ROVER_USE_LIDAR`). `false` idles the container. It also idles when both `ROVER_USE_GPS` and `ROVER_USE_LIDAR` are false, since there is no driver to run. |

### Robot configuration

| Variable | Default | Read by | Effect |
|----------|---------|---------|--------|
| `ROVER_NAMESPACE` | `rover` | all | ROS namespace (see [ROS namespace](#ros-namespace)). Keep it equal across services. |
| `ROVER_ZENOH_MODE` | platform `peer`, orchestrator and sensors `client` | platform, orchestrator, sensors | How each container's ROS processes join the graph. `peer`: direct links between processes, plus one to the router. `client`: one link each, to `rover-a1-zenoh-router`. The split keeps the platform's control loops independent of the router, which stalls for up to a minute while cleaning up after an orchestrator restart. See [ROS 2 over the rover LAN](#ros-2-over-the-rover-lan-zenoh) before changing it. |
| `ROVER_USE_GPS` | `false` | sensors, platform, orchestrator | One switch for GPS. `true`: `rover-a1-sensors` starts the RUTX11 GNSS driver (`gps/fix`, `GPS fix` diagnostics) and the platform fuses it (`rover_gps_heading` alignment, `navsat_transform`, global EKF; it publishes `map → odom` only with `ROVER_GPS_PUBLISH_MAP_TF=true`). `false`: no GPS driver, EKF on wheel odometry + IMU only. In the orchestrator it selects Nav 2's `localization_source` (`gps` vs `odom`). |
| `ROVER_GPS_PUBLISH_MAP_TF` | `false` | platform, orchestrator | Only matters with `ROVER_USE_GPS=true`. `true`: the global EKF broadcasts `map → odom`. `false`: it keeps fusing GPS and publishing `odometry/global` but leaves `map → odom` to slam_toolbox or AMCL. The orchestrator warns when this is `false` with `localization_source=gps`, since then nothing publishes `map → odom`. Set it as an all-services variable. |
| `ROVER_USE_LIDAR` | `false` | sensors, orchestrator | Starts the RoboSense RS16 driver in `rover-a1-sensors`. Leave `false` on rovers with no lidar fitted. The orchestrator logs a warning when it is false: both Nav 2 costmaps mark and clear from `<namespace>/scan`, so navigation would drive blind. |
| `ROVER_FOXGLOVE_TOPIC_WHITELIST` | *(unset)* | platform | `foxglove_bridge`'s `topic_whitelist`. Unset: only the topics the drive UI and the Cockpit use (listed in `rover_bringup/launch/rover_web_bridges.launch.py`), because anything a browser subscribes to crosses the Zenoh router at full rate. Set `['.*']` to see the whole graph in Foxglove Studio while debugging. |
| `ROVER_FOXGLOVE_SERVICE_WHITELIST` | *(unset)* | platform | `foxglove_bridge`'s `service_whitelist`. Unset: only the services the drive UI and the Cockpit call (listed in `rover_bringup/launch/rover_web_bridges.launch.py`). Otherwise the bridge advertises every service on the graph and logs a warning for each one whose package isn't in the platform image (slam_toolbox, the voxel layer). A UI can only call a service the bridge advertises. Set `['.*']` to reach every service from Foxglove Studio while debugging. |
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

### Cockpit login

| Variable | Default | Read by | Effect |
|----------|---------|---------|--------|
| `ROVER_COCKPIT_USER` | `rover` | cockpit | Cockpit login user. `root` is refused. |
| `ROVER_COCKPIT_PASSWORD` | *(unset)* | cockpit | Required — without it `cockpit-ws` is not started and the container idles (sshd on 26 only), logging an error. |
| `ROVER_COCKPIT_PORT` | `80` | cockpit | Port the Cockpit web console binds (plain http). |
| `ROVER_COCKPIT_DEBUG` | `false` | cockpit | `true` = verbose cockpit-ws / session / bridge logging in the container log (`G_MESSAGES_DEBUG`, `COCKPIT_DEBUG`), to see why a session was closed. Very chatty; leave off normally. |

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

It starts that stack only when **both** hold:

| `ROVER_START_ROS_PLATFORM` | `ROVER_START_NAVIGATION` | Result |
|---|---|---|
| `true` | `true` | Nav 2 starts (+ mission manager with `ROVER_START_MISSION_MANAGER=true`) |
| *any* | `false` | idle — navigation not requested on this device (also the setting when a companion controller runs the stack) |
| `false` | `true` | idle — no platform bringup to navigate with |

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

## ROS namespace

`rover-a1-platform` runs every rover node under the namespace in `ROVER_NAMESPACE`
(default `rover`, set in `docker-compose.yml`, overridable as a balenaCloud
variable), so rover topics and services are `/rover/cmd_vel`,
`/rover/odom`, `/rover/led/state`, `/rover/hardware_interface/gpio_state`, …
and TF frames are `rover/odom`, `rover/base_link`. `/tf`, `/tf_static`,
`/rosout` and `/parameter_events` stay global, as do the web bridges
(`/rosapi/*`, `/client_count`). `rover-a1-orchestrator`,
`rover-a1-sensors` and `rover-cockpit` read the same variable, so change it on all four services together — an
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
