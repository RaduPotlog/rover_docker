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

# Entrypoint of rover-a1-network. Serves the uplink page on NETUI_PORT (default 5080), or idles
# when a credential is missing: exiting would make `restart: always` crash-loop the service.

rm -f /tmp/network-idle

idle() {
  echo "$1; idling"
  touch /tmp/network-idle  # see healthcheck.sh
  trap 'exit 0' TERM INT  # PID 1: without a handler, `docker stop` waits for SIGKILL
  sleep infinity &
  wait
}

case "${ROVER_NETWORK_ENABLE:-true}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) ;;
  *) idle "Network page disabled (ROVER_NETWORK_ENABLE=${ROVER_NETWORK_ENABLE})" ;;
esac

# The page can re-point the rover's internet uplink; never serve it without a login.
if [ -z "${NETUI_PASSWORD:-}" ]; then
  echo "ERROR: NETUI_PASSWORD is not set - refusing to serve the network page without a login" >&2
  idle "Network page not served"
fi
if [ -z "${RUTX11_PASSWORD:-}" ]; then
  echo "ERROR: RUTX11_PASSWORD is not set - cannot log in to the router" >&2
  idle "Network page not served"
fi

export NETUI_DATA="${NETUI_DATA:-/data}"
export NETUI_BIND="${NETUI_BIND:-0.0.0.0}"
export NETUI_ICONS="${NETUI_ICONS:-/app/icons}"
mkdir -p "$NETUI_DATA"
chown -R netui:netui "$NETUI_DATA"

cd /app
exec setpriv --reuid=netui --regid=netui --init-groups python -m uplink_manager
