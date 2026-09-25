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

# Whether the GPS global EKF (rover_ekf_global_node) broadcasts map -> odom; read by
# rover_localization's publish_global_tf default. Unset or empty means false: SLAM or AMCL owns
# map -> odom while GPS is still fused (odometry/global keeps publishing). Set it true to let the
# global EKF publish map -> odom itself.
case "${ROVER_GPS_PUBLISH_MAP_TF:-false}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) ROVER_GPS_PUBLISH_MAP_TF=true ;;
  *) ROVER_GPS_PUBLISH_MAP_TF=false ;;
esac
export ROVER_GPS_PUBLISH_MAP_TF

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

# rover_crsf_teleop saves the measured RC stick calibration here (the rover-config named volume,
# see docker-compose.yml). Created up front so the first `apply` does not have to, and so an
# operator can drop a calibration in by hand before the node ever starts.
mkdir -p /config/rover_crsf_teleop

# Source ROS2 + workspace
source "/opt/ros/${ROS_DISTRO}/setup.bash"
source /root/ros2_ws/rover_a1/install/setup.bash

# **Zenoh session mode** for every ROS process this container starts (ROVER_ZENOH_MODE; unset or
# empty means client). client: each process opens one link, to the router in
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
if [ "$ROVER_START_ROS_PLATFORM" = true ]; then
  nohup ros2 launch rover_bringup rover_bringup.launch.py > /tmp/rover_bringup.log 2>&1 < /dev/null &
  ROVER_PID=$!
  CHILD_PIDS+=("$ROVER_PID")
  echo "Rover bringup started in background (PID: $ROVER_PID, ROVER_USE_GPS=$ROVER_USE_GPS, ROVER_GPS_PUBLISH_MAP_TF=$ROVER_GPS_PUBLISH_MAP_TF)"
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

STATUS_ENTRIES=("sshd:$SSHD_PID" "web_bridges:$BRIDGES_PID")
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
