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

# **SSHD background (keep alive)** - started before the enable/disable gate below, because a
# shell is most useful exactly when the orchestrator is idling and there is no Nav 2 to
# inspect. Credentials are the image's (root password), as in rover-a1-platform.
#
# Port 24 (set in the image's sshd_config drop-in), not 22: host networking shares one port
# space, so each container's sshd has its own - platform 22, sensors 23, orchestrator 24,
# drive-interface 25, vda5050 26.
/usr/sbin/sshd -D &
SSHD_PID=$!
CHILD_PIDS+=("$SSHD_PID")
echo "sshd started on port 24 (PID: $SSHD_PID)"

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

# Normalize a balenaCloud boolean the same way rover-a1-platform's start.sh does: unset or
# empty falls back to $2, and anything that is not true/1/yes/on (any case) is false.
norm_bool() {
  case "${1:-$2}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) echo true ;;
    *) echo false ;;
  esac
}

ROVER_START_ROS_PLATFORM=$(norm_bool "${ROVER_START_ROS_PLATFORM:-}" true)
ROVER_START_NAVIGATION=$(norm_bool "${ROVER_START_NAVIGATION:-}" false)
ROVER_START_MISSION_MANAGER=$(norm_bool "${ROVER_START_MISSION_MANAGER:-}" false)
# Driving modes (rover_drive_mode): routes the web UI's joystick to the platform (MANUAL, or
# through the lidar collision monitor in ASSISTED) and gates Nav 2 to AUTOMATIC. On by
# default and independent of ROVER_START_NAVIGATION: without it the drive UI cannot drive.
ROVER_START_DRIVE_MODE=$(norm_bool "${ROVER_START_DRIVE_MODE:-}" true)
case "${ROVER_DRIVE_DEFAULT_MODE:-assisted}" in
  manual|assisted) ROVER_DRIVE_DEFAULT_MODE=${ROVER_DRIVE_DEFAULT_MODE:-assisted} ;;
  *)
    echo "WARNING: ROVER_DRIVE_DEFAULT_MODE='${ROVER_DRIVE_DEFAULT_MODE}' is not manual|assisted; using 'assisted'"
    ROVER_DRIVE_DEFAULT_MODE=assisted
    ;;
esac
ROVER_USE_GPS=$(norm_bool "${ROVER_USE_GPS:-}" false)
ROVER_GPS_PUBLISH_MAP_TF=$(norm_bool "${ROVER_GPS_PUBLISH_MAP_TF:-}" false)
ROVER_USE_LIDAR=$(norm_bool "${ROVER_USE_LIDAR:-}" false)
# Adds the RealSense depth cloud to the local costmap (bringup.launch.py use_camera).
ROVER_NAV_USE_CAMERA=$(norm_bool "${ROVER_NAV_USE_CAMERA:-}" false)
# The camera itself runs in rover-a1-sensors; read here only to warn when Nav 2 would wait on it.
ROVER_USE_CAMERA=$(norm_bool "${ROVER_USE_CAMERA:-}" false)
# true only when the platform is rover_gazebo (Gazebo publishes /clock); never on the rover.
ROVER_USE_SIM_TIME=$(norm_bool "${ROVER_USE_SIM_TIME:-}" false)

# The orchestrator stack runs on this device only when navigation is requested here AND the
# platform bringup it drives is actually running. To run the stack on a companion controller
# instead, leave ROVER_START_NAVIGATION=false on this device.
START_ORCHESTRATOR=false
DISABLED_REASON=""
if [ "$ROVER_START_NAVIGATION" != true ]; then
  DISABLED_REASON="ROVER_START_NAVIGATION=false (navigation not requested on this device)"
elif [ "$ROVER_START_ROS_PLATFORM" != true ]; then
  DISABLED_REASON="ROVER_START_ROS_PLATFORM=false (no platform bringup to navigate with)"
else
  START_ORCHESTRATOR=true
fi

