FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# iputils-ping: the monitor shells out to `ping`; slim images do not ship it.
# git: needed to fetch the application source below.
RUN apt-get update \
    && apt-get install --no-install-recommends -y iputils-ping git \
    && rm -rf /var/lib/apt/lists/*

# Tracks the tip of `main` by default, so every `balena push --nocache` picks
# up the latest commit; pin to a specific SHA with
# `--build-arg ROVER_WEB_REF=<sha>` for a reproducible build instead.
# Same convention as ROVER_ROS_REF in rovera1_app/Dockerfile.
ARG ROVER_WEB_REF=main
RUN git clone https://github.com/RaduPotlog/rover_networking_web_server.git /src \
    && git -C /src checkout ${ROVER_WEB_REF} \
    && rm -rf /src/.git /src/cisco

# `app.main:app` is imported by package name, so the working directory has to
# be the parent of `app/`.
WORKDIR /src/webserver
RUN pip install --no-cache-dir -r requirements.txt

EXPOSE 80

# `python -m app` (not a direct uvicorn call) — ROVER_WEB_PORT is only read in
# app/__main__.py, so invoking uvicorn directly would silently ignore it.
CMD ["python", "-m", "app"]
