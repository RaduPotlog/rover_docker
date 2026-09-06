#!/bin/bash -e
set -x  # Debug logging for Balena

# All long-running processes we supervise. Populated as each is started.
CHILD_PIDS=()

# Toggle whether the rover_bringup launch is started at all.
START_ROVER_BRINGUP=false

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
source /opt/ros/jazzy/setup.bash
source /root/ros2_ws/rover_a1/install/setup.bash

# **Zenoh Router - Background with proper management**
export RMW_IMPLEMENTATION=rmw_zenoh_cpp
cat > /tmp/router.json5 << 'EOF'
{
  // Router mode for Balena fleet
  mode: "router",

  // Listen on ALL interfaces (LAN + BalenaVPN + Docker)
  listen: {
    endpoints: [
      "tcp/0.0.0.0:7447"      // Catches 10.245.253.239 + 192.168.88.10
    ]
  },

  // Connect to other fleet routers if needed
  connect: {
    endpoints: []
  },

  // BalenaVPN optimized scouting (disable multicast - VPN blocks it)
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
export LD_LIBRARY_PATH=/usr/local/lib:$LD_LIBRARY_PATH
if [ "$START_ROVER_BRINGUP" = true ]; then
  nohup ros2 launch rover_bringup rover_bringup.launch.py > /tmp/rover_bringup.log 2>&1 < /dev/null &
  ROVER_PID=$!
  CHILD_PIDS+=("$ROVER_PID")
  echo "Rover bringup started in background (PID: $ROVER_PID)"
else
  echo "Rover bringup disabled (START_ROVER_BRINGUP=false); skipping"
fi

# Optional short delay to let rover nodes initialize before the bridges connect
sleep 2

# rosbridge (websocket + rosapi) - required for ros-mcp-server to introspect
# and control the ROS graph. Supervised like everything else below.
nohup ros2 launch rosbridge_server rosbridge_websocket_launch.xml > /tmp/rosbridge.log 2>&1 < /dev/null &
ROSBRIDGE_PID=$!
CHILD_PIDS+=("$ROSBRIDGE_PID")
echo "rosbridge started (PID: $ROSBRIDGE_PID)"

# foxglove_bridge is supervised like everything else (not exec'd as PID 1),
# so a crash here is detected the same way as a crash in any other process.
nohup ros2 launch foxglove_bridge foxglove_bridge_launch.xml > /tmp/foxglove_bridge.log 2>&1 < /dev/null &
FOXGLOVE_PID=$!
CHILD_PIDS+=("$FOXGLOVE_PID")
echo "foxglove_bridge started (PID: $FOXGLOVE_PID)"

# **Supervise** - block until the first of the supervised processes exits
# (crash or otherwise). Rather than let the container keep running with a
# dead component nobody notices, tear down everything else and exit so
# docker-compose's `restart: always` (Balena) brings the whole stack back
# up cleanly.
wait -n "${CHILD_PIDS[@]}"
EXIT_CODE=$?

STATUS_ENTRIES=("sshd:$SSHD_PID" "zenohd:$ZENOHD_PID" "rosbridge:$ROSBRIDGE_PID" "foxglove_bridge:$FOXGLOVE_PID")
if [ "$START_ROVER_BRINGUP" = true ]; then
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