START_DRIVE_MODE=false
if [ "$ROVER_START_DRIVE_MODE" != true ]; then
  echo "Drive modes disabled (ROVER_START_DRIVE_MODE=false): the drive UI's joystick reaches nothing"
elif [ "$ROVER_START_ROS_PLATFORM" != true ]; then
  echo "Drive modes disabled: ROVER_START_ROS_PLATFORM=false (no platform to drive)"
else
  START_DRIVE_MODE=true
fi

# Idle rather than exit when nothing is enabled: `restart: always` would otherwise crash-loop
# this service. Changing any balenaCloud variable restarts the container, which re-reads them.
if [ "$START_ORCHESTRATOR" != true ] && [ "$START_DRIVE_MODE" != true ]; then
  echo "Orchestrator stack disabled: ${DISABLED_REASON}; idling (sshd on 24 stays up)"
  # Not `exec sleep infinity` here: exec would replace this shell, dropping the TERM trap and
  # orphaning sshd. Waiting on sshd idles just as well and keeps signals forwarded.
  wait "$SSHD_PID" || true
  terminate_children
  exit 0
fi

# Source ROS2 + workspace
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source /root/ros2_ws/rover_a1/install/setup.bash

# Join the Zenoh graph (as a client, see ROVER_ZENOH_MODE above). The router runs in
# rover-a1-zenoh-router; every service is network_mode: host, so it is reachable on loopback.
# Deliberately no ZENOH_ROUTER_CONFIG_URI here - a second router would fight the first one for
# port 7447.
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

# Kill any existing daemon (rmw_zenoh conflicts)
pkill -f ros2_daemon || true
sleep 1

ROVER_NAMESPACE=${ROVER_NAMESPACE:-}
# `namespace:=` only when there is one: `ros2 launch` rejects an empty `name:=` ("malformed launch
# argument") and exits at once, which would crash-loop this service on an unnamespaced rover
# (rover-a1-vda5050 did, 2026-09-28). The launch files default namespace to ROVER_NAMESPACE.
NAMESPACE_ARG=()
if [ -n "$ROVER_NAMESPACE" ]; then
  NAMESPACE_ARG=(namespace:="${ROVER_NAMESPACE}")
fi

# **Drive modes - Background** (before the Nav 2 gate: MANUAL and ASSISTED need no Nav 2).
if [ "$START_DRIVE_MODE" = true ]; then
  set -m  # own process group, so stop_launch_groups can signal its nodes
  nohup ros2 launch rover_drive_mode rover_drive_mode.launch.py \
    use_sim_time:="${ROVER_USE_SIM_TIME}" \
    "${NAMESPACE_ARG[@]}" \
    default_mode:="${ROVER_DRIVE_DEFAULT_MODE}" \
    > >(rotating_log /tmp/rover_drive_mode.log "$ROVER_LOG_MAX_BYTES" "$ROVER_LOG_BACKUP_COUNT") 2>&1 < /dev/null &
  DRIVE_MODE_PID=$!
  set +m
  LAUNCH_PGIDS+=("$DRIVE_MODE_PID")
  CHILD_PIDS+=("$DRIVE_MODE_PID")
  echo "Drive modes started in background (PID: $DRIVE_MODE_PID, boot mode: $ROVER_DRIVE_DEFAULT_MODE)"
fi

