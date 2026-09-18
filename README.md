# rover_docker

Docker files to build the ARM64 balena application release for the Rover A1.
The application uses ROS 2 Lyrical on Ubuntu 26.04; the balenaOS host image
is managed separately.

Four services are deployed to the balenaCloud fleet `g_potlog_radu/rovera1`.
Each has its own folder holding its Dockerfile and any scripts, which is the
service's build context in `docker-compose.yml`:

| Service            | Folder              | Contents                                                                   |
|--------------------|---------------------|----------------------------------------------------------------------------|
| `rover-a1-platform`      | `rover_a1_platform/`      | Ubuntu 26.04 + ROS 2 Lyrical + rover firmware (sshd, Zenoh router, `rover_bringup`, rosbridge, foxglove_bridge); `start.sh` is the entrypoint |
| `rover-a1-orchestrator` | `rover_a1_orchestrator/` | Ubuntu 26.04 + ROS 2 Lyrical + [`rover_orchestrator`](https://github.com/RaduPotlog/rover_orchestrator) — the autonomy stack (Nav 2 via `rover_navigation`, plus `rover_mission_manager`), plus an sshd on port 2222 and the Claude Code CLI with `ros-mcp` registered; `start.sh` is the entrypoint. Idle unless enabled, see [Where the orchestrator runs](#where-the-orchestrator-runs) |
| `rover-cockpit`    | `rover_cockpit/`    | Cockpit + [`rover_cockpit_ros2_diagnostics`](https://github.com/RaduPotlog/rover_cockpit_ros2_diagnostics) — ROS 2 Diagnostics / Networking / LEDs web page on port 80 (no ROS inside; the browser talks to foxglove_bridge, and the Networking tab pings the rover's devices) |

```
rover_docker/
├── docker-compose.yml
├── rover_a1_platform/
│   ├── Dockerfile
│   └── start.sh
├── rover_a1_orchestrator/
│   ├── Dockerfile
│   └── start.sh
└── rover_cockpit/
    ├── Dockerfile
    ├── cockpit.conf
    └── start.sh
```

## Build and validate for ARM64

Run commands from `rover_docker/`. Use a Docker Buildx builder that supports
`linux/arm64`, either natively or through emulation. In WSL, enable Docker
Desktop integration for the distribution first.

```bash
bash -n rover_a1_platform/start.sh
bash -n rover_a1_orchestrator/start.sh
bash -n rover_cockpit/start.sh
docker compose config --quiet
docker buildx inspect --bootstrap
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rover-a1-platform:lyrical ./rover_a1_platform
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rover-a1-orchestrator:lyrical ./rover_a1_orchestrator
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rover-cockpit:lyrical ./rover_cockpit
```

The application build defaults to the `rover_ros` **master** branch and
imports its `hardware_deps.repos`, including the receiver and transport
dependencies. `ROS_DISTRO=lyrical` is baked into the image and
used for package installation, rosdep, compilation, and startup; do not
override it with a different distribution at runtime.

The orchestrator build is the slow one. Besides the workspace itself it
compiles `nav2_smac_planner` from source — `planner_server`'s `GridBased`
plugin, and the only `nav2_*` package with no arm64 binary on
lyrical/resolute. `autonomy_deps.repos` pins it at tag `1.5.1` of
[`rover_navigation`](https://github.com/RaduPotlog/rover_navigation), our
navigation2 fork, to match the Nav 2 debs, and the Dockerfile prunes that import to the single
package with `git sparse-checkout`. Budget roughly eight extra minutes on
arm64; the build is not stuck. Its `ros2 pkg prefix` below must report the
workspace install tree, not `/opt/ros/lyrical`.

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
are never compiled there. Check it the same way:

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
and `rover_cockpit_ros2_diagnostics` respectively). Those
clones sit in cached layers, so a plain `balena push` will happily ship stale application
code.

Select specific application commits instead of branch tips with:

```bash
balena push g_potlog_radu/rovera1 \
  --build-arg ROVER_ROS_REF=<sha> \
  --build-arg ROVER_ORCHESTRATOR_REF=<sha> \
  --build-arg ROVER_COCKPIT_REF=<sha>
```

`ROVER_ROS_REF` is consumed by both `rover-a1-platform` and `rover-a1-orchestrator`, so the
two stay on the same `rover_ros` commit.

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
| 2222   | sshd (`rover-a1-orchestrator`)       |
| 80     | Cockpit: ROS 2 Diagnostics / Networking / LEDs (`rover-cockpit`, plain http) |
| 7447   | Zenoh router (loopback + rover LAN only, see below) |
| 8765   | foxglove_bridge                |
| 9090   | rosbridge websocket (ros-mcp-server only; dashboards use 8765) — served by `rover-a1-platform`, used by the `ros-mcp` in **both** ROS services |
| 48484  | balena supervisor              |

`rover-a1-orchestrator` opens one port of its own, 2222, for its sshd — 22 belongs to
`rover-a1-platform`, and host networking gives the two containers a single port space. It
runs **no Zenoh router** of its own, joining the existing one on 7447 as a session (see
[ROS 2 over the rover LAN](#ros-2-over-the-rover-lan-zenoh)).

That sshd takes the same credentials as `rover-a1-platform`'s — root password login, baked
into the image. Only the port differs: `ssh -p 2222 root@<rover-lan-ip>`. See
[Orchestrator SSH](#orchestrator-ssh).

## Orchestrator SSH

`rover-a1-orchestrator` runs its own sshd on **2222**, configured in the image
(`rover_a1_orchestrator/Dockerfile`) exactly as `rover-a1-platform`'s is on 22 — `root:root`,
`PermitRootLogin yes`, `UsePAM no` — through a `/etc/ssh/sshd_config.d/` drop-in.

```bash
ssh -p 2222 root@<rover-lan-ip>     # orchestrator: Nav 2 + mission manager
ssh root@<rover-lan-ip>             # platform: drivers, Zenoh router, bringup
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

Neither is a regression — it is the arrangement port 22 has always had — but 2222 doubles the
surface, so it is worth stating.

### Claude Code on the 2222 shell

The orchestrator image carries the same Claude tooling as `rover-a1-platform` — the
`@anthropic-ai/claude-code` CLI plus `ros-mcp`, registered at user scope at build time — so
`claude` works identically on either shell. Run it from the 2222 session when the thing you
are debugging is Nav 2, the costmaps or the mission manager.

- **One-time login.** `claude` prompts for authentication on first run. The credential is
  written to `/root/.claude.json` **inside the container**, so it does not survive a container
  recreate — every balena release means logging in again. If that friction bites, declare an
  unset `ANTHROPIC_API_KEY` on both ROS services in `docker-compose.yml` and set it as a
  balenaCloud variable instead.
- **ros-mcp needs `rover-a1-platform` running.** It reaches rosbridge at `127.0.0.1:9090`,
  which is served by that container — host networking gives the two services one namespace,
  which is why the orchestrator runs no rosbridge of its own. With the platform stopped,
  `claude mcp list` shows ros-mcp failing to connect.

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
  `rover-cockpit` (required — the container exits without it). The user name is
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
| `ROVER_START_ROS_PLATFORM` | `true` | platform, orchestrator | `false` skips `ros2 launch rover_bringup rover_bringup.launch.py`. Zenoh, sshd and the web bridges still run. The orchestrator also stays idle, since there is no platform to drive. |
| `ROVER_START_NAVIGATION` | `false` | orchestrator | `true` starts the autonomy stack (`rover_navigation` → Nav 2) on this device. Requires `ROVER_START_ROS_PLATFORM=true`. Leave `false` when a companion controller runs the stack. |
| `ROVER_START_MISSION_MANAGER` | `true` | orchestrator | `false` runs Nav 2 without `rover_mission_manager`. Only consulted when the orchestrator stack starts at all. |

### Robot configuration

| Variable | Default | Read by | Effect |
|----------|---------|---------|--------|
| `ROVER_NAMESPACE` | `rover` | all | ROS namespace (see [ROS namespace](#ros-namespace)). Keep it equal across services. |
| `ROVER_USE_GPS` | `false` | platform, orchestrator | Localization mode. `false`: EKF on wheel odometry + IMU. `true`: also fuses the RUTX11 GPS (`rover_gps` heading alignment, `navsat_transform`, global EKF publishing `map → odom`). The GPS driver and its diagnostics run in both modes. In the orchestrator it selects Nav 2's `localization_source` (`gps` vs `odom`). |
| `ROVER_USE_LIDAR` | `false` | platform, orchestrator | Starts the RoboSense RS16 driver. Leave `false` on rovers with no lidar fitted. The orchestrator logs a warning when it is false: both Nav 2 costmaps mark and clear from `<namespace>/scan`, so navigation would drive blind. |
| `ROVER_LAN_IP` | `192.168.1.201` | platform | Rover LAN address the Zenoh router binds. |
| `ROVER_LOCALIZATION_SOURCE` | *(unset)* | orchestrator | Optional. `odom`, `gps` or `slam`, overriding the `ROVER_USE_GPS` mapping. `slam` (slam_toolbox) requires `ROVER_USE_GPS=false` — exactly one process may publish `map → odom`. An unrecognized value is ignored with a warning. |
| `ROVER_NAV_MAP` | *(unset)* | orchestrator | Optional path to a map yaml inside the container; defaults to `rover_navigation`'s `empty_world.yaml`. |

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
| `ROVER_COCKPIT_PASSWORD` | *(unset)* | cockpit | Required — `rover-cockpit` exits with an error without it. |
| `ROVER_COCKPIT_PORT` | `80` | cockpit | Port the Cockpit web console binds (plain http). |

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

## Where the orchestrator runs

`rover-a1-orchestrator` holds the autonomy stack from
[`rover_orchestrator`](https://github.com/RaduPotlog/rover_orchestrator): `rover_navigation`
(Nav 2 configuration — costmaps, MPPI controller, Smac 2D planner, behavior trees, map
server, SLAM map autosaver) and `rover_mission_manager` (behavior-tree mission supervision
dispatching Nav 2 actions).

It starts that stack only when **both** hold:

| `ROVER_START_ROS_PLATFORM` | `ROVER_START_NAVIGATION` | Result |
|---|---|---|
| `true` | `true` | Nav 2 starts (+ mission manager unless `ROVER_START_MISSION_MANAGER=false`) |
| *any* | `false` | idle — navigation not requested on this device (also the setting when a companion controller runs the stack) |
| `false` | `true` | idle — no platform bringup to navigate with |

When idle the container does **not** exit — it sleeps, so `restart: always` cannot crash-loop
it, and the balena logs carry a single line naming the reason. sshd starts ahead of that
gate, so an idle container is still reachable on 2222 — which is when a shell tends to be
most useful. Changing any of the variables restarts the container, which re-evaluates them.

To run the stack on a companion controller, leave `ROVER_START_NAVIGATION=false` on the rover,
then build and run `rover_autonomy` on the companion computer and join the rover's Zenoh
router over the rover LAN (see [ROS 2 over the rover LAN](#ros-2-over-the-rover-lan-zenoh)). Keep `ROVER_NAMESPACE` and the
chosen `localization_source` identical on both sides.

The container runs no Zenoh router of its own: host networking puts it in the same network
namespace as `rover-a1-platform`, so `rmw_zenoh_cpp` connects to `tcp/127.0.0.1:7447`.
`start.sh` waits up to 60 s for that port before launching, because balena does not order
service startup.

## ROS namespace

`rover-a1-platform` runs every rover node under the namespace in `ROVER_NAMESPACE`
(default `rover`, set in `docker-compose.yml`, overridable as a balenaCloud
variable), so rover topics and services are `/rover/cmd_vel`,
`/rover/odom`, `/rover/led/state`, `/rover/hardware_interface/gpio_state`, …
and TF frames are `rover/odom`, `rover/base_link`. `/tf`, `/tf_static`,
`/rosout` and `/parameter_events` stay global, as do the web bridges
(`/rosapi/*`, `/client_count`). `rover-a1-orchestrator` and
`rover-cockpit` read the same variable, so change it on all three services together — an
all-services balenaCloud variable is the safe way to do that.

## ROS 2 over the rover LAN (Zenoh)

The ROS 2 graph runs on `rmw_zenoh_cpp`. The Zenoh router in `rover-a1-platform`
listens on loopback and on the rover LAN address only (default
`192.168.1.201`, override with the balenaCloud variable `ROVER_LAN_IP`).
balenaVPN and GSM are deliberately not bound. The router has no
authentication, so any host on the rover LAN can join the graph.

If the LAN address isn't on the device within ~10 s of startup, the router
falls back to loopback-only (logged as a `WARNING`) until the container
restarts.

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
