FROM ubuntu:24.04

# Avoid interactive prompts during build
ENV DEBIAN_FRONTEND=noninteractive

# Update and install essentials (ROS2-ready)
RUN apt-get update && apt-get install -y \
    curl wget gnupg lsb-release software-properties-common \
    build-essential git nano htop \
    && rm -rf /var/lib/apt/lists/*

RUN add-apt-repository universe
RUN apt-get update
RUN apt-get install alsa-topology-conf
RUN apt-mark hold alsa-topology-conf

RUN apt-get update && apt-get install -y \
    libavahi-client3 \
    avahi-utils \
    usbutils \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Phidgets admin and network server
RUN curl -fsSL https://www.phidgets.com/downloads/setup_linux | bash
RUN apt-get update
RUN apt-get -y install libphidget22 libphidget22-dev libphidget22extra
RUN apt-get -y install phidget22admin phidget22networkserver phidget22wwwjs

WORKDIR /root

CMD ["phidget22networkserver"]