# Drive modes only: supervise them (and sshd) the same way as the full stack below.
if [ "$START_ORCHESTRATOR" != true ]; then
  echo "Nav 2 disabled: ${DISABLED_REASON}; running drive modes only (AUTOMATIC unavailable)"
  EXIT_CODE=0
  wait -n "${CHILD_PIDS[@]}" || EXIT_CODE=$?
  for entry in "sshd:$SSHD_PID" "rover_drive_mode:$DRIVE_MODE_PID"; do
    name=${entry%%:*}
    pid=${entry##*:}
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Supervised process '$name' (PID $pid) exited (code $EXIT_CODE)"
    fi
  done
  terminate_children
  exit "$EXIT_CODE"
fi

# Nav 2's global frame owner. ROVER_USE_GPS decides it by default - 'gps' means
# rover_ekf_global_node (rover-a1-platform) publishes map -> odom (needs
# ROVER_GPS_PUBLISH_MAP_TF=true), 'odom' means nobody does and navigation is odometry-relative.
# ROVER_LOCALIZATION_SOURCE overrides that, and is the only way to reach 'slam' (slam_toolbox),
# 'amcl' (nav2_amcl on ROVER_NAV_MAP) or 'indoor' (rover_indoor_nav_manager switches between
# the two at runtime from the drive UI, maps in /maps) - all require ROVER_USE_GPS=false or
# ROVER_GPS_PUBLISH_MAP_TF=false. Deliberately not auto-selected: flipping an existing
# odom-mode rover into amcl would hard-fail it, since amcl needs a map that odom never had.
if [ "$ROVER_USE_GPS" = true ]; then
  LOCALIZATION_SOURCE=gps
else
  LOCALIZATION_SOURCE=odom
fi
if [ -n "${ROVER_LOCALIZATION_SOURCE:-}" ]; then
  case "$ROVER_LOCALIZATION_SOURCE" in
    odom|gps|slam|amcl|indoor)
      LOCALIZATION_SOURCE="$ROVER_LOCALIZATION_SOURCE"
      ;;
    *)
      echo "WARNING: ROVER_LOCALIZATION_SOURCE='${ROVER_LOCALIZATION_SOURCE}' is not one of odom|gps|slam|amcl|indoor; using '${LOCALIZATION_SOURCE}'"
      ;;
  esac
fi
# Exactly one process may publish map -> odom. With ROVER_GPS_PUBLISH_MAP_TF=false the GPS
# global EKF still fuses but leaves map -> odom to slam_toolbox or AMCL.
if { [ "$LOCALIZATION_SOURCE" = slam ] || [ "$LOCALIZATION_SOURCE" = amcl ] || [ "$LOCALIZATION_SOURCE" = indoor ]; } \
   && [ "$ROVER_USE_GPS" = true ] && [ "$ROVER_GPS_PUBLISH_MAP_TF" = true ]; then
  echo "WARNING: localization_source=${LOCALIZATION_SOURCE} with ROVER_USE_GPS=true - ${LOCALIZATION_SOURCE} and rover_ekf_global_node would both publish map -> odom (set ROVER_GPS_PUBLISH_MAP_TF=false)"
fi
# AMCL matches the lidar scan against the static map; without a scan it never localizes and
# never publishes map -> odom, so Nav 2 cannot resolve its global frame at all. This is more
# severe than the generic "costmaps stay empty" warning further down.
if { [ "$LOCALIZATION_SOURCE" = amcl ] || [ "$LOCALIZATION_SOURCE" = indoor ]; } && [ "$ROVER_USE_LIDAR" != true ]; then
  echo "WARNING: localization_source=amcl with ROVER_USE_LIDAR=false - AMCL has no scan to match, will never localize, and nothing will publish map -> odom"
fi
if [ "$LOCALIZATION_SOURCE" = gps ] && [ "$ROVER_GPS_PUBLISH_MAP_TF" != true ]; then
  echo "WARNING: localization_source=gps with ROVER_GPS_PUBLISH_MAP_TF=false - nothing publishes map -> odom, so Nav 2 cannot resolve its global frame"
fi

# Both Nav 2 costmaps mark and clear from <namespace>/scan, and the navigation trees stop
# driving when the lidar diagnostics go bad.
if [ "$ROVER_USE_LIDAR" != true ]; then
  echo "WARNING: ROVER_USE_LIDAR=false - no lidar driver in rover-a1-sensors, so the costmaps stay empty and navigation drives blind"
fi
if [ "$ROVER_NAV_USE_CAMERA" = true ] && [ "$ROVER_USE_CAMERA" != true ]; then
  echo "WARNING: ROVER_NAV_USE_CAMERA=true but ROVER_USE_CAMERA=false - the local costmap waits on camera/depth/points, which nothing publishes"
fi

