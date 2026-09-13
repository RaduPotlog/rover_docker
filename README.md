# rover_docker

Docker files to build the ARM64 balena application release for the Rover A1.
The application uses ROS 2 Lyrical on Ubuntu 26.04; the balenaOS host image
is managed separately.

Two services are deployed to the balenaCloud fleet `g_potlog_radu/rovera1`.
Each has its own folder holding its Dockerfile and any scripts, which is the
service's build context in `docker-compose.yml`:

| Service            | Folder              | Contents                                                                   |
|--------------------|---------------------|----------------------------------------------------------------------------|
| `rovera1-app`      | `rovera1_app/`      | Ubuntu 26.04 + ROS 2 Lyrical + rover firmware (sshd, Zenoh router, `rover_bringup`, rosbridge, foxglove_bridge); `start.sh` is the entrypoint |
| `rover-web-server` | `rover_web_server/` | [`rover_networking_web_server`](https://github.com/RaduPotlog/rover_networking_web_server) — network monitoring dashboard on port 80 |

```
rover_docker/
├── docker-compose.yml
├── rovera1_app/
│   ├── Dockerfile
│   └── start.sh
└── rover_web_server/
    └── Dockerfile
```

## Build and validate for ARM64

Run commands from `rover_docker/`. Use a Docker Buildx builder that supports
`linux/arm64`, either natively or through emulation. In WSL, enable Docker
Desktop integration for the distribution first.

```bash
bash -n rovera1_app/start.sh
docker compose config --quiet
docker buildx inspect --bootstrap
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rovera1-app:lyrical ./rovera1_app
docker buildx build --platform linux/arm64 --pull --no-cache --load \
  -t rover-web-server:lyrical ./rover_web_server
```

The application build defaults to the `rover_ros` **lyrical** branch and
imports its `hardware_deps.repos`, including the Lyrical receiver and
transport dependencies. `ROS_DISTRO=lyrical` is baked into the image and
used for package installation, rosdep, compilation, and startup; do not
override it with a different distribution at runtime.

Check the built image without starting hardware bringup:

```bash
docker run --rm --platform linux/arm64 --entrypoint /bin/bash \
  rovera1-app:lyrical -ec '
    test "$(dpkg --print-architecture)" = arm64
    test "$ROS_DISTRO" = lyrical
    source /opt/ros/$ROS_DISTRO/setup.bash
    source /root/ros2_ws/rover_a1/install/setup.bash
    for package in rover_bringup rmw_zenoh_cpp rosbridge_server rosapi foxglove_bridge; do
      ros2 pkg prefix "$package"
    done
  '
```

Before deployment, smoke-test `rmw_zenohd`, rosbridge, and Foxglove in an
isolated container with the entrypoint overridden (no hardware bringup),
and check workspace shared libraries with `ldd` for missing dependencies.
Verify the web image's `/healthz` endpoint returns success. On the rover,
verify hardware bringup, the LAN Zenoh connection, and bridge ports after
deployment. A successful image build alone does not validate hardware.

See the [Docker multi-platform build documentation](https://docs.docker.com/build/building/multi-platform/)
for builder setup.

## Deploy

The fleet must use an ARM64 device type. This command builds and deploys
both services to the fleet; local validation above does not deploy them.

```bash
balena push g_potlog_radu/rovera1 --nocache
```

`--nocache` matters: both services fetch their application source with
`git clone` during the build (`rover_ros` and `rover_networking_web_server`
respectively). Those clones sit in cached layers, so a plain `balena push`
will happily ship stale application code.

Select specific application commits instead of branch tips with:

```bash
balena push g_potlog_radu/rovera1 \
  --build-arg ROVER_ROS_REF=<sha> \
  --build-arg ROVER_WEB_REF=<sha>
```

Use a Lyrical-compatible commit for `ROVER_ROS_REF`. These overrides pin
only the two application repositories: imported dependency branches, base
image tags, apt packages, and npm/uv tool versions can still change. Use
`--nocache` when refreshing those dependencies even with pinned application
commits.

## Network dashboard

`rover-web-server` listens on port 80, which is the only port the balena
**Public Device URL** proxies. Enable that URL on the device in balenaCloud
and the dashboard is reachable at `https://<uuid>.balena-devices.com`. On the
rover LAN it is reachable directly at `http://<device-ip>/`.

The monitored device list defaults to the `devices.json` committed in the web
server repo. To retarget a fleet or a single device without rebuilding the
image, set a balenaCloud variable:

- `ROVER_WEB_DEVICES_JSON` — the device list inline as JSON (preferred on
  balena, since host files cannot be bind-mounted into a container).
- `ROVER_WEB_DEVICES_FILE` — path to a device list on a mounted volume.

Other service variables: `ROVER_WEB_PORT` (default `8080` in the app, set to
`80` in `docker-compose.yml`), `ROVER_WEB_POLL_INTERVAL_SECONDS`,
`ROVER_WEB_PING_TIMEOUT_SECONDS`, `ROVER_WEB_ROSBRIDGE_URL` (default
`ws://127.0.0.1:9090`, the rosbridge in `rovera1-app`; the `/led` page reads
the LED animation state through it).

## Ports

All containers use host networking, so these bind directly to the device:

| Port   | Service                        |
|--------|--------------------------------|
| 22     | sshd (`rovera1-app`)           |
| 80     | network dashboard              |
| 7447   | Zenoh router (loopback + rover LAN only, see below) |
| 8765   | foxglove_bridge                |
| 9090   | rosbridge websocket            |
| 48484  | balena supervisor              |

## ROS 2 over the rover LAN (Zenoh)

The ROS 2 graph runs on `rmw_zenoh_cpp`. The Zenoh router in `rovera1-app`
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
