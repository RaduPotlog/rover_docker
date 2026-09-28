#!/bin/bash
# Container healthcheck: the service answers /healthz (no login, does not touch the router).
# In the image rather than docker-compose.yml: balena's compose parser mangles `$$`.
# While start.sh idles on purpose (missing password) there is nothing to ask; it leaves this
# marker so balenaEngine does not restart the container over and over.
if [ -f /tmp/network-idle ]; then
  exit 0
fi
exec curl -fsS -o /dev/null "http://127.0.0.1:${NETUI_PORT:-5080}/healthz"
