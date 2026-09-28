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

# **SSHD background (keep alive)** - before the enable gate, so a shell is available while the
# container idles. Port 27 (image's sshd_config drop-in): platform 22, sensors 23,
# orchestrator 24, drive-interface 25, cockpit 26, vda5050 27.
/usr/sbin/sshd -D &
SSHD_PID=$!
CHILD_PIDS+=("$SSHD_PID")
echo "sshd started on port 27 (PID: $SSHD_PID)"

# **Zenoh session mode** - client unless ROVER_ZENOH_MODE=peer, as in rover-a1-orchestrator
# (see its start.sh for why runtime-started groups are clients).
case "${ROVER_ZENOH_MODE:-client}" in
  [Pp][Ee][Ee][Rr]) ROVER_ZENOH_MODE=peer ;;
  *) ROVER_ZENOH_MODE=client ;;
esac
ZENOH_ROUTER_ENDPOINT="tcp/127.0.0.1:7447"
ZENOH_CLIENT_BASE="mode=\"client\";connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];listen/endpoints=[]"
if [ "$ROVER_ZENOH_MODE" = client ]; then
  export ZENOH_CONFIG_OVERRIDE="${ZENOH_CLIENT_BASE};connect/timeout_ms=-1;connect/retry={period_init_ms:500,period_max_ms:2000,period_increase_factor:2}"
else
  unset ZENOH_CONFIG_OVERRIDE
fi
printf "export ZENOH_CONFIG_OVERRIDE='%s'\n" "${ZENOH_CLIENT_BASE};connect/timeout_ms=5000" > /tmp/rover_zenoh_cli.env
echo "Zenoh session mode: $ROVER_ZENOH_MODE"

# Normalize a balenaCloud boolean the same way the other services do: unset or empty falls back
# to $2, and anything that is not true/1/yes/on (any case) is false.
norm_bool() {
  case "${1:-$2}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) echo true ;;
    *) echo false ;;
  esac
}

ROVER_START_VDA5050=$(norm_bool "${ROVER_START_VDA5050:-}" false)
ROVER_VDA5050_LOCAL_BROKER=$(norm_bool "${ROVER_VDA5050_LOCAL_BROKER:-}" true)
ROVER_USE_GPS=$(norm_bool "${ROVER_USE_GPS:-}" false)

# Idle rather than exit when disabled: `restart: always` would otherwise crash-loop this
# service. Changing any balenaCloud variable restarts the container, which re-reads them.
if [ "$ROVER_START_VDA5050" != true ]; then
  echo "VDA 5050 disabled (ROVER_START_VDA5050=false); idling (sshd on 27 stays up)"
  # Not `exec sleep infinity`: exec would drop the TERM trap and orphan sshd.
  wait "$SSHD_PID" || true
  terminate_children
  exit 0
fi

BROKER_HOST=${ROVER_VDA5050_BROKER_HOST:-127.0.0.1}
BROKER_PORT=${ROVER_VDA5050_BROKER_PORT:-1883}

# Orders are sent as rover_mission_manager missions in Nav 2's global frame, which follows
# rover-a1-orchestrator's localization source (its start.sh): odom for 'odom', map for the rest.
# ROVER_VDA5050_MAP_FRAME overrides the derived value.
if [ -n "${ROVER_LOCALIZATION_SOURCE:-}" ]; then
  LOCALIZATION_SOURCE=$ROVER_LOCALIZATION_SOURCE
elif [ "$ROVER_USE_GPS" = true ]; then
  LOCALIZATION_SOURCE=gps
else
  LOCALIZATION_SOURCE=odom
fi
if [ -n "${ROVER_VDA5050_MAP_FRAME:-}" ]; then
  MAP_FRAME=$ROVER_VDA5050_MAP_FRAME
elif [ "$LOCALIZATION_SOURCE" = odom ]; then
  MAP_FRAME=odom
else
  MAP_FRAME=map
fi

source "/opt/ros/${ROS_DISTRO}/setup.bash"
source /root/ros2_ws/rover_a1/install/setup.bash

# **Mosquitto - Background** (before the connector, which retries its broker connection anyway).
if [ "$ROVER_VDA5050_LOCAL_BROKER" = true ]; then
  mosquitto -c /root/ros2_ws/rover_a1/install/rover_vda5050_bringup/share/rover_vda5050_bringup/config/mosquitto.conf \
    > /tmp/rover_mosquitto.log 2>&1 < /dev/null &
  MOSQUITTO_PID=$!
  CHILD_PIDS+=("$MOSQUITTO_PID")
  echo "Mosquitto started in background (PID: $MOSQUITTO_PID, MQTT 1883, WebSockets 9001)"
  if [ "$BROKER_HOST" != 127.0.0.1 ] && [ "$BROKER_HOST" != localhost ]; then
    echo "WARNING: ROVER_VDA5050_LOCAL_BROKER=true but ROVER_VDA5050_BROKER_HOST=${BROKER_HOST}: the connector uses the remote broker and the local one carries nothing"
  fi
fi

# Join the Zenoh graph. The router runs in rover-a1-zenoh-router, reachable on loopback.
export RMW_IMPLEMENTATION=rmw_zenoh_cpp

# Balena starts services in no particular order, so wait for the router rather than assume it.
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

# Kill any existing daemon (rmw_zenoh conflicts)
pkill -f ros2_daemon || true
sleep 1

if [ "$(norm_bool "${ROVER_START_MISSION_MANAGER:-}" false)" != true ]; then
  echo "WARNING: ROVER_START_MISSION_MANAGER=false - rover-a1-orchestrator runs no rover_mission_manager, so every VDA 5050 order is refused"
fi

# **VDA 5050 connector - Background**
nohup ros2 launch rover_vda5050_bringup vda5050.launch.py \
  namespace:="${ROVER_NAMESPACE:-}" \
  broker_host:="${BROKER_HOST}" \
  broker_port:="${BROKER_PORT}" \
  broker_username:="${ROVER_VDA5050_BROKER_USER:-}" \
  broker_password:="${ROVER_VDA5050_BROKER_PASSWORD:-}" \
  manufacturer:="${ROVER_VDA5050_MANUFACTURER:-MechatronicsAcademy}" \
  serial_number:="${ROVER_VDA5050_SERIAL_NUMBER:-rover_a1}" \
  map_frame:="${MAP_FRAME}" \
  > /tmp/rover_vda5050.log 2>&1 < /dev/null &
VDA5050_PID=$!
CHILD_PIDS+=("$VDA5050_PID")
echo "VDA 5050 connector started in background (PID: $VDA5050_PID, broker ${BROKER_HOST}:${BROKER_PORT}, frame ${MAP_FRAME})"

# **Supervise** - block until the first supervised process exits, then tear everything down
# and exit so `restart: always` brings the service back cleanly. `|| EXIT_CODE=$?`: under
# `bash -e` a bare `wait -n` would kill the shell on a non-zero child and skip the teardown.
EXIT_CODE=0
wait -n "${CHILD_PIDS[@]}" || EXIT_CODE=$?

STATUS_ENTRIES=("sshd:$SSHD_PID" "rover_vda5050:$VDA5050_PID")
if [ "$ROVER_VDA5050_LOCAL_BROKER" = true ]; then
  STATUS_ENTRIES+=("mosquitto:$MOSQUITTO_PID")
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
