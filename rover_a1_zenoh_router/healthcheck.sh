#!/bin/bash
# Container healthcheck: the router accepts TCP connections on loopback. Lives in the image rather
# than in docker-compose.yml because balena's compose parser does not honour the `$$` escape (see
# rover_cockpit/healthcheck.sh).
exec 3<>/dev/tcp/127.0.0.1/7447
