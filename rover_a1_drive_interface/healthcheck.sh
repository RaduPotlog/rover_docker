#!/bin/bash
# Container healthcheck: nginx answers /healthz (no login) on the configured port.
# In the image rather than docker-compose.yml: balena's compose parser mangles `$$`
# (see rover_cockpit/healthcheck.sh).
exec curl -fsS -o /dev/null "http://127.0.0.1:${ROVER_DRIVE_PORT:-5000}/healthz"
