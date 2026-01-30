#!/bin/bash -e
set -x  # Debug logging for Balena

# SSHD background (keep alive)
 /usr/sbin/sshd -D &
SSHD_PID=$!

# Source ROS2 + workspace
source /opt/ros/jazzy/setup.bash
source /root/ros2_ws/rover_a1/install/setup.bash

# Wait for ROS master
sleep 3

# **FOREGROUND** foxglove_bridge as PID 1 (keeps container alive)
exec ros2 launch foxglove_bridge foxglove_bridge_launch.xml
