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

# **SSHD background (keep alive)** - started before the enable/disable gate below, so the
# container is reachable even while the payload idles. Port 23 (set in the image's
# sshd_config drop-in): one port per container on the shared host network - platform 22,
# sensors 23, orchestrator 24, drive-interface 25, cockpit 26.
/usr/sbin/sshd -D &
SSHD_PID=$!
CHILD_PIDS+=("$SSHD_PID")
echo "sshd started on port 23 (PID: $SSHD_PID)"

# **Zenoh session mode** for every ROS process this container starts (ROVER_ZENOH_MODE; unset or
# empty means client). Set before the idle gate below, so SSH shells get the CLI settings
# even while this container idles. client: each process opens one link, to the router in
# rover-a1-zenoh-router, and all traffic goes through it. peer (the rollback): rmw_zenoh's
# default, where every process also links directly to every other one - with ~35 processes on the
# host network that was ~600 links, and a group of them shutting down stalled the rest for
# seconds. Keep it equal on every service.
#   timeout_ms=-1: a process started before the router waits for it instead of aborting with
#   RCLBadAlloc; after a router restart the clients reconnect (retry) on their own.
# The ros2 CLI in an SSH shell gets the same client settings with a 5 s timeout, so a command
# fails fast while the router is down; .bashrc sources /tmp/rover_zenoh_cli.env.
case "${ROVER_ZENOH_MODE:-client}" in
  [Pp][Ee][Ee][Rr]) ROVER_ZENOH_MODE=peer ;;
  *) ROVER_ZENOH_MODE=client ;;
esac
ZENOH_ROUTER_ENDPOINT="tcp/127.0.0.1:7447"
if [ "$ROVER_ZENOH_MODE" = client ]; then
  ZENOH_CLIENT_BASE="mode=\"client\";connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];listen/endpoints=[]"
  export ZENOH_CONFIG_OVERRIDE="${ZENOH_CLIENT_BASE};connect/timeout_ms=-1;connect/retry={period_init_ms:500,period_max_ms:2000,period_increase_factor:2}"
  printf "export ZENOH_CONFIG_OVERRIDE='%s'\n" "${ZENOH_CLIENT_BASE};connect/timeout_ms=5000" > /tmp/rover_zenoh_cli.env
else
  unset ZENOH_CONFIG_OVERRIDE
  : > /tmp/rover_zenoh_cli.env
fi
echo "Zenoh session mode: $ROVER_ZENOH_MODE"

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

# With no driver selected the launch has nothing to run and exits at once, so that case is
# treated as disabled too.
DISABLED_REASON=""
if [ "$ROVER_START_SENSORS" != true ]; then
  DISABLED_REASON="ROVER_START_SENSORS=false"
elif [ "$ROVER_USE_GPS" != true ] && [ "$ROVER_USE_LIDAR" != true ]; then
  DISABLED_REASON="ROVER_USE_GPS=false and ROVER_USE_LIDAR=false (no driver to run)"
fi

# Idle rather than exit when disabled: `restart: always` would otherwise crash-loop this
# service. Changing any balenaCloud variable restarts the container, which re-reads them here.
if [ -n "$DISABLED_REASON" ]; then
  echo "Sensor payload disabled: ${DISABLED_REASON}; idling (sshd on 23 stays up)"
  # Waiting on sshd idles just as well as `sleep infinity` and keeps signals forwarded.
  wait "$SSHD_PID" || true
  terminate_children
  exit 0
fi

# Source ROS2 + workspace
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source /root/ros2_ws/rover_a1/install/setup.bash

# Join the Zenoh graph (as a client, see ROVER_ZENOH_MODE above). The router runs in
# rover-a1-zenoh-router; every service is network_mode: host, so it is reachable on loopback. No
# ZENOH_ROUTER_CONFIG_URI - a second router would fight the first one for port 7447.
export RMW_IMPLEMENTATION=rmw_zenoh_cpp

# Balena starts services in no particular order, so wait for the router rather than assume it.
# Falls through with a warning: in client mode each process waits for the router itself.
ZENOH_ROUTER_READY=false
for _ in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/7447) 2>/dev/null; then
    ZENOH_ROUTER_READY=true
    break
  fi
  sleep 1
done
if [ "$ZENOH_ROUTER_READY" != true ]; then
  echo "WARNING: Zenoh router (127.0.0.1:7447, rover-a1-zenoh-router) not reachable after 60 s; starting anyway"
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

for entry in "sshd:$SSHD_PID" "rover_sensors_bringup:$SENSORS_PID"; do
  name=${entry%%:*}
  pid=${entry##*:}
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Supervised process '$name' (PID $pid) exited (code $EXIT_CODE)"
  fi
done

terminate_children
exit "$EXIT_CODE"
