#!/bin/bash
# Container healthcheck: cockpit-ws answers /ping on the configured port.
# Lives in the image rather than in docker-compose.yml, because balena's compose
# parser does not honour the `$$` escape: `$${ROVER_COCKPIT_PORT:-80}` reached the
# shell as `$$` (the PID) + literal text, curl rejected the port, the check never
# passed, and balenaEngine restarted the unhealthy container every minute or so.
exec curl -fsS -o /dev/null "http://127.0.0.1:${ROVER_COCKPIT_PORT:-80}/ping"
