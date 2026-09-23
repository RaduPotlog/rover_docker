# rover-a1-orchestrator: the Rover A1 autonomy stack (Nav 2 + mission manager).
#
# Sibling of rover-a1-platform. That image owns the hardware (drivers, controllers,
# localization, safety) and runs the Zenoh router; this one owns navigation only and joins
# that router over host networking. Everything hardware-specific - the Modbus stack,
# rover_cppuprofile, libpcap, dbus - is deliberately absent here. Two things are exceptions.
# An sshd, which listens on 24 rather than 22: host networking puts this container in
# rover-a1-platform's network namespace, where that image's sshd already owns 22. And the
# Claude Code / ros-mcp tooling, kept at parity with rover-a1-platform so `claude` behaves the
# same on either shell - it needs no rosbridge of its own, because that same shared namespace
# puts rover-a1-platform's on 127.0.0.1:9090.
FROM ubuntu:26.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=lyrical
ENV ROVER_ROS_BUILD_TYPE=hardware

RUN apt-get update && apt-get install -y \
    curl wget gnupg2 lsb-release software-properties-common \
    build-essential git locales \
    && rm -rf /var/lib/apt/lists/*

##################################### SSH ################################################

# Installed above the workspace layers on purpose: the git clone / rosdep / colcon build
# steps below are the expensive ones, so keeping sshd out of that churn preserves the cache.
#
# Port 24, not 22: every service in docker-compose.yml is network_mode: host, so they share
# one port space and each sshd gets its own port - platform 22, sensors 23, orchestrator 24,
# drive-interface 25, cockpit 26.
RUN apt-get update && apt-get install -y openssh-server \
    && mkdir -p /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*

# Root password login, the same arrangement rover-a1-platform uses (`root:root`,
# PermitRootLogin yes, UsePAM no) so both containers are reached the same way - only the port
# differs. See README.md "Orchestrator SSH" for the exposure this carries on the rover LAN.
#
# A drop-in rather than rover-a1-platform's sed edits: Ubuntu's stock sshd_config starts with
# `Include /etc/ssh/sshd_config.d/*.conf`, so this wins without depending on the exact
# commented-out text surviving an Ubuntu package update.
RUN echo 'root:root' | chpasswd \
    && printf 'Port 24\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/rover_orchestrator.conf

# Documentation only - host networking ignores EXPOSE. Kept for parity with
# rover-a1-platform's `EXPOSE 22`.
EXPOSE 24

##################################### Claude Code CLI ####################################

# Node.js (LTS) via NodeSource, then the Claude Code CLI - the same pair rover-a1-platform
# installs. Above the workspace layers for the reason the sshd block gives: the git clone /
# rosdep / colcon build steps below are the expensive ones. The cost of that placement is
# that bumping either tool invalidates the ROS and workspace layers under it.
#
# The NodeSource setup script runs its own apt-get update, so this works even though the
# layer above ends with `rm -rf /var/lib/apt/lists/*`.
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

##################################### ros-mcp-server #####################################

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Baked into the image at build time, so the robot needs no PyPI fetch at runtime. fastmcp is
# held below 4 deliberately: ros-mcp 3.1.0 asks only for `fastmcp>=2.11.3`, but fastmcp 4 moved
# `fastmcp.tools.tool` to `fastmcp.tools.base`, so an unconstrained install resolves fastmcp 4
# and ros-mcp dies on import with ModuleNotFoundError - which Claude Code reports only as a
# CONNECTION_CLOSED server. Drop the constraint once ros-mcp ships fastmcp 4 support; ros-mcp
# itself stays unpinned, so rebuilds still pick up new releases.
RUN uv tool install ros-mcp --with "fastmcp<4"

# Registered at user scope so it is available no matter which directory `claude` is started
# from over SSH. ros-mcp reaches rosbridge at 127.0.0.1:9090, which runs in
# rover-a1-platform - both services are network_mode: host and share one network namespace.
# This image runs no rosbridge of its own and needs none.
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

# ros-base, not desktop: this container has no GUI and no RViz. rmw_zenoh_cpp matches the
# middleware rover-a1-platform's router speaks.
RUN apt-get update && apt-get install -y \
    ros-dev-tools \
    ros-${ROS_DISTRO}-ros-base \
    ros-${ROS_DISTRO}-rmw-zenoh-cpp \
    ros-${ROS_DISTRO}-ament-cmake \
    python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*

RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc
# No ZENOH_ROUTER_CONFIG_URI: this container is a Zenoh session, not a router. The router
# runs in rover-a1-platform and both share the host network namespace.
RUN echo "export RMW_IMPLEMENTATION=rmw_zenoh_cpp" >> /root/.bashrc
# ENV PATH above reaches `docker exec`, but sshd builds a fresh environment for login shells,
# so without this `ros-mcp` is off PATH over SSH and Claude fails to spawn the MCP server.
RUN echo "export PATH=\"\$PATH:/root/.local/bin\"" >> /root/.bashrc

##################################### Autonomy workspace #################################

RUN mkdir -p ~/ros2_ws/rover_a1
WORKDIR /root/ros2_ws/rover_a1

# map_autosaver writes <map_directory>.yaml/.pgm here while slam_toolbox is running, and
# localization_source:=amcl reads the result back via ROVER_NAV_MAP. nav2's map_saver does
# not create parent directories, so the directory has to exist in the image. Mount a named
# volume over it (docker-compose.yml) or the map dies with the container.
RUN mkdir -p /maps

# Both repositories track their master branch by default, so every `--nocache` build picks
# up the latest commit; pin either with --build-arg. rover_ros is cloned only for
# rover_utils, which rover_mission_manager and rover_navigation depend on - the hardware
# packages are never built, `--packages-up-to rover_autonomy` stops short of them.
# TEMPORARY (feature/aux-io-portenta-dio): tracks the aux-IO feature branch of rover_ros
# instead of master. Set back to master once that branch is merged. Keep it equal in
# rover_a1_platform and rover_a1_orchestrator (see README, ROVER_ROS_REF).
ARG ROVER_ROS_REF=feature/aux-io-portenta-dio
ARG ROVER_ORCHESTRATOR_REF=master
RUN git clone https://github.com/RaduPotlog/rover_ros.git src/rover_ros \
    && git -C src/rover_ros checkout ${ROVER_ROS_REF}
RUN git clone https://github.com/RaduPotlog/rover_orchestrator.git src/rover_orchestrator \
    && git -C src/rover_orchestrator checkout ${ROVER_ORCHESTRATOR_REF}

# rover_ros's source-only dependencies (hardware_deps.repos: rover_cppuprofile). Imported so
# rosdep can resolve every package in src/rover_ros; none of them is built here.
RUN vcs import src < src/rover_ros/rover_metapackage/${ROVER_ROS_BUILD_TYPE}_deps.repos

# autonomy_deps.repos brings pointcloud_crop_box - the self-filter for rover_navigation's
# `pointcloud` observation path, source-only so it cannot come from rosdep. Every nav2_*
# package, nav2_smac_planner included, is an arm64 deb and comes from the rosdep pass below.
RUN vcs import src < src/rover_orchestrator/rover_autonomy/autonomy_deps.repos

RUN rosdep init
RUN rosdep update --rosdistro "${ROS_DISTRO}"
# Scans all of src/: src/rover_ros is cloned whole, so rosdep also installs the apt
# dependencies of its hardware packages even though colcon never builds them. The lidar and
# GPS drivers are not in rover_ros any more (they are the rover_sensors payload, built by
# rover-a1-sensors). src/rover_pointcloud_crop_box must stay in src/ so -i ignores its
# `pointcloud_crop_box` key.
# Pulls the Nav 2 stack (nav2_smac_planner and nav2_amcl included), slam_toolbox,
# spatio_temporal_voxel_layer and behaviortree_cpp. nav2_amcl arrives because
# rover_navigation declares it - localization_source:=amcl launches it - so it needs no
# entry here, but it does need an image rebuild to appear.
#
# apt-get update belongs in this same RUN: the ros-base layer above ends with
# `rm -rf /var/lib/apt/lists/*`, and rosdep does not refresh the index itself - it shells out
# to a bare `apt-get install -y <pkg>`, once per package. With no lists the first package it
# reaches dies on `E: Unable to locate package ros-${ROS_DISTRO}-...` and takes the build with
# it. Same RUN rather than a separate update layer, so the two can never cache out of step.
RUN apt-get update \
    && rosdep install --from-paths src --rosdistro "${ROS_DISTRO}" -y -i \
    && rm -rf /var/lib/apt/lists/*

RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build --symlink-install --packages-up-to rover_autonomy \
       --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
RUN echo "source /root/ros2_ws/rover_a1/install/setup.bash" >> /root/.bashrc

WORKDIR /root

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
CMD ["/usr/local/bin/start.sh"]
