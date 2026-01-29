FROM ubuntu:24.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Update and install essentials (ROS2-ready)
RUN apt-get update && apt-get install -y \
    curl wget gnupg lsb-release software-properties-common \
    build-essential git nano htop \
    && rm -rf /var/lib/apt/lists/*


RUN apt-get update && apt-get install -y openssh-server \
    && mkdir /var/run/sshd \
    && rm -rf /var/lib/apt/lists/*

# Configure SSH
RUN echo 'root:root' | chpasswd \
    && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/UsePAM yes/UsePAM no/' /etc/ssh/sshd_config

# Expose SSH port
EXPOSE 22

RUN add-apt-repository universe
RUN apt-get update
RUN apt-get install alsa-topology-conf
RUN apt-mark hold alsa-topology-conf

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
ENV LANG en_US.UTF-8

# Add ROS 2 apt repository
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null

SHELL ["/bin/bash", "-c"]

# Install ROS 2 Jazzy
RUN apt-get update && apt-get install -y \
    ros-dev-tools \
    ros-jazzy-desktop \
    && rm -rf /var/lib/apt/lists/*

RUN apt-get update && apt-get install -y \
    ros-jazzy-ament-cmake \
    python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*

# Source ROS 2 in bashrc
RUN echo "source /opt/ros/jazzy/setup.bash" >> /root/.bashrc
RUN source /opt/ros/jazzy/setup.bash

####################################### Install ROVER Firmware ##########################
RUN mkdir -p ~/ros2_ws/rover_a1
WORKDIR /root/ros2_ws/rover_a1
RUN git clone -b main https://github.com/RaduPotlog/rover_ros.git src/rover_ros
RUN echo "export ROVER_ROS_BUILD_TYPE=hardware" >> /root/.bashrc
RUN vcs import src < src/rover_ros/rover_metapackage/hardware_deps.repos
RUN apt-get update
RUN apt-get upgrade
RUN apt-get install -y usbutils
RUN apt-get install -y plocate
RUN rosdep init
ENV ROS_DISTRO=jazzy
ENV ROVER_ROS_BUILD_TYPE=hardware
RUN source /root/.bashrc
RUN rosdep update --rosdistro jazzy
RUN rosdep install --from-paths src -y -i

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
 
WORKDIR /root/ros2_ws/rover_a1/src/rover_cpplinux_serial
RUN mkdir build
WORKDIR /root/ros2_ws/rover_a1/src/rover_cpplinux_serial/build
RUN cmake ..
RUN make
RUN make install

RUN echo "export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/local/lib" >> /root/.bashrc

WORKDIR /root/ros2_ws/rover_a1
ENV ROVER_ROS_BUILD_TYPE=hardware
RUN apt-get install python3-pip
RUN pip3 install dalybms --break-system-packages
RUN source /root/.bashrc
RUN source /opt/ros/jazzy/setup.bash && colcon build --symlink-install --packages-up-to rover_metapackage --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
RUN echo "source /root/ros2_ws/rover_a1/install/setup.bash" >> /root/.bashrc
RUN source /root/ros2_ws/rover_a1/install/setup.bash

WORKDIR /root

RUN apt-get update
RUN apt-get upgrade
RUN apt-get install net-tools

WORKDIR /root

# Start SSH daemon directly (no systemd needed)
CMD ["/usr/sbin/sshd", "-D"]
#CMD ["/bin/bash"]
