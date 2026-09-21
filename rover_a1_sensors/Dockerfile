# rover-a1-sensors: the Rover A1 sensor payload (GNSS, lidar) from the rover_sensors repo.
#
# Sibling of rover-a1-platform (base, controller, localization, safety; runs the Zenoh router)
# and rover-a1-orchestrator (Nav 2, mission manager). The payload is kept in its own image so a
# different GPS or lidar is a change to this image only: its drivers only publish (gps/fix,
# scan, rslidar_points, diagnostics) and nothing here depends on rover_ros or
# rover_orchestrator. Joins the platform's Zenoh router over host networking, which is also
# what lets the drivers receive the RUTX11 NMEA (UDP 10110) and the RS16 (UDP 6699/7788).
#
# Deliberately lean apart from two things. An sshd on 222 (22 is rover-a1-platform's, 2222 is
# rover-a1-orchestrator's - host networking gives all three one port space). And the Claude
# Code / ros-mcp tooling, kept at parity with the other two ROS images so `claude` behaves the
# same on any of the three shells; as in rover-a1-orchestrator it needs no rosbridge of its
# own, because that shared namespace puts rover-a1-platform's on 127.0.0.1:9090.
FROM ubuntu:26.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=lyrical

RUN apt-get update && apt-get install -y \
    curl wget gnupg2 lsb-release software-properties-common \
    build-essential git locales \
    && rm -rf /var/lib/apt/lists/*

##################################### SSH ################################################

# Above the ROS and workspace layers so the expensive clone / rosdep / colcon steps below
# keep their cache. Same arrangement as rover-a1-orchestrator: root password login through an
# sshd_config.d drop-in, only the port differs. See README.md "Sensors SSH".
RUN apt-get update && apt-get install -y openssh-server \
    && mkdir -p /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*

RUN echo 'root:root' | chpasswd \
    && printf 'Port 222\nPermitRootLogin yes\nUsePAM no\n' \
       > /etc/ssh/sshd_config.d/rover_sensors.conf

# Documentation only - host networking ignores EXPOSE.
EXPOSE 222

##################################### Claude Code CLI ####################################

# Node.js (LTS) via NodeSource, then the Claude Code CLI - the same pair rover-a1-platform and
# rover-a1-orchestrator install. Above the ROS and workspace layers for the reason the sshd
# block gives: the git clone / rosdep / colcon build steps below are the expensive ones. The
# cost of that placement is that bumping either tool invalidates those layers under it.
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
# from over SSH. ros-mcp reaches rosbridge at 127.0.0.1:9090, which runs in rover-a1-platform -
# all three ROS services are network_mode: host and share one network namespace. This image
# runs no rosbridge of its own and needs none.
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
# ENV PATH above reaches `docker exec`, but sshd builds a fresh environment for login shells,
# so without this `ros-mcp` is off PATH over SSH and Claude fails to spawn the MCP server.
RUN echo "export PATH=\"\$PATH:/root/.local/bin\"" >> /root/.bashrc

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
