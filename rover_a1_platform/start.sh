#!/bin/bash -e
set -x  # Debug logging for Balena

# All long-running processes we supervise. Populated as each is started.
CHILD_PIDS=()

# Toggle whether the rover_bringup launch is started at all. Set ROVER_START_ROS_PLATFORM as a
# balenaCloud device/fleet variable (true/false); unset or empty means true. Changing the
# variable makes the balena supervisor restart this container, which re-reads it here.
case "${ROVER_START_ROS_PLATFORM:-true}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) ROVER_START_ROS_PLATFORM=true ;;
  *) ROVER_START_ROS_PLATFORM=false ;;
esac

# Localization mode for rover_bringup (read there through the ROVER_USE_GPS environment variable).
# Normalized like ROVER_START_ROS_PLATFORM so the launch files only ever see true/false;
# unset or empty means false (wheels + IMU), true adds the RUTX11 GPS (dual EKF). The same
# variable starts the GPS driver in rover-a1-sensors.
case "${ROVER_USE_GPS:-false}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) ROVER_USE_GPS=true ;;
  *) ROVER_USE_GPS=false ;;
esac
export ROVER_USE_GPS

terminate_children() {
  if [ "${#CHILD_PIDS[@]}" -gt 0 ]; then
    kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null || true
    wait "${CHILD_PIDS[@]}" 2>/dev/null || true
  fi
}

# Forward container stop/kill signals to every supervised process instead
# of only whichever one happens to be PID 1.
trap 'terminate_children; exit 0' TERM INT

# SSHD background (keep alive)
/usr/sbin/sshd -D &
SSHD_PID=$!
CHILD_PIDS+=("$SSHD_PID")

# Source ROS2 + workspace
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source /root/ros2_ws/rover_a1/install/setup.bash

# **Zenoh Router - Background with proper management**
export RMW_IMPLEMENTATION=rmw_zenoh_cpp

# The router is reachable on loopback plus the rover LAN address only, so
# hosts on the rover LAN can join the ROS 2 graph while balenaVPN and GSM
# stay closed (binding an address, not 0.0.0.0, is what keeps them out).
# Override per device/fleet with the ROVER_LAN_IP balenaCloud variable.
ROVER_LAN_IP=${ROVER_LAN_IP:-192.168.1.201}

# Binding an address the host doesn't have makes rmw_zenohd exit, which
# would crash-loop the whole container. Give DHCP/NetworkManager a moment,
# then fall back to loopback-only so the rover still runs locally.
ZENOH_LAN_ENDPOINT=""
for _ in $(seq 1 10); do
  if hostname -I | tr ' ' '\n' | grep -Fxq "$ROVER_LAN_IP"; then
    ZENOH_LAN_ENDPOINT="\"tcp/${ROVER_LAN_IP}:7447\","
    break
  fi
  sleep 1
done
if [ -z "$ZENOH_LAN_ENDPOINT" ]; then
  echo "WARNING: rover LAN address $ROVER_LAN_IP not present; Zenoh router is loopback-only until the container restarts"
fi

cat > /tmp/router.json5 << EOF
{
  // Router mode for Balena fleet
  mode: "router",

  // Loopback (both families: nodes resolve "localhost" and may pick ::1)
  // plus the rover LAN address. Not 0.0.0.0 - that would expose the ROS 2
  // graph on balenaVPN and GSM too.
  listen: {
    endpoints: [
      ${ZENOH_LAN_ENDPOINT}
      "tcp/127.0.0.1:7447",
      "tcp/[::1]:7447"
    ]
  },

  // Remote hosts dial in; the rover doesn't dial out
  connect: {
    endpoints: []
  },

  // No multicast scouting - LAN hosts connect to the router explicitly
  scouting: {
    multicast: {
      enabled: false
    }
  }
}
EOF
export ZENOH_ROUTER_CONFIG_URI=/tmp/router.json5

# Kill any existing daemon (rmw_zenoh conflicts)
pkill -f ros2_daemon || true
sleep 1

# Start Zenoh Router in background
nohup ros2 run rmw_zenoh_cpp rmw_zenohd > /tmp/zenohd.log 2>&1 < /dev/null &
ZENOHD_PID=$!
CHILD_PIDS+=("$ZENOHD_PID")

echo "Zenoh router started (PID: $ZENOHD_PID)"

# Verify it's alive
if ! kill -0 $ZENOHD_PID 2>/dev/null; then
  echo "ERROR: rmw_zenohd failed to start. Check /tmp/zenohd.log"
  cat /tmp/zenohd.log
  exit 1
fi

# **Rover Bringup - Background**
# Starts the rover nodes and redirects output so it doesn't pollute the container logs.
# Append, never prepend: /usr/local/lib is only for libs that exist nowhere else
# (rover_modbus, rover_cppuprofile). Prepending it made it shadow the ROS libs the
# workspace was compiled against, since LD_LIBRARY_PATH beats their RUNPATH.
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
if [ "$ROVER_START_ROS_PLATFORM" = true ]; then
  nohup ros2 launch rover_bringup rover_bringup.launch.py > /tmp/rover_bringup.log 2>&1 < /dev/null &
  ROVER_PID=$!
  CHILD_PIDS+=("$ROVER_PID")
  echo "Rover bringup started in background (PID: $ROVER_PID, ROVER_USE_GPS=$ROVER_USE_GPS)"
else
  echo "Rover bringup disabled (ROVER_START_ROS_PLATFORM=false); skipping"
fi

# Optional short delay to let rover nodes initialize before the bridges connect
sleep 2

# Web bridges, supervised like everything else below (not exec'd as PID 1), so a
# crash here is detected the same way as a crash in any other process:
# - foxglove_bridge (/rover_foxglove_bridge) - used by the web dashboards (network
#   monitor LED page, Cockpit diagnostics).
# - rosbridge websocket + rosapi (/rover_rosbridge_websocket, /rosapi) - kept only for
#   ros-mcp-server to introspect and control the ROS graph.
# rover_web_bridges.launch.py starts them under rover_-prefixed node names.
nohup ros2 launch rover_bringup rover_web_bridges.launch.py > /tmp/web_bridges.log 2>&1 < /dev/null &
BRIDGES_PID=$!
CHILD_PIDS+=("$BRIDGES_PID")
echo "Web bridges (foxglove_bridge, rosbridge) started (PID: $BRIDGES_PID)"

# **Supervise** - block until the first of the supervised processes exits
# (crash or otherwise). Rather than let the container keep running with a
# dead component nobody notices, tear down everything else and exit so
# docker-compose's `restart: always` (Balena) brings the whole stack back
# up cleanly.
#
# `|| EXIT_CODE=$?` rather than a bare `wait -n`: this script runs
# under `bash -e`, so a child exiting non-zero - the crash case this
# block exists to report - would otherwise kill the shell here,
# skipping the teardown and the log line naming what died.
EXIT_CODE=0
wait -n "${CHILD_PIDS[@]}" || EXIT_CODE=$?

STATUS_ENTRIES=("sshd:$SSHD_PID" "zenohd:$ZENOHD_PID" "web_bridges:$BRIDGES_PID")
if [ "$ROVER_START_ROS_PLATFORM" = true ]; then
  STATUS_ENTRIES+=("rover_bringup:$ROVER_PID")
fi

for entry in "${STATUS_ENTRIES[@]}"; do
  name=${entry%%:*}
  pid=${entry##*:}
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Supervised process '$name' (PID $pid) exited (code $EXIT_CODE)"
  fi
done

terminate_children
exit "$EXIT_CODE"
