##################################### Build the web app ######################################

FROM node:24-slim AS build

RUN apt-get update \
    && apt-get install --no-install-recommends -y git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Tracks the tip of `master` by default, so every `balena push --nocache` picks
# up the latest commit; pin to a specific SHA with
# `--build-arg ROVER_DRIVE_INTERFACE_REF=<sha>` for a reproducible build instead.
# Same convention as ROVER_COCKPIT_REF / ROVER_ROS_REF in the other services.
ARG ROVER_DRIVE_INTERFACE_REF=master
RUN git clone https://github.com/RaduPotlog/rover_drive_interface.git /src \
    && git -C /src checkout ${ROVER_DRIVE_INTERFACE_REF}

WORKDIR /src
RUN npm ci --no-audit --no-fund \
    && npm test \
    && npm run build

##################################### Runtime ################################################

# No ROS in here: the browser speaks the foxglove websocket protocol, and nginx only
# serves the page and proxies /ws to foxglove_bridge in rover-a1-platform.
FROM nginx:stable

# apache2-utils: htpasswd (bcrypt) for the login. curl: healthcheck.
RUN apt-get update \
    && apt-get install --no-install-recommends -y apache2-utils curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /src/dist /usr/share/nginx/drive
COPY nginx.conf.template /etc/nginx/drive.conf.template
COPY start.sh /usr/local/bin/start.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh

EXPOSE 5000

# Our own entrypoint instead of the image's template/envsubst machinery: it also writes
# the login and config.json, and refuses to start without a password.
ENTRYPOINT []
CMD ["/usr/local/bin/start.sh"]
