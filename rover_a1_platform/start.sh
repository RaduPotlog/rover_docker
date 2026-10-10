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

# Toggle whether the rover_bringup launch is started at all. Set ROVER_PLATFORM_ENABLE as a
# balenaCloud device/fleet variable (true/false); unset or empty means true. Changing the
# variable makes the balena supervisor restart this container, which re-reads it here.
case "${ROVER_PLATFORM_ENABLE:-true}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) ROVER_PLATFORM_ENABLE=true ;;
  *) ROVER_PLATFORM_ENABLE=false ;;
esac

# Localization mode for rover_bringup (read there through the ROVER_SYSTEM_USE_GPS environment
# variable).
# Normalized like ROVER_PLATFORM_ENABLE so the launch files only ever see true/false;
# unset or empty means false (wheels + IMU), true adds the RUTX11 GPS (dual EKF). The same
# variable starts the GPS driver in rover-a1-sensors.
case "${ROVER_SYSTEM_USE_GPS:-false}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) ROVER_SYSTEM_USE_GPS=true ;;
  *) ROVER_SYSTEM_USE_GPS=false ;;
esac
export ROVER_SYSTEM_USE_GPS

# Whether the GPS global EKF (rover_ekf_global_node) broadcasts map -> odom; read by
# rover_localization's publish_global_tf default. Unset or empty means false: SLAM or AMCL owns
# map -> odom while GPS is still fused (odometry/global keeps publishing). Set it true to let the
# global EKF publish map -> odom itself.
case "${ROVER_SYSTEM_GPS_MAP_TF:-false}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) ROVER_SYSTEM_GPS_MAP_TF=true ;;
  *) ROVER_SYSTEM_GPS_MAP_TF=false ;;
esac
export ROVER_SYSTEM_GPS_MAP_TF

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

# --- BEGIN log housekeeping -------------------------------------------------------------------
# Nothing used to rotate or delete logs: /tmp/rover_bringup.log grew for as long as the container
# stayed up (about 13 MB/day idle, far more if a fault spams) and was overwritten when it restarted,
# which also destroyed the log of whatever crashed it; ~/.ros/log gained an entry for every
# process start and every `ros2` CLI call, forever.
#   ROVER_SYSTEM_LOG_MAX_MB          size at which a log is rotated (default 20)
#   ROVER_SYSTEM_LOG_BACKUPS         rotated copies kept per log, FILE.1 .. FILE.N (default 3)
#   ROVER_SYSTEM_ROS_LOG_KEEP_DAYS   age after which ~/.ros/log entries are deleted (default 7)
#   ROVER_SYSTEM_ROS_LOG_MAX_MB      size ~/.ros/log is trimmed to, oldest first (default 300)
ROVER_LOG_MAX_BYTES=$(( ${ROVER_SYSTEM_LOG_MAX_MB:-20} * 1024 * 1024 ))
ROVER_LOG_BACKUP_COUNT=${ROVER_SYSTEM_LOG_BACKUPS:-3}

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

# Delete ros logs older than ROVER_SYSTEM_ROS_LOG_KEEP_DAYS, then the oldest ones until the
# directory is below ROVER_SYSTEM_ROS_LOG_MAX_MB. Called before anything is launched, so no live
# log is touched.
prune_ros_logs() {
  local - dir days max_mb entry
  set +x  # the size loop would flood the container log
  dir=${ROS_LOG_DIR:-${ROS_HOME:-$HOME/.ros}/log}
  days=${ROVER_SYSTEM_ROS_LOG_KEEP_DAYS:-7}
  max_mb=${ROVER_SYSTEM_ROS_LOG_MAX_MB:-300}
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

# SSHD background (keep alive)
/usr/sbin/sshd -D &
SSHD_PID=$!
CHILD_PIDS+=("$SSHD_PID")

# rover_crsf_teleop saves the measured RC stick calibration here (the rover-config named volume,
# see docker-compose.yml). Created up front so the first `apply` does not have to, and so an
# operator can drop a calibration in by hand before the node ever starts.
mkdir -p /config/rover_crsf_teleop

# Source ROS2 + workspace
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source /root/ros2_ws/rover_a1/install/setup.bash

# **Zenoh session mode** for every ROS process this container starts
# (ROVER_ZENOH_MODE_PLATFORM; unset or empty means peer).
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
case "${ROVER_ZENOH_MODE_PLATFORM:-peer}" in
  [Pp][Ee][Ee][Rr]) ZENOH_MODE=peer ;;
  [Cc][Ll][Ii][Ee][Nn][Tt]) ZENOH_MODE=client ;;
  *) ZENOH_MODE=peer ;;
