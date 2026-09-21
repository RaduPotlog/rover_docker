#!/bin/bash
# Container healthcheck: nginx answers /healthz (no login) on the configured port.
# In the image rather than docker-compose.yml: balena's compose parser mangles `$$`
# (see rover_cockpit/healthcheck.sh).
#
# While start.sh idles on purpose (ROVER_DRIVE_ENABLE=false, or no ROVER_DRIVE_PASSWORD) there
# is no nginx to ask. It leaves this marker so the container is not reported unhealthy, which
# would make balenaEngine restart it and drop the SSH session with it.
if [ -f /tmp/drive-interface-idle ]; then
  exit 0
fi
exec curl -fsS -o /dev/null "http://127.0.0.1:${ROVER_DRIVE_PORT:-5000}/healthz"
