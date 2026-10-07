#!/bin/bash -e
# Copyright 2026 Mechatronics Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -x  # Debug logging for Balena

# All long-running processes we supervise. Populated as each is started.
CHILD_PIDS=()

# --- BEGIN log housekeeping -------------------------------------------------------------------
# Nothing used to rotate or delete logs: /tmp/rover_bringup.log grew for as long as the container
# stayed up (about 13 MB/day idle, far more if a fault spams) and was overwritten when it restarted,
# which also destroyed the log of whatever crashed it; ~/.ros/log gained an entry for every
# process start and every `ros2` CLI call, forever.
#   ROVER_LOG_MAX_MB          size at which a log is rotated (default 20)
#   ROVER_LOG_BACKUPS         rotated copies kept per log, FILE.1 .. FILE.N (default 3)
#   ROVER_ROS_LOG_KEEP_DAYS   age after which ~/.ros/log entries are deleted (default 7)
#   ROVER_ROS_LOG_MAX_MB      size ~/.ros/log is trimmed to, oldest first (default 300)
ROVER_LOG_MAX_BYTES=$(( ${ROVER_LOG_MAX_MB:-20} * 1024 * 1024 ))
ROVER_LOG_BACKUP_COUNT=${ROVER_LOG_BACKUPS:-3}

# Copies stdin to FILE and keeps it below MAX_BYTES: when the next line would not fit, FILE becomes
# FILE.1, FILE.1 becomes FILE.2 ... and the oldest of BACKUPS copies is dropped. A FILE left over
# from a previous run is rotated out of the way first instead of being overwritten.
# It is the other end of the launch's stdout pipe, so it must outlive every writer: it ignores the
# SIGINT stop_launch_groups sends the whole launch group (the shutdown messages are worth keeping),
# never exits before EOF, and on a write error (full disk) keeps draining so the nodes never get a
# SIGPIPE.
read -r -d '' ROVER_ROTATING_LOG_PY <<'PY' || true
import os, signal, sys

path, max_bytes, backups = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
signal.signal(signal.SIGINT, signal.SIG_IGN)


def rotate():
    if backups > 0:
        for i in range(backups - 1, 0, -1):
            try:
                os.replace("%s.%d" % (path, i), "%s.%d" % (path, i + 1))
            except FileNotFoundError:
                pass
        os.replace(path, path + ".1")
    else:
        os.truncate(path, 0)


def open_log():
    try:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            rotate()
    except OSError:
        pass
    return open(path, "ab", buffering=0)


out, size = None, 0
try:
    out = open_log()
except OSError:
    out = None

while True:
    line = sys.stdin.buffer.readline(65536)
    if not line:
        break
    try:
        if out is not None and size > 0 and size + len(line) > max_bytes:
            out.close()
            out = None
            rotate()
            out = open(path, "ab", buffering=0)
            size = 0
        if out is None:
            out = open_log()
            size = 0
        out.write(line)
        size += len(line)
    except OSError:
        out = None
PY

rotating_log() {
  exec python3 -u -c "$ROVER_ROTATING_LOG_PY" "$@"
}

# Delete ros logs older than ROVER_ROS_LOG_KEEP_DAYS, then the oldest ones until the directory is
# below ROVER_ROS_LOG_MAX_MB. Called before anything is launched, so no live log is touched.
prune_ros_logs() {
  local - dir days max_mb entry
  set +x  # the size loop would flood the container log
  dir=${ROS_LOG_DIR:-${ROS_HOME:-$HOME/.ros}/log}
  days=${ROVER_ROS_LOG_KEEP_DAYS:-7}
  max_mb=${ROVER_ROS_LOG_MAX_MB:-300}
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -mtime +"$days" -exec rm -rf {} + 2>/dev/null || true
  while [ "$(du -sm "$dir" 2>/dev/null | cut -f1)" -gt "$max_mb" ] 2>/dev/null; do
    entry=$(ls -tr "$dir" | head -n 1)
    [ -n "$entry" ] || break
    rm -rf -- "${dir:?}/$entry"
  done
  echo "ROS log housekeeping: $dir now $(du -sm "$dir" 2>/dev/null | cut -f1) MB, $(ls "$dir" 2>/dev/null | wc -l) entries"
}
# --- END log housekeeping ---------------------------------------------------------------------

prune_ros_logs

# Process groups of the `ros2 launch` jobs (each launch's PID: they run as jobs, see set -m below).
LAUNCH_PGIDS=()

