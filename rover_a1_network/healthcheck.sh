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

# Container healthcheck: the service answers /healthz (no login, does not touch the router).
# In the image rather than docker-compose.yml: balena's compose parser mangles `$$`.
# While start.sh idles on purpose (missing password) there is nothing to ask; it leaves this
# marker so balenaEngine does not restart the container over and over.
if [ -f /tmp/network-idle ]; then
  exit 0
fi
exec curl -fsS -o /dev/null "http://127.0.0.1:${NETUI_PORT:-5080}/healthz"
