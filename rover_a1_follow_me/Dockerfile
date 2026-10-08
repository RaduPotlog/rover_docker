# Copyright 2026 Mechatronics Academy
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# rover-a1-follow-me: follow-me for Rover A1.
#
# A follow-me algorithm (ROVER_FOLLOW_ME_ALGO, default fmoc: ADBSCAN on the RealSense depth cloud)
# tracks a person; the follow_me node runs following as one goal of Nav 2's Following server (in
# rover-a1-orchestrator), whose velocity goes through the velocity smoother, the collision monitor
# and drive mode like any Nav 2 motion. It never publishes cmd_vel. Like the other ROS services it
# joins rover-a1-zenoh-router over host networking, runs an sshd on its own port (27) and carries
# the Claude Code / ros-mcp tooling for parity with them.
FROM ubuntu:26.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=lyrical

RUN apt-get update && apt-get install -y \
    curl wget gnupg2 lsb-release software-properties-common \
    build-essential git locales \
    && rm -rf /var/lib/apt/lists/*

##################################### SSH ################################################

# Above the workspace layers, which are the expensive ones (see rover_a1_orchestrator).
#
# Port 27, not 22: every service in docker-compose.yml is network_mode: host, so they share
# one port space and each sshd gets its own port - platform 22, sensors 23, orchestrator 24,
# drive-interface 25, vda5050 26, follow-me 27.
RUN apt-get update && apt-get install -y openssh-server \
    && mkdir -p /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*

# Root password login, the same arrangement as rover-a1-platform and rover-a1-orchestrator.
RUN echo 'root:root' | chpasswd \
    && printf 'Port 27\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/rover_follow_me.conf

# Documentation only - host networking ignores EXPOSE.
EXPOSE 27

##################################### Claude Code CLI ####################################

# Same pair as rover-a1-orchestrator, above the workspace layers for the same reason.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

##################################### ros-mcp-server #####################################

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# fastmcp < 4: ros-mcp 3.1.0 dies on import with fastmcp 4 (see rover_a1_orchestrator).
RUN uv tool install ros-mcp --with "fastmcp<4"

# ros-mcp reaches rosbridge at 127.0.0.1:9090, served by rover-a1-platform (shared host network).
RUN claude mcp add ros-mcp --scope user -- ros-mcp --transport=stdio

##########################################################################################

RUN add-apt-repository universe

# Set up locale
RUN locale-gen en_US en_US.UTF-8 && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8

##################################### ROS2 install #######################################

# Add ROS 2 apt repository
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null

SHELL ["/bin/bash", "-c"]

# ros-base: no GUI. rmw_zenoh_cpp matches the middleware rover-a1-zenoh-router speaks.
RUN apt-get update && apt-get install -y \
    ros-dev-tools \
    ros-${ROS_DISTRO}-ros-base \
    ros-${ROS_DISTRO}-rmw-zenoh-cpp \
    ros-${ROS_DISTRO}-ament-cmake \
    python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*

RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc
# No ZENOH_ROUTER_CONFIG_URI: this container is a Zenoh client, not a router.
RUN echo "export RMW_IMPLEMENTATION=rmw_zenoh_cpp" >> /root/.bashrc
# ros2 CLI over SSH: the Zenoh client settings start.sh writes.
RUN echo '[ -r /tmp/rover_zenoh_cli.env ] && . /tmp/rover_zenoh_cli.env' >> /root/.bashrc
# sshd builds a fresh environment for login shells; keep ros-mcp on PATH there too.
RUN echo "export PATH=\"\$PATH:/root/.local/bin\"" >> /root/.bashrc

##################################### Follow-me workspace ################################

RUN mkdir -p ~/ros2_ws/rover_a1
WORKDIR /root/ros2_ws/rover_a1

# rover_follow_me carries everything follow-me: the FollowTarget contract (rover_follow_me_msgs),
# the follow_me node that runs following as a Nav 2 FollowObject goal (rover_follow_me_nav2), the
# algorithms (rover_fmoc) and the launch (rover_follow_me_bringup). The Following server itself
# runs with Nav 2 in rover-a1-orchestrator. rover_follow_me has a single branch, master
# (github.com/RaduPotlog/rover_follow_me); pin a commit with --build-arg ROVER_FOLLOW_ME_REF=<sha>.
ARG ROVER_FOLLOW_ME_REF=master
RUN git clone https://github.com/RaduPotlog/rover_follow_me.git src/rover_follow_me \
    && git -C src/rover_follow_me checkout ${ROVER_FOLLOW_ME_REF}
# rover_ros is cloned only for rover_msgs (drive_mode, mission_state); nothing else of it is built
# or rosdep-resolved. Keep ROVER_ROS_REF equal in rover_a1_platform, rover_a1_orchestrator,
# rover_a1_vda5050 and here.
ARG ROVER_ROS_REF=feature/rover_follow_me
RUN git clone https://github.com/RaduPotlog/rover_ros.git src/rover_ros \
    && git -C src/rover_ros checkout ${ROVER_ROS_REF}

RUN rosdep init
RUN rosdep update --rosdistro "${ROS_DISTRO}"
# apt-get update in the same RUN - rosdep does not refresh the index itself (see
# rover_a1_orchestrator). Brings python3-numpy, python3-scipy, sensor_msgs_py, tf2_ros_py,
# nav2_msgs, ...
RUN apt-get update \
    && rosdep install --from-paths src/rover_follow_me src/rover_ros/rover_msgs \
       --rosdistro "${ROS_DISTRO}" -y -i \
    && rm -rf /var/lib/apt/lists/*

RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build --symlink-install --packages-up-to rover_follow_me_bringup \
       --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
RUN echo "source /root/ros2_ws/rover_a1/install/setup.bash" >> /root/.bashrc

WORKDIR /root

COPY start.sh /usr/local/bin/start.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh
CMD ["/usr/local/bin/start.sh"]
