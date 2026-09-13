FROM ubuntu:26.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=lyrical

# Update and install essentials (ROS2-ready)
RUN apt-get update && apt-get install -y \
    curl wget gnupg lsb-release software-properties-common \
    build-essential git nano htop \
    && rm -rf /var/lib/apt/lists/*

##################################### Claude Code CLI #######################################

# Install Node.js (LTS) via NodeSource, then the Claude Code CLI
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

##################################### ros-mcp-server #########################

RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

# Bake the package into the image at build time (no PyPI fetch needed at
# runtime on the robot).
RUN uv tool install ros-mcp

# Register with Claude Code, scoped to the user so it's available no
# matter which directory `claude` is started from over SSH.
RUN claude mcp add ros-mcp --scope user -- ros-mcp --transport=stdio

RUN apt-get update && apt-get install -y openssh-server \
    && mkdir -p /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*

# Configure SSH
RUN echo 'root:root' | chpasswd \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

# Expose SSH port
EXPOSE 22

RUN add-apt-repository universe
RUN apt-get update && apt-get install -y alsa-topology-conf \
    && apt-mark hold alsa-topology-conf \
    && rm -rf /var/lib/apt/lists/*

##################################### ROS2 install #######################################

WORKDIR /root

RUN apt-get update && apt-get install -y \
    locales \
    curl \
    gnupg2 \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Set up locale
RUN locale-gen en_US en_US.UTF-8 && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8

# Add ROS 2 apt repository
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null

SHELL ["/bin/bash", "-c"]

# Install ROS 2 Lyrical
RUN apt-get update && apt-get install -y \
    ros-dev-tools \
    ros-${ROS_DISTRO}-desktop \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y \
    ros-${ROS_DISTRO}-ament-cmake \
    python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*

# rosbridge (websocket + rosapi) — required by ros-mcp-server for ROS
# introspection/control; the full suite pulls in rosapi as a dependency.
RUN apt-get update && apt-get install -y \
    ros-${ROS_DISTRO}-rosbridge-suite \
    && rm -rf /var/lib/apt/lists/*

# Source ROS 2 in bashrc
RUN echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >> /root/.bashrc
RUN echo "export RMW_IMPLEMENTATION=rmw_zenoh_cpp" >> /root/.bashrc
RUN echo "export ZENOH_ROUTER_CONFIG_URI=/tmp/router.json5" >> /root/.bashrc
RUN echo "export PATH=\"\$PATH:/root/.local/bin\"" >> /root/.bashrc

####################################### Install ROVER Firmware ##########################
RUN apt-get update
RUN apt-get install -y libyaml-cpp-dev
RUN apt-get install -y libpcap-dev

RUN mkdir -p ~/ros2_ws/rover_a1
WORKDIR /root/ros2_ws/rover_a1

# Tracks the tip of the `lyrical` branch by default, so every `--nocache`
# build (see README) picks up the latest commit; pin to a specific SHA with
# `--build-arg ROVER_ROS_REF=<sha>` to pin the rover source instead.
# Imported dependencies and package versions remain independently versioned.
ARG ROVER_ROS_REF=lyrical
RUN git clone https://github.com/RaduPotlog/rover_ros.git src/rover_ros \
    && git -C src/rover_ros checkout ${ROVER_ROS_REF}
RUN echo "export ROVER_ROS_BUILD_TYPE=hardware" >> /root/.bashrc
RUN vcs import src < src/rover_ros/rover_metapackage/hardware_deps.repos
RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y usbutils plocate \
    && rm -rf /var/lib/apt/lists/*
RUN add-apt-repository universe
RUN apt-get update
RUN rosdep init
ENV ROVER_ROS_BUILD_TYPE=hardware
RUN rosdep update --rosdistro "${ROS_DISTRO}"
RUN rosdep install --from-paths src --rosdistro "${ROS_DISTRO}" -y -i

WORKDIR /root/ros2_ws/rover_a1/src/rover_cppuprofile
RUN cmake -Bbuild . -DPROFILE_ENABLED=OFF
RUN cmake --build build
WORKDIR /root/ros2_ws/rover_a1/src/rover_cppuprofile/build
RUN make install

WORKDIR /root/ros2_ws/rover_a1/src/rover_modbus
RUN apt-get install -y libnet1-dev
RUN cmake -Bbuild .
RUN cmake --build build
WORKDIR /root/ros2_ws/rover_a1/src/rover_modbus/build
RUN make install

RUN apt-get update && apt-get install -y libzmq3-dev sqlite3 \
    && rm -rf /var/lib/apt/lists/*
# BehaviorTree.CPP comes only from apt (ros-lyrical-behaviortree-cpp, installed by rosdep for
# rover_safety). Do not also build a copy into /usr/local: rover_safety compiles against the
# /opt/ros headers, and a second, different-version libbehaviortree_cpp.so on the library
# path segfaults both safety nodes at startup (ABI mismatch) - which kills the LEDs.

RUN echo "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib" >> /root/.bashrc

WORKDIR /root/ros2_ws/rover_a1
ENV ROVER_ROS_BUILD_TYPE=hardware
RUN source /opt/ros/${ROS_DISTRO}/setup.bash && colcon build --symlink-install --packages-up-to rover_metapackage --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
RUN echo "source /root/ros2_ws/rover_a1/install/setup.bash" >> /root/.bashrc

WORKDIR /root

RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y net-tools \
    && rm -rf /var/lib/apt/lists/*

# Start SSH daemon directly (no systemd needed)
COPY start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh
CMD ["/usr/local/bin/start.sh"]
