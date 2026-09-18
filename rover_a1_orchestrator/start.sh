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

# **SSHD background (keep alive)** - started before the enable/disable gate below, because a
# shell is most useful exactly when the orchestrator is idling and there is no Nav 2 to
# inspect. Credentials are the image's (root password), as in rover-a1-platform.
#
# Port 2222 (set in the image's sshd_config drop-in), not 22: host networking shares one port
# space with rover-a1-platform, whose sshd owns 22.
/usr/sbin/sshd -D &
SSHD_PID=$!
CHILD_PIDS+=("$SSHD_PID")
echo "sshd started on port 2222 (PID: $SSHD_PID)"

# Normalize a balenaCloud boolean the same way rover-a1-platform's start.sh does: unset or
# empty falls back to $2, and anything that is not true/1/yes/on (any case) is false.
norm_bool() {
  case "${1:-$2}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) echo true ;;
    *) echo false ;;
  esac
}

ROVER_START_ROVER_ROS=$(norm_bool "${ROVER_START_ROVER_ROS:-}" true)
ROVER_START_NAV_BRINGUP=$(norm_bool "${ROVER_START_NAV_BRINGUP:-}" false)
ROVER_START_MISSION_MANAGER=$(norm_bool "${ROVER_START_MISSION_MANAGER:-}" true)
ROVER_USE_GPS=$(norm_bool "${ROVER_USE_GPS:-}" false)
ROVER_USE_LIDAR=$(norm_bool "${ROVER_USE_LIDAR:-}" false)

# The orchestrator stack runs on this device only when navigation is requested here AND the
# platform bringup it drives is actually running. To run the stack on a companion controller
# instead, leave ROVER_START_NAV_BRINGUP=false on this device.
START_ORCHESTRATOR=false
DISABLED_REASON=""
if [ "$ROVER_START_NAV_BRINGUP" != true ]; then
  DISABLED_REASON="ROVER_START_NAV_BRINGUP=false (navigation not requested on this device)"
elif [ "$ROVER_START_ROVER_ROS" != true ]; then
  DISABLED_REASON="ROVER_START_ROVER_ROS=false (no platform bringup to navigate with)"
else
  START_ORCHESTRATOR=true
fi

# Idle rather than exit when disabled: `restart: always` would otherwise crash-loop this
# service. Changing any balenaCloud variable restarts the container, which re-reads them here.
if [ "$START_ORCHESTRATOR" != true ]; then
  echo "Orchestrator stack disabled: ${DISABLED_REASON}; idling (sshd on 2222 stays up)"
  # Not `exec sleep infinity` here: exec would replace this shell, dropping the TERM trap and
  # orphaning sshd. Waiting on sshd idles just as well and keeps signals forwarded.
  wait "$SSHD_PID" || true
  terminate_children
  exit 0
fi

# Nav 2's global frame owner. ROVER_USE_GPS decides it by default - 'gps' means
# rover_ekf_global_node (rover-a1-platform) publishes map -> odom, 'odom' means nobody does
# and navigation is odometry-relative. ROVER_LOCALIZATION_SOURCE overrides that, and is the
# only way to reach 'slam' (slam_toolbox, which requires ROVER_USE_GPS=false).
if [ "$ROVER_USE_GPS" = true ]; then
  LOCALIZATION_SOURCE=gps
else
  LOCALIZATION_SOURCE=odom
fi
if [ -n "${ROVER_LOCALIZATION_SOURCE:-}" ]; then
  case "$ROVER_LOCALIZATION_SOURCE" in
    odom|gps|slam)
      LOCALIZATION_SOURCE="$ROVER_LOCALIZATION_SOURCE"
      ;;
    *)
      echo "WARNING: ROVER_LOCALIZATION_SOURCE='${ROVER_LOCALIZATION_SOURCE}' is not one of odom|gps|slam; using '${LOCALIZATION_SOURCE}'"
      ;;
  esac
fi
if [ "$LOCALIZATION_SOURCE" = slam ] && [ "$ROVER_USE_GPS" = true ]; then
  echo "WARNING: localization_source=slam with ROVER_USE_GPS=true - slam_toolbox and rover_ekf_global_node would both publish map -> odom"
fi

# Both Nav 2 costmaps mark and clear from <namespace>/scan, and the navigation trees stop
# driving when the lidar diagnostics go bad.
if [ "$ROVER_USE_LIDAR" != true ]; then
  echo "WARNING: ROVER_USE_LIDAR=false - no lidar driver in rover-a1-platform, so the costmaps stay empty and navigation drives blind"
fi

# Source ROS2 + workspace
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source /root/ros2_ws/rover_a1/install/setup.bash

# Join the Zenoh graph as a session. The router itself runs in rover-a1-platform; both
# containers are network_mode: host, so it is reachable on loopback. Deliberately no
# ZENOH_ROUTER_CONFIG_URI here - a second router would fight the first one for port 7447.
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

# Kill any existing daemon (rmw_zenoh conflicts)
pkill -f ros2_daemon || true
sleep 1

ROVER_NAMESPACE=${ROVER_NAMESPACE:-}
ROVER_NAV_MAP=${ROVER_NAV_MAP:-/root/ros2_ws/rover_a1/install/rover_navigation/share/rover_navigation/map/empty_world.yaml}

# **Nav 2 - Background**
# namespace and localization_source are passed explicitly even though both launch files read
# ROVER_NAMESPACE themselves: rover_mission_manager must be launched with the same
# localization_source as rover_navigation, and passing both proves they agree.
nohup ros2 launch rover_navigation bringup.launch.py \
  use_sim_time:=False \
  namespace:="${ROVER_NAMESPACE}" \
  localization_source:="${LOCALIZATION_SOURCE}" \
  map:="${ROVER_NAV_MAP}" \
  > /tmp/rover_nav.log 2>&1 < /dev/null &
NAV_PID=$!
CHILD_PIDS+=("$NAV_PID")
echo "Nav 2 bringup started in background (PID: $NAV_PID, localization_source=$LOCALIZATION_SOURCE, map=$ROVER_NAV_MAP)"

# **Mission manager - Background**
if [ "$ROVER_START_MISSION_MANAGER" = true ]; then
  nohup ros2 launch rover_mission_manager rover_mission_manager.launch.py \
    use_sim_time:=False \
    namespace:="${ROVER_NAMESPACE}" \
    localization_source:="${LOCALIZATION_SOURCE}" \
    > /tmp/rover_mission_manager.log 2>&1 < /dev/null &
  MISSION_PID=$!
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
