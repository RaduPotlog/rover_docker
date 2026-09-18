# rover-a1-sensors: the Rover A1 sensor payload (GNSS, lidar) from the rover_sensors repo.
#
# Sibling of rover-a1-platform (base, controller, localization, safety; runs the Zenoh router)
# and rover-a1-orchestrator (Nav 2, mission manager). The payload is kept in its own image so a
# different GPS or lidar is a change to this image only: its drivers only publish (gps/fix,
# scan, rslidar_points, diagnostics) and nothing here depends on rover_ros or
# rover_orchestrator. Joins the platform's Zenoh router over host networking, which is also
# what lets the drivers receive the RUTX11 NMEA (UDP 10110) and the RS16 (UDP 6699/7788).
#
# Deliberately lean: no sshd, no Claude tooling. Use `balena ssh <device> rover-a1-sensors`
# (or the platform's shell, which sees the same ROS graph) to debug.
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

# ros-base, not desktop: no GUI here. rmw_zenoh_cpp matches the middleware rover-a1-platform's
# router speaks. libpcap-dev: rover_rs16_lidar's pcap replay input (rosdep would also install
# it; listed so the dependency is visible here).
RUN apt-get update && apt-get install -y \
    ros-dev-tools \
    ros-${ROS_DISTRO}-ros-base \
    ros-${ROS_DISTRO}-rmw-zenoh-cpp \
    ros-${ROS_DISTRO}-ament-cmake \
    python3-colcon-common-extensions \
    libpcap-dev \
    && rm -rf /var/lib/apt/lists/*

RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc
# No ZENOH_ROUTER_CONFIG_URI: this container is a Zenoh session, not a router. The router
# runs in rover-a1-platform and both share the host network namespace.
RUN echo "export RMW_IMPLEMENTATION=rmw_zenoh_cpp" >> /root/.bashrc

##################################### Sensors workspace ##################################

RUN mkdir -p ~/ros2_ws/rover_a1
WORKDIR /root/ros2_ws/rover_a1

# Tracks master by default, so every `--nocache` build picks up the latest commit; pin with
# --build-arg ROVER_SENSORS_REF=<ref>.
ARG ROVER_SENSORS_REF=master
RUN git clone https://github.com/RaduPotlog/rover_sensors.git src/rover_sensors \
    && git -C src/rover_sensors checkout ${ROVER_SENSORS_REF}

RUN vcs import src < src/rover_sensors/sensors_deps.repos

RUN rosdep init
RUN rosdep update --rosdistro "${ROS_DISTRO}"
# apt-get update in the same RUN: the layers above end with `rm -rf /var/lib/apt/lists/*`,
# and rosdep shells out to a bare `apt-get install` that needs the index.
RUN apt-get update \
    && rosdep install --from-paths src --rosdistro "${ROS_DISTRO}" -y -i \
    && rm -rf /var/lib/apt/lists/*

RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build --symlink-install --packages-up-to rover_sensors_bringup \
       --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
RUN echo "source /root/ros2_ws/rover_a1/install/setup.bash" >> /root/.bashrc

WORKDIR /root

COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
CMD ["/usr/local/bin/start.sh"]
