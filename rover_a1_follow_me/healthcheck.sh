#!/bin/bash
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

# rover-a1-follow-me health: the MQTT broker the follow master talks to accepts connections.
# Healthy when the service idles (ROVER_START_FOLLOW_ME false) - there is nothing to check, and
# an unhealthy container gets restarted by balenaEngine. The launch is supervised by start.sh,
# which exits (and so restarts the container) when it dies.

norm_bool() {
  case "${1:-$2}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) echo true ;;
    *) echo false ;;
  esac
}

if [ "$(norm_bool "${ROVER_START_FOLLOW_ME:-}" false)" != true ]; then
  exit 0
fi

exec 3<>/dev/tcp/"${ROVER_VDA5050_BROKER_HOST:-127.0.0.1}"/"${ROVER_VDA5050_BROKER_PORT:-1883}"
