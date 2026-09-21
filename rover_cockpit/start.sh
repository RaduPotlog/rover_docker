#!/bin/bash -e
# Entrypoint of rover-cockpit: start sshd, set up the Cockpit login and its private D-Bus, then
# run cockpit-ws - supervising sshd and cockpit-ws together, like the other rover containers.

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

rm -f /tmp/rover-cockpit-idle

# **SSHD background (keep alive)** - started before the checks below, so the container is
# reachable even when Cockpit cannot start. Port 26 (set in the image's sshd_config drop-in):
# platform 22, sensors 23, orchestrator 24, drive-interface 25, cockpit 26.
mkdir -p /run/sshd  # privilege-separation dir; /run can start empty, like /run/dbus below
/usr/sbin/sshd -D &
SSHD_PID=$!
CHILD_PIDS+=("$SSHD_PID")
echo "sshd started on port 26 (PID: $SSHD_PID)"

# Idle (sshd only) rather than exit on a configuration error: `restart: always` would otherwise
# crash-loop the service and take the SSH session with it. Changing a balenaCloud variable
# restarts the container, which re-reads it here.
idle() {
  echo "$1; idling (sshd on 26 stays up)"
  touch /tmp/rover-cockpit-idle  # see healthcheck.sh
  wait "$SSHD_PID" || true
  terminate_children
  exit 0
}

# Cockpit login account for the ROS 2 diagnostics page. The password has no
# default on purpose: set ROVER_COCKPIT_PASSWORD as a balenaCloud service variable.
ROVER_COCKPIT_USER=${ROVER_COCKPIT_USER:-rover}
ROVER_COCKPIT_PORT=${ROVER_COCKPIT_PORT:-80}

if [ -z "${ROVER_COCKPIT_PASSWORD:-}" ]; then
  echo "ERROR: ROVER_COCKPIT_PASSWORD is not set. Set it as a balenaCloud service variable for rover-cockpit; refusing to start without a login password." >&2
  idle "Cockpit not started"
fi

# root is in /etc/cockpit/disallowed-users, so a normal account is required.
if [ "$ROVER_COCKPIT_USER" = root ]; then
  echo "ERROR: ROVER_COCKPIT_USER must not be root (Cockpit refuses root logins)." >&2
  idle "Cockpit not started"
fi

if ! id "$ROVER_COCKPIT_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$ROVER_COCKPIT_USER"
fi
# Re-applied on every start so a changed balenaCloud variable takes effect on restart.
echo "${ROVER_COCKPIT_USER}:${ROVER_COCKPIT_PASSWORD}" | chpasswd

mkdir -p /run/cockpit

# The diagnostics plugin reads the ROS namespace from /etc/clearpath/robot.yaml and
# subscribes to <namespace>/diagnostics_agg; without the file it asks for manual entry.
ROVER_NAMESPACE=${ROVER_NAMESPACE:-}
mkdir -p /etc/clearpath
if [ -n "$ROVER_NAMESPACE" ]; then
  echo "namespace: ${ROVER_NAMESPACE}" > /etc/clearpath/robot.yaml
  chmod 644 /etc/clearpath/robot.yaml
else
  rm -f /etc/clearpath/robot.yaml
fi

echo "Cockpit ROS 2 diagnostics on http port $ROVER_COCKPIT_PORT (user: $ROVER_COCKPIT_USER, namespace: ${ROVER_NAMESPACE:-<none>})"

# The Cockpit shell opens D-Bus channels on the system bus (e.g. hostname1). With no bus
# in the container, cockpit-bridge crashes on a page reload ("sd_bus_attach_event:
# Invalid argument", then "channel is already open") and the login ends in "Connection
# failed". Run a private system bus: missing services then just report not-found, and the
# page gets no access to the host's D-Bus.
mkdir -p /run/dbus
rm -f /run/dbus/pid
dbus-daemon --system --fork

# Extra allowed WebSocket origins, space separated, for when the ProtocolHeader in
# cockpit.conf is not enough (a proxy without X-Forwarded-Proto, a port-forwarded WAN IP).
# This list REPLACES Cockpit's same-host default, so it must also name every LAN origin
# still used, e.g. "https://<uuid>.balena-devices.com http://192.168.88.10".
if [ -n "${ROVER_COCKPIT_ORIGINS:-}" ]; then
  sed -i '/^Origins *=/d' /etc/cockpit/cockpit.conf
  sed -i "/^\[WebService\]/a Origins=${ROVER_COCKPIT_ORIGINS}" /etc/cockpit/cockpit.conf
  echo "Cockpit allowed origins: ${ROVER_COCKPIT_ORIGINS}"
fi

# Verbose cockpit-ws / session / bridge logging in the container log, to see why a
# session gets closed. Off by default: it logs every message.
if [ "${ROVER_COCKPIT_DEBUG:-false}" = true ]; then
  echo "ROVER_COCKPIT_DEBUG=true: verbose Cockpit logging enabled"
  export G_MESSAGES_DEBUG=cockpit-ws,cockpit-protocol
  export COCKPIT_DEBUG=all
fi

# Plain http (see cockpit.conf); every interface, like foxglove_bridge on 8765
# that the page connects to.
/usr/lib/cockpit/cockpit-ws --no-tls --port "$ROVER_COCKPIT_PORT" &
COCKPIT_PID=$!
CHILD_PIDS+=("$COCKPIT_PID")

# **Supervise** - block until the first supervised process exits, then tear down the other and
# exit so `restart: always` brings the whole container back. `|| EXIT_CODE=$?` because this
# script runs under `bash -e`, which would otherwise skip the teardown on a non-zero exit.
EXIT_CODE=0
wait -n "${CHILD_PIDS[@]}" || EXIT_CODE=$?

for entry in "sshd:$SSHD_PID" "cockpit-ws:$COCKPIT_PID"; do
  name=${entry%%:*}
  pid=${entry##*:}
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Supervised process '$name' (PID $pid) exited (code $EXIT_CODE)"
  fi
done

terminate_children
exit "$EXIT_CODE"
