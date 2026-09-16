# rover-a1-orchestrator: the Rover A1 autonomy stack (Nav 2 + mission manager).
#
# Sibling of rover-a1-platform. That image owns the hardware (drivers, controllers,
# localization, safety) and runs the Zenoh router; this one owns navigation only and joins
# that router over host networking. Everything hardware-specific - rover_modbus,
# rover_cppuprofile, libpcap, dbus, sshd, the Claude Code / ros-mcp tooling - is deliberately
# absent here.
FROM ubuntu:26.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=lyrical

RUN apt-get update && apt-get install -y \
    curl wget gnupg2 lsb-release software-properties-common \
    build-essential git locales \
    && rm -rf /var/lib/apt/lists/*

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

##################################### Autonomy workspace #################################

RUN mkdir -p ~/ros2_ws/rover_a1
WORKDIR /root/ros2_ws/rover_a1

# Both repositories track their master branch by default, so every `--nocache` build picks
# up the latest commit; pin either with --build-arg. rover_ros is needed because
# rover_mission_manager depends on rover_utils (and rover_msgs transitively) - the hardware
# packages are never built, `--packages-up-to rover_autonomy` stops short of them.
ARG ROVER_ROS_REF=master
ARG ROVER_ORCHESTRATOR_REF=master
RUN git clone https://github.com/RaduPotlog/rover_ros.git src/rover_ros \
    && git -C src/rover_ros checkout ${ROVER_ROS_REF}
RUN git clone https://github.com/RaduPotlog/rover_orchestrator.git src/rover_orchestrator \
    && git -C src/rover_orchestrator checkout ${ROVER_ORCHESTRATOR_REF}

# pointcloud_crop_box - the self-filter for rover_navigation's `pointcloud` observation path.
# Source-only, so it cannot come from rosdep.
RUN vcs import src < src/rover_orchestrator/rover_autonomy/autonomy_deps.repos

RUN rosdep init
RUN rosdep update --rosdistro "${ROS_DISTRO}"
# Pulls the Nav 2 stack, slam_toolbox, spatio_temporal_voxel_layer and behaviortree_cpp.
RUN rosdep install --from-paths src --rosdistro "${ROS_DISTRO}" -y -i

RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build --symlink-install --packages-up-to rover_autonomy \
       --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
RUN echo "source /root/ros2_ws/rover_a1/install/setup.bash" >> /root/.bashrc

WORKDIR /root

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
CMD ["/usr/local/bin/start.sh"]
