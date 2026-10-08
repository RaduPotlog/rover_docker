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

# Container healthcheck: nginx answers /healthz (no login) on the configured port.
# In the image rather than docker-compose.yml: balena's compose parser mangles `$$`.
#
# While start.sh idles on purpose (ROVER_DRIVE_ENABLE=false, or no ROVER_DRIVE_PASSWORD) there
# is no nginx to ask. It leaves this marker so the container is not reported unhealthy, which
# would make balenaEngine restart it and drop the SSH session with it.
if [ -f /tmp/drive-interface-idle ]; then
  exit 0
fi
exec curl -fsS -o /dev/null "http://127.0.0.1:${ROVER_DRIVE_PORT:-5000}/healthz"
