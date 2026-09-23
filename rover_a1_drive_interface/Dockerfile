##################################### Build the web app ######################################

FROM node:24-slim AS build

RUN apt-get update \
    && apt-get install --no-install-recommends -y git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Tracks the tip of `master` by default, so every `balena push --nocache` picks
# up the latest commit; pin to a specific SHA with
# `--build-arg ROVER_DRIVE_INTERFACE_REF=<sha>` for a reproducible build instead.
# Same convention as ROVER_COCKPIT_REF / ROVER_ROS_REF in the other services.
# TEMPORARY (feature/aux-io-portenta-dio): tracks the Aux IO popup branch instead of master,
# to match rover_ros on the same branch. Set back to master once both are merged.
ARG ROVER_DRIVE_INTERFACE_REF=feature/aux-io-portenta-dio
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
# an sshd_config.d drop-in, only the port differs - 25, because host networking shares one
# port space: platform 22, sensors 23, orchestrator 24, drive-interface 25, cockpit 26.
# Debian's stock sshd_config starts with `Include /etc/ssh/sshd_config.d/*.conf`, and the
# package's postinst generates the host keys. See README.md "Drive interface SSH".
RUN apt-get update \
    && apt-get install --no-install-recommends -y openssh-server \
    && mkdir -p /run/sshd \
    && rm -rf /var/lib/apt/lists/*

RUN echo 'root:root' | chpasswd \
    && printf 'Port 25\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/rover_drive_interface.conf

##################################### Claude Code + ros-mcp ##############################

# Same tooling as the other rover images (see rover_a1_orchestrator/Dockerfile), so `claude`
# with ros-mcp works on every container's SSH shell. Above the app layers so a web-app change
# does not rebuild these.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# fastmcp is held below 4 deliberately: ros-mcp 3.1.0 asks only for `fastmcp>=2.11.3`, but
# fastmcp 4 moved `fastmcp.tools.tool`, so an unconstrained install dies on import - which Claude
# Code reports only as a CONNECTION_CLOSED server. uv brings its own Python when the image has none.
RUN uv tool install ros-mcp --with "fastmcp<4"

# ros-mcp reaches rosbridge at 127.0.0.1:9090 in rover-a1-platform: every service is
# network_mode: host, so no rosbridge is needed here.
RUN claude mcp add ros-mcp --scope user -- ros-mcp --transport=stdio

# ENV PATH reaches `docker exec`, but sshd builds a fresh environment for login shells, so
# without this `ros-mcp` is off PATH over SSH and Claude fails to spawn the MCP server.
# profile.d as well as .bashrc: a login shell reads /etc/profile (-> profile.d) even when the
# base image ships no /root/.profile to source .bashrc.
RUN echo "export PATH=\"\$PATH:/root/.local/bin\"" >> /root/.bashrc \
    && echo 'export PATH="$PATH:/root/.local/bin"' > /etc/profile.d/rover-local-bin.sh

COPY --from=build /src/dist /usr/share/nginx/drive
COPY nginx.conf.template /etc/nginx/drive.conf.template
COPY start.sh /usr/local/bin/start.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh

# Documentation only - host networking ignores EXPOSE.
EXPOSE 5000 25

# Our own entrypoint instead of the image's template/envsubst machinery: it also writes
# the login and config.json, supervises sshd + nginx, and refuses to serve without a password.
ENTRYPOINT []
CMD ["/usr/local/bin/start.sh"]
