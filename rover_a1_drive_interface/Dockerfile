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

##################################### SSH ################################################

# Same arrangement as rover-a1-orchestrator / rover-a1-sensors: root password login through
# an sshd_config.d drop-in, only the port differs - 2223, because host networking shares one
# port space and 22 / 2222 / 222 belong to the platform, orchestrator and sensors sshds.
# Debian's stock sshd_config starts with `Include /etc/ssh/sshd_config.d/*.conf`, and the
# package's postinst generates the host keys. See README.md "Drive interface SSH".
RUN apt-get update \
    && apt-get install --no-install-recommends -y openssh-server \
    && mkdir -p /run/sshd \
    && rm -rf /var/lib/apt/lists/*

RUN echo 'root:root' | chpasswd \
    && printf 'Port 2223\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/rover_drive_interface.conf

COPY --from=build /src/dist /usr/share/nginx/drive
COPY nginx.conf.template /etc/nginx/drive.conf.template
COPY start.sh /usr/local/bin/start.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh

# Documentation only - host networking ignores EXPOSE.
EXPOSE 5000 2223

# Our own entrypoint instead of the image's template/envsubst machinery: it also writes
# the login and config.json, supervises sshd + nginx, and refuses to serve without a password.
ENTRYPOINT []
CMD ["/usr/local/bin/start.sh"]
