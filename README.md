# rover_docker

Docker files to build the balenaOS release for the Rover A1.

Two services are deployed to the balenaCloud fleet `g_potlog_radu/rovera1`.
Each has its own folder holding its Dockerfile and any scripts, which is the
service's build context in `docker-compose.yml`:

| Service            | Folder              | Contents                                                                   |
|--------------------|---------------------|----------------------------------------------------------------------------|
| `rovera1-app`      | `rovera1_app/`      | Ubuntu 24.04 + ROS 2 Jazzy + rover firmware (sshd, Zenoh router, `rover_bringup`, rosbridge, foxglove_bridge); `start.sh` is the entrypoint |
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

## Deploy

```bash
balena push g_potlog_radu/rovera1 --nocache
```

`--nocache` matters: both services fetch their application source with
`git clone` during the build (`rover_ros` and `rover_networking_web_server`
respectively). Those clones sit in cached layers, so a plain `balena push`
will happily ship stale application code.

Pin a build to specific commits instead of the branch tips with:

```bash
balena push g_potlog_radu/rovera1 \
  --build-arg ROVER_ROS_REF=<sha> \
  --build-arg ROVER_WEB_REF=<sha>
```

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

To join from a LAN host running ROS 2 Jazzy with `rmw_zenoh_cpp`, run a local
router that dials the rover, then start nodes as usual:

```bash
# on the LAN host
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
