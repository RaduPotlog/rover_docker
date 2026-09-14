#!/bin/bash -e

# Cockpit login account for the ROS 2 diagnostics page. The password has no
# default on purpose: set COCKPIT_PASSWORD as a balenaCloud service variable.
COCKPIT_USER=${COCKPIT_USER:-rover}
COCKPIT_PORT=${COCKPIT_PORT:-9091}

if [ -z "${COCKPIT_PASSWORD:-}" ]; then
  echo "ERROR: COCKPIT_PASSWORD is not set. Set it as a balenaCloud service variable for rover-cockpit; refusing to start without a login password."
  exit 1
fi

# root is in /etc/cockpit/disallowed-users, so a normal account is required.
if [ "$COCKPIT_USER" = root ]; then
  echo "ERROR: COCKPIT_USER must not be root (Cockpit refuses root logins)."
  exit 1
fi

if ! id "$COCKPIT_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$COCKPIT_USER"
fi
# Re-applied on every start so a changed balenaCloud variable takes effect on restart.
echo "${COCKPIT_USER}:${COCKPIT_PASSWORD}" | chpasswd

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

echo "Cockpit ROS 2 diagnostics on http port $COCKPIT_PORT (user: $COCKPIT_USER, namespace: ${ROVER_NAMESPACE:-<none>})"

# exec: cockpit-ws becomes PID 1 and receives the container's stop signals.
# Plain http (see cockpit.conf); every interface, like foxglove_bridge on 8765
# that the page connects to.
exec /usr/lib/cockpit/cockpit-ws --no-tls --port "$COCKPIT_PORT"
