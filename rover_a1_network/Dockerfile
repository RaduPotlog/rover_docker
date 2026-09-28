# rover-a1-network: web page to switch the RUTX11 Wi-Fi uplink (wan1) in place and keep the
# firewall/NAT consistent, so the wired LAN and the rover AP keep internet. See README.md.
# No ROS in here; built from this directory, not cloned.

##################################### Test ###################################################

FROM python:3.13-slim AS test
WORKDIR /app
COPY requirements.txt requirements-test.txt ./
RUN pip install --no-cache-dir -r requirements.txt -r requirements-test.txt
COPY pytest.ini ./
COPY uplink_manager ./uplink_manager
COPY test ./test
RUN python -m pytest -q -p no:cacheprovider && touch /tmp/tests-passed

##################################### Runtime ################################################

FROM python:3.13-slim

# curl: healthcheck.
RUN apt-get update \
    && apt-get install --no-install-recommends -y curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY uplink_manager ./uplink_manager
# Makes the build fail when the tests fail (an unused stage would otherwise be skipped).
COPY --from=test /tmp/tests-passed /tmp/tests-passed

# Unprivileged runtime user; start.sh hands it /data and drops to it.
RUN useradd --system --home /data --shell /usr/sbin/nologin netui

COPY start.sh healthcheck.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/start.sh /usr/local/bin/healthcheck.sh

EXPOSE 5080
CMD ["/usr/local/bin/start.sh"]
