#!/bin/bash
# Container healthcheck: cockpit-ws answers /ping on the configured port.
# Lives in the image rather than in docker-compose.yml, because balena's compose
# parser does not honour the `$$` escape: `$${ROVER_COCKPIT_PORT:-80}` reached the
# shell as `$$` (the PID) + literal text, curl rejected the port, the check never
# passed, and balenaEngine restarted the unhealthy container every minute or so.
# While start.sh idles on purpose (no ROVER_COCKPIT_PASSWORD, or root as the user) there is no
# cockpit-ws to ask; it leaves this marker so the idle container is not restarted as unhealthy,
# which would drop the SSH session on port 26 with it.
if [ -f /tmp/rover-cockpit-idle ]; then
  exit 0
fi
exec curl -fsS -o /dev/null "http://127.0.0.1:${ROVER_COCKPIT_PORT:-80}/ping"