esac
ZENOH_ROUTER_ENDPOINT="tcp/127.0.0.1:7447"
ZENOH_CLIENT_BASE="mode=\"client\";connect/endpoints=[\"${ZENOH_ROUTER_ENDPOINT}\"];listen/endpoints=[]"
if [ "$ZENOH_MODE" = client ]; then
  export ZENOH_CONFIG_OVERRIDE="${ZENOH_CLIENT_BASE};connect/timeout_ms=-1;connect/retry={period_init_ms:500,period_max_ms:2000,period_increase_factor:2}"
else
  unset ZENOH_CONFIG_OVERRIDE
fi
printf "export ZENOH_CONFIG_OVERRIDE='%s'\n" "${ZENOH_CLIENT_BASE};connect/timeout_ms=5000" > /tmp/rover_zenoh_cli.env
echo "Zenoh session mode: $ZENOH_MODE (ROVER_ZENOH_MODE_PLATFORM)"

export RMW_IMPLEMENTATION=rmw_zenoh_cpp

# The router runs in its own service, rover-a1-zenoh-router, on 127.0.0.1:7447 (host networking).
# Balena starts services in no particular order, so wait for it rather than assume it. Unlike the
# payload containers this one does not start without it: exit, and `restart: always` retries.
ZENOH_ROUTER_READY=false
for _ in $(seq 1 60); do
  if (exec 3<>/dev/tcp/127.0.0.1/7447) 2>/dev/null; then
    ZENOH_ROUTER_READY=true
    break
  fi
  sleep 1
done
if [ "$ZENOH_ROUTER_READY" != true ]; then
  echo "ERROR: Zenoh router (127.0.0.1:7447, rover-a1-zenoh-router) not reachable after 60 s"
  terminate_children
  exit 1
fi

# **Rover Bringup - Background**
# Starts the rover nodes and redirects output so it doesn't pollute the container logs.
# Append, never prepend: /usr/local/lib is only for libs that exist nowhere else
# (rover_modbus, rover_cppuprofile). Prepending it made it shadow the ROS libs the
# workspace was compiled against, since LD_LIBRARY_PATH beats their RUNPATH.
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib
if [ "$ROVER_PLATFORM_ENABLE" = true ]; then
  set -m  # own process group, so stop_launch_groups can signal its nodes
  # `> >(...)` rather than a pipe: $! must stay the PID (and process group) of `ros2 launch` itself,
  # which stop_launch_groups and `wait -n` below depend on.
  nohup ros2 launch rover_bringup rover_bringup.launch.py \
    > >(rotating_log /tmp/rover_bringup.log "$ROVER_LOG_MAX_BYTES" "$ROVER_LOG_BACKUP_COUNT") 2>&1 < /dev/null &
  ROVER_PID=$!
  set +m
  LAUNCH_PGIDS+=("$ROVER_PID")
  CHILD_PIDS+=("$ROVER_PID")
  echo "Rover bringup started in background (PID: $ROVER_PID, ROVER_SYSTEM_USE_GPS=$ROVER_SYSTEM_USE_GPS, ROVER_SYSTEM_GPS_MAP_TF=$ROVER_SYSTEM_GPS_MAP_TF)"
else
  echo "Rover bringup disabled (ROVER_PLATFORM_ENABLE=false); skipping"
fi

# Optional short delay to let rover nodes initialize before the bridges connect
sleep 2

# Web bridges, supervised like everything else below (not exec'd as PID 1), so a
# crash here is detected the same way as a crash in any other process:
# - foxglove_bridge (/rover_foxglove_bridge) - used by the web dashboards (network
#   monitor LED page, diagnostics page).
# - rosbridge websocket + rosapi (/rover_rosbridge_websocket, /rosapi) - kept only for
#   ros-mcp-server to introspect and control the ROS graph.
# rover_web_bridges.launch.py starts them under rover_-prefixed node names.
set -m  # own process group, so stop_launch_groups can signal its nodes
nohup ros2 launch rover_bringup rover_web_bridges.launch.py \
  > >(rotating_log /tmp/web_bridges.log "$ROVER_LOG_MAX_BYTES" "$ROVER_LOG_BACKUP_COUNT") 2>&1 < /dev/null &
BRIDGES_PID=$!
set +m
LAUNCH_PGIDS+=("$BRIDGES_PID")
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

STATUS_ENTRIES=("sshd:$SSHD_PID" "web_bridges:$BRIDGES_PID")
if [ "$ROVER_PLATFORM_ENABLE" = true ]; then
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
