#!/bin/bash -e
set -x  # Debug logging for Balena

# All long-running processes we supervise. Populated as each is started.
CHILD_PIDS=()

terminate_children() {
  if [ "${#CHILD_PIDS[@]}" -gt 0 ]; then
    kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null || true
    wait "${CHILD_PIDS[@]}" 2>/dev/null || true
  fi
}

# Forward container stop/kill signals to every supervised process instead
# of only whichever one happens to be PID 1.
trap 'terminate_children; exit 0' TERM INT

# Normalize a balenaCloud boolean the same way the other rover containers do: unset or empty
# falls back to $2, and anything that is not true/1/yes/on (any case) is false.
norm_bool() {
  case "${1:-$2}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) echo true ;;
    *) echo false ;;
  esac
}

ROVER_START_SENSORS=$(norm_bool "${ROVER_START_SENSORS:-}" false)
# One switch for GPS on the whole rover: the driver here, GPS fusion in rover-a1-platform.
ROVER_USE_GPS=$(norm_bool "${ROVER_USE_GPS:-}" false)
ROVER_USE_LIDAR=$(norm_bool "${ROVER_USE_LIDAR:-}" false)

# Idle rather than exit when disabled: `restart: always` would otherwise crash-loop this
# service. Changing any balenaCloud variable restarts the container, which re-reads them here.
if [ "$ROVER_START_SENSORS" != true ]; then
  echo "Sensor payload disabled (ROVER_START_SENSORS=false); idling"
  sleep infinity &
  CHILD_PIDS+=("$!")
  wait "${CHILD_PIDS[@]}" || true
  exit 0
fi

# Source ROS2 + workspace
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source /root/ros2_ws/rover_a1/install/setup.bash

# Join the Zenoh graph as a session. The router runs in rover-a1-platform; both containers are
# network_mode: host, so it is reachable on loopback. No ZENOH_ROUTER_CONFIG_URI - a second
# router would fight the first one for port 7447.
export RMW_IMPLEMENTATION=rmw_zenoh_cpp

# Balena starts services in no particular order, so wait for the router rather than assume it.
# Falls through with a warning: rmw_zenoh retries the connection on its own.
ZENOH_ROUTER_READY=false
for _ in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/7447) 2>/dev/null; then
    ZENOH_ROUTER_READY=true
    break
  fi
  sleep 1
done
if [ "$ZENOH_ROUTER_READY" != true ]; then
  echo "WARNING: Zenoh router (127.0.0.1:7447, rover-a1-platform) not reachable after 60 s; starting anyway"
fi

ROVER_NAMESPACE=${ROVER_NAMESPACE:-}

# **Sensor drivers - Background**
nohup ros2 launch rover_sensors_bringup rover_sensors.launch.py \
  namespace:="${ROVER_NAMESPACE}" \
  use_gps:="${ROVER_USE_GPS}" \
  use_lidar:="${ROVER_USE_LIDAR}" \
  > /tmp/rover_sensors.log 2>&1 < /dev/null &
SENSORS_PID=$!
CHILD_PIDS+=("$SENSORS_PID")
echo "Sensor payload started in background (PID: $SENSORS_PID, gps=$ROVER_USE_GPS, lidar=$ROVER_USE_LIDAR)"

# **Supervise** - exit when the launch exits (crash or otherwise), so docker-compose's
# `restart: always` (Balena) brings the drivers back up cleanly.
#
# `|| EXIT_CODE=$?` rather than a bare `wait -n`: this script runs under `bash -e`, so a
# child exiting non-zero would otherwise kill the shell here and skip the teardown.
EXIT_CODE=0
wait -n "${CHILD_PIDS[@]}" || EXIT_CODE=$?
echo "Supervised process 'rover_sensors_bringup' (PID $SENSORS_PID) exited (code $EXIT_CODE)"

terminate_children
exit "$EXIT_CODE"
