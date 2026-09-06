# rover_docker — Review Notes (2026-09-04)

Review of `Dockerfile`, `docker-compose.yml`, and `start.sh`. Kept for
later implementation — nothing here has been applied yet.

## Security — fix first

- **`Dockerfile:18-20`** — SSH is configured with `root:root` and
  `PermitRootLogin yes`. Combined with `network_mode: host` +
  `privileged: true` in `docker-compose.yml`, this binds an SSH server
  with a default root password directly onto the host's network
  interfaces — anyone on the LAN/VPN that can reach port 22 can log in
  as root.
  - Fix option A: switch to authorized-key-only auth
    (`PasswordAuthentication no` + inject a public key at build/deploy
    time via build-arg or bind mount).
  - Fix option B: if a password is still wanted, inject it via
    build-arg/secret at deploy time instead of hardcoding it in the
    image.

## Reproducibility / build hygiene

- **`Dockerfile:82-84` and `Dockerfile:122-124`** — `apt-get upgrade -y`
  runs twice mid-build. Upgrading base packages inside the Dockerfile
  fights the reproducibility already gained from pinning
  `ROVER_ROS_REF` — a rebuild months later can silently pull a
  different set of package versions. Consider dropping `upgrade` and
  pinning the base image digest instead if reproducibility matters.

## Minor / cosmetic

- **`Dockerfile:43`** — `ENV LANG en_US.UTF-8` uses the legacy no-`=`
  syntax; current Docker prefers `ENV LANG=en_US.UTF-8`. Cosmetic only,
  still works.
- **`Dockerfile:23`** — `EXPOSE 22` is a no-op since
  `docker-compose.yml` uses `network_mode: host` (host networking
  ignores `EXPOSE`/port publishing). Harmless but misleading — could be
  removed.
- **No non-root user** anywhere in the image — acceptable given
  `privileged: true` is needed for hardware access, but worth noting
  the whole container (SSH included) runs as root.
- **`docker-compose.yml:1`** — `version: '2.4'` is a deprecated compose
  file format; not breaking, but modern `docker compose` warns on it
  and ignores the field entirely. Could be dropped.

## What's already good

- `start.sh` properly supervises sshd, the Zenoh router, rover
  bringup, and foxglove_bridge as background children, forwards
  TERM/INT to all of them, and exits so `restart: always` (Balena)
  cleanly restarts the whole stack on any child crash.
- `rover_ros` checkout is pinned to a specific commit
  (`ROVER_ROS_REF`) for reproducible builds.
