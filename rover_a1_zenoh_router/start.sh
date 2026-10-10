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

# Runs the Zenoh router as the container's main process (exec below), so balena restarts the
# container if the router ever exits.

# The router is reachable on loopback plus the rover LAN address only, so hosts on the rover LAN
# (setup_rover_pc.sh) can join the ROS 2 graph while balenaVPN and GSM stay closed (binding an
# address, not 0.0.0.0, is what keeps them out). Override per device/fleet with the
# ROVER_SYSTEM_LAN_IP balenaCloud variable.
ROVER_SYSTEM_LAN_IP=${ROVER_SYSTEM_LAN_IP:-192.168.1.201}

# Binding an address the host doesn't have makes rmw_zenohd exit, which would crash-loop the
# container. Give DHCP/NetworkManager a moment, then fall back to loopback only so the rover
# still runs locally.
ZENOH_LAN_ENDPOINT=""
for _ in $(seq 1 10); do
  if hostname -I | tr ' ' '\n' | grep -Fxq "$ROVER_SYSTEM_LAN_IP"; then
    ZENOH_LAN_ENDPOINT="\"tcp/${ROVER_SYSTEM_LAN_IP}:7447\","
    break
  fi
  sleep 1
done
if [ -z "$ZENOH_LAN_ENDPOINT" ]; then
  echo "WARNING: rover LAN address $ROVER_SYSTEM_LAN_IP not present; Zenoh router is loopback-only until the container restarts"
fi

source "/opt/ros/${ROS_DISTRO}/setup.bash"

# Configured with an override on top of rmw_zenoh's packaged router defaults, not with a
# ZENOH_ROUTER_CONFIG_URI file: a file replaces the whole configuration, so every key it leaves out
# falls back to zenoh's built-in default instead of the ROS defaults (lease, open/accept timeouts
# and session limits tuned for many nodes starting at once). The packaged defaults already turn
# multicast scouting off; LAN hosts connect to the router explicitly.
# ZENOH_CONFIG_OVERRIDE applies to rmw_zenohd too, so anything inherited is dropped first.
unset ZENOH_ROUTER_CONFIG_URI ZENOH_CONFIG_OVERRIDE
export ZENOH_CONFIG_OVERRIDE="listen/endpoints=[${ZENOH_LAN_ENDPOINT}\"tcp/127.0.0.1:7447\",\"tcp/[::1]:7447\"];connect/endpoints=[]"
echo "Starting Zenoh router: ZENOH_CONFIG_OVERRIDE=$ZENOH_CONFIG_OVERRIDE"
# The binary directly, not `ros2 run`: this image has no ros2cli.
exec "/opt/ros/${ROS_DISTRO}/lib/rmw_zenoh_cpp/rmw_zenohd"
