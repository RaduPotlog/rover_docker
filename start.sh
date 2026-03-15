#!/bin/bash -e
set -x  # Debug logging for Balena

# SSHD background (keep alive)
/usr/sbin/sshd -D &
SSHD_PID=$!

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

# Start Zenoh Router in background with nohup + disown
nohup ros2 run rmw_zenoh_cpp rmw_zenohd > /tmp/zenohd.log 2>&1 < /dev/null &
ZENOHD_PID=$!
disown -r  # Prevent SIGHUP from killing it

echo "Zenoh router started (PID: $ZENOHD_PID)"

# Verify it's alive
if ! kill -0 $ZENOHD_PID 2>/dev/null; then
  echo "ERROR: rmw_zenohd failed to start. Check /tmp/zenohd.log"
  cat /tmp/zenohd.log
  exit 1
fi

# **FOREGROUND** foxglove_bridge as PID 1
exec ros2 launch foxglove_bridge foxglove_bridge_launch.xml