ROVER_NAV_MAP=${ROVER_NAV_MAP:-/root/ros2_ws/rover_a1/install/rover_navigation/share/rover_navigation/map/empty_world.yaml}

# The default map is 50x50 m of free space. Every AMCL particle scores identically against it,
# so the filter never converges and the rover reports a pose it has no evidence for. This is
# the single most likely amcl misconfiguration, hence its own check.
case "$LOCALIZATION_SOURCE:$ROVER_NAV_MAP" in
  amcl:*empty_world.yaml)
    echo "WARNING: localization_source=amcl with the default empty_world.yaml - AMCL cannot localize against an empty map. Build one first with ROVER_LOCALIZATION_SOURCE=slam, then set ROVER_NAV_MAP=/maps/map.yaml"
    ;;
esac

# **Nav 2 - Background**
# localization_source (and namespace, when set) are passed explicitly even though both launch
# files read the environment themselves: rover_mission_manager must be launched with the same
# localization_source as rover_navigation, and passing both proves they agree.
set -m  # own process group, so stop_launch_groups can signal its nodes
nohup ros2 launch rover_navigation bringup.launch.py \
  use_sim_time:="${ROVER_USE_SIM_TIME}" \
  "${NAMESPACE_ARG[@]}" \
  localization_source:="${LOCALIZATION_SOURCE}" \
  use_camera:="${ROVER_NAV_USE_CAMERA}" \
  map:="${ROVER_NAV_MAP}" \
  > >(rotating_log /tmp/rover_nav.log "$ROVER_LOG_MAX_BYTES" "$ROVER_LOG_BACKUP_COUNT") 2>&1 < /dev/null &
NAV_PID=$!
set +m
LAUNCH_PGIDS+=("$NAV_PID")
CHILD_PIDS+=("$NAV_PID")
echo "Nav 2 bringup started in background (PID: $NAV_PID, localization_source=$LOCALIZATION_SOURCE, map=$ROVER_NAV_MAP, camera costmap=$ROVER_NAV_USE_CAMERA)"

# **Mission manager - Background**
if [ "$ROVER_START_MISSION_MANAGER" = true ]; then
  set -m  # own process group, so stop_launch_groups can signal its nodes
  nohup ros2 launch rover_mission_manager rover_mission_manager.launch.py \
    use_sim_time:="${ROVER_USE_SIM_TIME}" \
    "${NAMESPACE_ARG[@]}" \
    localization_source:="${LOCALIZATION_SOURCE}" \
    > >(rotating_log /tmp/rover_mission_manager.log "$ROVER_LOG_MAX_BYTES" "$ROVER_LOG_BACKUP_COUNT") 2>&1 < /dev/null &
  MISSION_PID=$!
  set +m
  LAUNCH_PGIDS+=("$MISSION_PID")
  CHILD_PIDS+=("$MISSION_PID")
  echo "Mission manager started in background (PID: $MISSION_PID)"
else
  echo "Mission manager disabled (ROVER_START_MISSION_MANAGER=false); Nav 2 only"
fi

# **Supervise** - block until the first of the supervised processes exits (crash or
# otherwise), then tear down everything else and exit so docker-compose's `restart: always`
# (Balena) brings the whole stack back up cleanly.
#
# `|| EXIT_CODE=$?` rather than a bare `wait -n`: this script runs under `bash -e`, so a
# child exiting non-zero - the crash case this block exists to report - would otherwise kill
# the shell here, skipping the teardown and the log line naming what died.
EXIT_CODE=0
wait -n "${CHILD_PIDS[@]}" || EXIT_CODE=$?

STATUS_ENTRIES=("sshd:$SSHD_PID" "rover_navigation:$NAV_PID")
if [ "$START_DRIVE_MODE" = true ]; then
  STATUS_ENTRIES+=("rover_drive_mode:$DRIVE_MODE_PID")
fi
if [ "$ROVER_START_MISSION_MANAGER" = true ]; then
  STATUS_ENTRIES+=("rover_mission_manager:$MISSION_PID")
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
