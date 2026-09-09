# rover_docker

Docker files to build the balenaOS release for the Rover A1.

Two services are deployed to the balenaCloud fleet `g_potlog_radu/rovera1`:

| Service            | Contents                                                                   |
|--------------------|----------------------------------------------------------------------------|
| `rovera1-app`      | Ubuntu 24.04 + ROS 2 Jazzy + rover firmware (sshd, Zenoh router, `rover_bringup`, rosbridge, foxglove_bridge) |
| `rover-web-server` | [`rover_networking_web_server`](https://github.com/RaduPotlog/rover_networking_web_server) — network monitoring dashboard on port 80 |

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
`ROVER_WEB_PING_TIMEOUT_SECONDS`.

## Ports

All containers use host networking, so these bind directly to the device:

| Port   | Service                        |
|--------|--------------------------------|
| 22     | sshd (`rovera1-app`)           |
| 80     | network dashboard              |
| 7447   | Zenoh router                   |
| 8765   | foxglove_bridge                |
| 9090   | rosbridge websocket            |
| 48484  | balena supervisor              |
