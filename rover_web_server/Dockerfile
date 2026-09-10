FROM node:24-slim

ENV NODE_ENV=production

# iputils-ping: the monitor shells out to `ping`; slim images do not ship it.
# git: needed to fetch the application source below.
RUN apt-get update \
    && apt-get install --no-install-recommends -y iputils-ping git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Tracks the tip of `master` by default, so every `balena push --nocache` picks
# up the latest commit; pin to a specific SHA with
# `--build-arg ROVER_WEB_REF=<sha>` for a reproducible build instead.
# Same convention as ROVER_ROS_REF in rovera1_app/Dockerfile.
ARG ROVER_WEB_REF=master
RUN git clone https://github.com/RaduPotlog/rover_networking_web_server.git /src \
    && git -C /src checkout ${ROVER_WEB_REF} \
    && rm -rf /src/.git /src/cisco

# The server resolves public/, resources/logos/ and src/*.json relative to its
# own files, but npm ci needs package.json, so work from webserver/.
WORKDIR /src/webserver
RUN npm ci --omit=dev --no-audit --no-fund

EXPOSE 80

# ROVER_WEB_PORT (set to 80 in docker-compose.yml) is read in src/server.js.
CMD ["node", "src/server.js"]
