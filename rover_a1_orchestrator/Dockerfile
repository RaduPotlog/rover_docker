# rover-a1-orchestrator: the Rover A1 autonomy stack (Nav 2 + mission manager).
#
# Sibling of rover-a1-platform. That image owns the hardware (drivers, controllers,
# localization, safety) and runs the Zenoh router; this one owns navigation only and joins
# that router over host networking. Everything hardware-specific - the Modbus stack,
# rover_cppuprofile, libpcap, dbus - is deliberately absent here. Two things are exceptions.
# An sshd, which listens on 2222 rather than 22: host networking puts this container in
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
# Port 2222, not 22: every service in docker-compose.yml is network_mode: host, so this
# container shares one port space with rover-a1-platform, whose sshd already binds 22.
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
    && printf 'Port 2222\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/rover_orchestrator.conf

# Documentation only - host networking ignores EXPOSE. Kept for parity with
# rover-a1-platform's `EXPOSE 22`.
EXPOSE 2222

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

# Baked into the image at build time, so the robot needs no PyPI fetch at runtime.
RUN uv tool install ros-mcp

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

# Both repositories track their master branch by default, so every `--nocache` build picks
# up the latest commit; pin either with --build-arg. rover_ros is cloned only for
# rover_utils, which rover_mission_manager and rover_navigation depend on - the hardware
# packages are never built, `--packages-up-to rover_autonomy` stops short of them.
ARG ROVER_ROS_REF=master
ARG ROVER_ORCHESTRATOR_REF=master
RUN git clone https://github.com/RaduPotlog/rover_ros.git src/rover_ros \
    && git -C src/rover_ros checkout ${ROVER_ROS_REF}
RUN git clone https://github.com/RaduPotlog/rover_orchestrator.git src/rover_orchestrator \
    && git -C src/rover_orchestrator checkout ${ROVER_ORCHESTRATOR_REF}

# pointcloud_crop_box - the self-filter for rover_navigation's `pointcloud` observation path.
# Source-only, so it cannot come from rosdep.
RUN vcs import src < src/rover_ros/rover_metapackage/${ROVER_ROS_BUILD_TYPE}_deps.repos

# autonomy_deps.repos also pins navigation2, for nav2_smac_planner - planner_server's
# GridBased plugin, and the one nav2_* package with no arm64 binary on lyrical/resolute.
# vcstool cannot express a sparse checkout, so prune the import down to that single package.
#
# Mandatory, not an optimization, for two independent reasons:
#   - rosdep resolves the `nav2_smac_planner` key to ros-${ROS_DISTRO}-nav2-smac-planner,
#     which does not exist on arm64. The -i below only skips it because the package is
#     present in src/, so without this checkout the rosdep layer fails outright.
#   - `--packages-up-to rover_autonomy` follows rover_navigation's exec_depends. Unpruned,
#     colcon finds 46 packages in this import instead of 1, so it rebuilds the whole Nav 2
#     stack from source on top of the debs, and rosdep resolves those packages' deps rather
#     than installing the debs at all - measured: ros-gz-bridge, nav2-minimal-tb3-sim,
#     nav2-minimal-tb4-sim and qt6-scxml-dev, in an image with no GUI and no simulator.
#
# src/navigation2, not src/third_party/navigation2: vcs import derives the directory from the
# .repos key. Folded into the same RUN as the import because Docker layers are additive -
# pruning in a later layer would leave the full tree committed in this one and reclaim nothing.
RUN vcs import src < src/rover_orchestrator/rover_autonomy/autonomy_deps.repos \
    && git -C src/navigation2 sparse-checkout init --cone \
    && git -C src/navigation2 sparse-checkout set nav2_smac_planner

RUN rosdep init
RUN rosdep update --rosdistro "${ROS_DISTRO}"
# Scan only what `--packages-up-to rover_autonomy` builds. src/rover_ros is cloned whole, but
# its hardware packages depend on source-only repos from hardware_deps.repos, which this image
# deliberately does not import - scanning them makes rosdep fail on [crsf_receiver_msg] and
# [rover_rslidar_sdk], and would drag in the hardware stack we are trying to leave out.
# src/rover_pointcloud_crop_box must stay listed so -i ignores its `pointcloud_crop_box` key.
# Pulls the Nav 2 stack, slam_toolbox, spatio_temporal_voxel_layer and behaviortree_cpp.
# nav2_smac_planner is the one exception: -i skips it because the pruned checkout above
# put it in src/, and colcon builds it from source instead.
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
