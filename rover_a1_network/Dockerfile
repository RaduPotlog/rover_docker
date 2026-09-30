# rover-a1-network: web page to switch the RUTX11 Wi-Fi uplink in place and keep the
# firewall/NAT consistent, so the wired LAN and the rover AP keep internet. The application
# lives in https://github.com/RaduPotlog/rover_networking under rutx11/ (docs in its README);
# this directory only holds the container glue. No ROS in here.

##################################### Fetch + test ###########################################

FROM python:3.13-slim AS test

RUN apt-get update \
    && apt-get install --no-install-recommends -y git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Tracks the tip of `master` by default, so every `balena push --nocache` picks up the latest
# commit; pin a SHA with `--build-arg ROVER_NETWORKING_REF=<sha>` for a reproducible build.
# Same convention as ROVER_DRIVE_INTERFACE_REF / ROVER_ROS_REF in the other services.
ARG ROVER_NETWORKING_REF=master
RUN git clone https://github.com/RaduPotlog/rover_networking.git /src \
    && git -C /src checkout ${ROVER_NETWORKING_REF}

# The app is the rutx11/ folder of the repo.
WORKDIR /src/rutx11
RUN pip install --no-cache-dir -r requirements.txt -r requirements-test.txt \
    && python -m pytest -q -p no:cacheprovider \
    && touch /tmp/tests-passed

##################################### Runtime ################################################

FROM python:3.13-slim

# curl: healthcheck.
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=test /src/rutx11/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY --from=test /src/rutx11/uplink_manager ./uplink_manager
COPY --from=test /src/rutx11/icons ./icons
# Makes the build fail when the tests fail (an unused stage would otherwise be skipped).
COPY --from=test /tmp/tests-passed /tmp/tests-passed

# Unprivileged runtime user; start.sh hands it /data and drops to it.
RUN useradd --system --home /data --shell /usr/sbin/nologin netui

COPY start.sh healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh

EXPOSE 5080
CMD ["/usr/local/bin/start.sh"]