# Stop the launched nodes themselves, not just `ros2 launch`: on SIGTERM launch exits at once and
# orphans its nodes, and when this script (PID 1) exits the kernel SIGKILLs whatever is left, so
# no node ever ran its shutdown code. SIGINT to each whole group is the signal every node here
# handles cleanly (rclpy's SIGTERM path hangs under rmw_zenoh). Wait up to
# LAUNCH_STOP_TIMEOUT_S for all of them together, then SIGKILL the stragglers.
LAUNCH_STOP_TIMEOUT_S=5
stop_launch_groups() {
  local - pgid alive
  set +x  # the polling below would flood the log
  [ "${#LAUNCH_PGIDS[@]}" -gt 0 ] || return 0
  for pgid in "${LAUNCH_PGIDS[@]}"; do
    kill -INT -- "-$pgid" 2>/dev/null || true
  done
  for _ in $(seq 1 $((LAUNCH_STOP_TIMEOUT_S * 10))); do
    alive=false
    for pgid in "${LAUNCH_PGIDS[@]}"; do
      if kill -0 -- "-$pgid" 2>/dev/null; then
        alive=true
      fi
    done
    [ "$alive" = true ] || return 0
    sleep 0.1
  done
  echo "Launched nodes still running after ${LAUNCH_STOP_TIMEOUT_S} s; killing them"
  for pgid in "${LAUNCH_PGIDS[@]}"; do
    kill -KILL -- "-$pgid" 2>/dev/null || true
  done
}

terminate_children() {
  stop_launch_groups
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
# empty means client).
# Set before the idle gate below, so SSH shells get the CLI settings even while this
# container idles.
#   peer: rmw_zenoh's default - each process also links directly to the other peers. The
#     platform runs this way, so its own traffic (imu -> EKF, cmd_vel -> twist_mux ->
#     ros2_control, safety) never waits on the router.
#   client: each process opens one link, to rover-a1-zenoh-router, and all its traffic goes
#     through it. For the containers whose processes come and go (orchestrator, sensors): when
#     a group of clients stops, only the router cleans up after it, not every process.
#   Measured 2026-09-26: that cleanup keeps the router at 100 % of a core for up to a minute
#   after an orchestrator restart, stalling everything routed through it. With the platform as
#   clients too, imu/odom stopped for 31-58 s; with the platform as peers, 0.15 s. As full
#   peer mesh (the old default), every stop stalled the other peers for 1-4 s.
#   Clients wait for the router (timeout_ms=-1) and reconnect after a restart (retry); peers
#   do both by default.
# The ros2 CLI in an SSH shell is always a client with a 5 s timeout (.bashrc sources
# /tmp/rover_zenoh_cli.env): it fails fast while the router is down and stays out of the mesh.
case "${ROVER_ZENOH_MODE:-client}" in
  [Pp][Ee][Ee][Rr]) ROVER_ZENOH_MODE=peer ;;
  [Cc][Ll][Ii][Ee][Nn][Tt]) ROVER_ZENOH_MODE=client ;;
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
ROVER_USE_CAMERA=$(norm_bool "${ROVER_USE_CAMERA:-}" false)

# With no driver selected the launch has nothing to run and exits at once, so that case is
# treated as disabled too.
DISABLED_REASON=""
if [ "$ROVER_START_SENSORS" != true ]; then
  DISABLED_REASON="ROVER_START_SENSORS=false"
elif [ "$ROVER_USE_GPS" != true ] && [ "$ROVER_USE_LIDAR" != true ] && [ "$ROVER_USE_CAMERA" != true ]; then
  DISABLED_REASON="ROVER_USE_GPS, ROVER_USE_LIDAR and ROVER_USE_CAMERA all false (no driver to run)"
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
# `namespace:=` only when there is one: `ros2 launch` rejects an empty `name:=` ("malformed launch
# argument") and exits at once, which would crash-loop this service on an unnamespaced rover
# (rover-a1-vda5050 did, 2026-09-28). The launch files default namespace to ROVER_NAMESPACE.
NAMESPACE_ARG=()
if [ -n "$ROVER_NAMESPACE" ]; then
  NAMESPACE_ARG=(namespace:="${ROVER_NAMESPACE}")
fi

# **Sensor drivers - Background**
set -m  # own process group, so stop_launch_groups can signal its nodes
nohup ros2 launch rover_sensors_bringup rover_sensors.launch.py \
  "${NAMESPACE_ARG[@]}" \
  use_gps:="${ROVER_USE_GPS}" \
  use_lidar:="${ROVER_USE_LIDAR}" \
  use_camera:="${ROVER_USE_CAMERA}" \
  > >(rotating_log /tmp/rover_sensors.log "$ROVER_LOG_MAX_BYTES" "$ROVER_LOG_BACKUP_COUNT") 2>&1 < /dev/null &
SENSORS_PID=$!
set +m
LAUNCH_PGIDS+=("$SENSORS_PID")
CHILD_PIDS+=("$SENSORS_PID")
echo "Sensor payload started in background (PID: $SENSORS_PID, gps=$ROVER_USE_GPS, lidar=$ROVER_USE_LIDAR, camera=$ROVER_USE_CAMERA)"

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
