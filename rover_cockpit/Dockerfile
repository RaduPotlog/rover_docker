##################################### Build the plugin #######################################

FROM node:24-slim AS build

# git: fetch the plugin source, and the Makefile fetches Cockpit's pkg/lib with git.
# make + gettext: the plugin's build (translations are compiled from po/).
RUN apt-get update \
    && apt-get install --no-install-recommends -y git make gettext ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Tracks the tip of `master` by default, so every `balena push --nocache` picks
# up the latest commit; pin to a specific SHA with
# `--build-arg ROVER_COCKPIT_REF=<sha>` for a reproducible build instead.
# Same convention as ROVER_ROS_REF in the other services.
# TEMPORARY (rover-clean-arch-ultra-code-effort-01): tracks that branch of
# rover_cockpit_ros2_diagnostics instead of master (it carries the Zenoh client-mode changes). Set
# back to master once merged (see README, "Temporary branch defaults").
ARG ROVER_COCKPIT_REF=rover-clean-arch-ultra-code-effort-01
RUN git clone https://github.com/RaduPotlog/rover_cockpit_ros2_diagnostics.git /src \
    && git -C /src checkout ${ROVER_COCKPIT_REF}

# Keep .git until make has run: the Makefile uses git to fetch Cockpit's lib files.
WORKDIR /src
RUN npm ci --no-audit --no-fund \
    && npm test \
    && NODE_ENV=production make

##################################### Runtime ################################################

FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

# cockpit-ws: web server + login. cockpit-bridge: the per-session backend.
# cockpit-system: provides the navigation shell the plugin loads into; its own
# pages (systemd, users, metrics) need systemd on the host and would only show
# broken pages or edit a throwaway container, so they are removed. With the
# plugin as the only menu entry, login lands straight on ROS 2 diagnostics.
# curl: healthcheck. iputils-ping: the ROS 2 Networking tab pings the rover's
# devices through cockpit.spawn (needs CAP_NET_RAW, see docker-compose.yml).
# dbus: a private system bus for the Cockpit shell (see start.sh); without one
# cockpit-bridge crashes when the page is reloaded.
RUN apt-get update \
    && apt-get install --no-install-recommends -y \
       cockpit-ws cockpit-bridge cockpit-system curl ca-certificates iputils-ping dbus \
    && rm -rf /var/lib/apt/lists/* \
       /usr/share/cockpit/systemd /usr/share/cockpit/users /usr/share/cockpit/metrics

# A root maintenance shell on port 26, the same arrangement as the other containers
# (root:root, sshd_config.d drop-in, UsePAM no); host networking gives every container one port
# space: platform 22, sensors 23, orchestrator 24, drive-interface 25, cockpit 26. Separate from
# Cockpit's own logins, which stay the ROVER_COCKPIT_USER account on port 80 (root is refused).
RUN apt-get update \
    && apt-get install --no-install-recommends -y openssh-server \
    && mkdir -p /run/sshd \
    && rm -rf /var/lib/apt/lists/*
RUN echo 'root:root' | chpasswd \
    && printf 'Port 26\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/rover_cockpit.conf

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

# pam_loginuid needs CAP_AUDIT_CONTROL, which an unprivileged container lacks;
# as `required` it rejects every login, so make it optional.
RUN sed -i 's/^session\s\+required\s\+pam_loginuid.so/session    optional     pam_loginuid.so/' /etc/pam.d/cockpit

# Installed under the plugin's package.json name.
COPY --from=build /src/dist /usr/share/cockpit/ros2-diagnostics

# Login-page branding: cockpit-ws picks /usr/share/cockpit/branding/<os-release ID>,
# so overwrite the stock Ubuntu logo/heading (and the default fallback) with ours.
COPY branding/ /usr/share/cockpit/branding/ubuntu/
COPY branding/ /usr/share/cockpit/branding/default/

COPY cockpit.conf /etc/cockpit/cockpit.conf
COPY start.sh /usr/local/bin/start.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh

# Documentation only - host networking ignores EXPOSE.
EXPOSE 80 26

CMD ["/usr/local/bin/start.sh"]
