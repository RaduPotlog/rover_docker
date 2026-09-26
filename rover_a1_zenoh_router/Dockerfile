# rover-a1-zenoh-router: the Zenoh router (rmw_zenohd) every ROS process on the rover connects to.
#
# Its own service so it outlives the containers that use it. The ROS processes in
# rover-a1-orchestrator and rover-a1-sensors are Zenoh clients of this router, and
# rover-a1-platform's peers reach them through it (ROVER_ZENOH_MODE, see README.md), so all
# traffic between containers passes through it. It used to run inside rover-a1-platform, where
# it restarted whenever any platform process exited and on every platform image update, taking
# the whole graph down with it. This image only changes when the ROS release does, so a balena
# release leaves the router running.
#
# Deliberately minimal: no sshd, no workspace, no Claude tooling - one process. Use the platform's
# SSH (port 22) and `ros2` there to look at the graph.
FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO=lyrical

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

# ROS 2 apt repository, as in the other rover images.
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(. /etc/os-release && echo $UBUNTU_CODENAME) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null

# rmw_zenoh_cpp ships rmw_zenohd; the version matches what the other images install from the
# same repository, which is what the sessions and the router must agree on.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ros-${ROS_DISTRO}-rmw-zenoh-cpp \
    && rm -rf /var/lib/apt/lists/*

COPY start.sh /usr/local/bin/start.sh
COPY healthcheck.sh /usr/local/bin/healthcheck.sh
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh
CMD ["/usr/local/bin/start.sh"]
