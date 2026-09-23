#!/bin/bash -e
# Entrypoint of rover-a1-drive-interface: start sshd, render the runtime config (config.json for
# the page) and the login, then run nginx - supervising both, like the other rover containers.

# All long-running processes we supervise. Populated as each is started.
CHILD_PIDS=()

terminate_children() {
  if [ "${#CHILD_PIDS[@]}" -gt 0 ]; then
    kill -TERM "${CHILD_PIDS[@]}" 2>/dev/null || true
    wait "${CHILD_PIDS[@]}" 2>/dev/null || true
  fi
}

# Forward container stop/kill signals to every supervised process instead
# of only whichever one happens to be PID 1.
trap 'terminate_children; exit 0' TERM INT

rm -f /tmp/drive-interface-idle

# **SSHD background (keep alive)** - started before the gates below, so the container is
# reachable even while the drive interface idles. Port 25 (set in the image's sshd_config
# drop-in): platform 22, sensors 23, orchestrator 24, drive-interface 25, cockpit 26.
/usr/sbin/sshd -D &
SSHD_PID=$!
CHILD_PIDS+=("$SSHD_PID")
echo "sshd started on port 25 (PID: $SSHD_PID)"

norm_bool() {
  case "${1:-$2}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) echo true ;;
    *) echo false ;;
  esac
}

# Idle (sshd only) rather than exit: `restart: always` would otherwise crash-loop the service
# and take the SSH session with it. Changing a balenaCloud variable restarts the container,
# which re-reads them here.
idle() {
  echo "$1; idling (sshd on 25 stays up)"
  touch /tmp/drive-interface-idle  # see healthcheck.sh
  # Not `exec sleep infinity`: waiting on sshd idles just as well and keeps signals forwarded.
  wait "$SSHD_PID" || true
  terminate_children
  exit 0
}

if [ "$(norm_bool "${ROVER_DRIVE_ENABLE:-}" true)" != true ]; then
  idle "Drive interface disabled (ROVER_DRIVE_ENABLE=false)"
fi

export ROVER_DRIVE_PORT="${ROVER_DRIVE_PORT:-5000}"
export ROVER_DRIVE_BRIDGE="${ROVER_DRIVE_BRIDGE:-127.0.0.1:8765}"
ROVER_DRIVE_USER="${ROVER_DRIVE_USER:-rover}"

# foxglove_bridge can drive the rover and trip the e-stop; never serve it without a login.
if [ -z "${ROVER_DRIVE_PASSWORD:-}" ]; then
  echo "ERROR: ROVER_DRIVE_PASSWORD is not set - refusing to expose the drive interface without a login" >&2
  idle "Drive interface not served"
fi
htpasswd -bcB /etc/nginx/drive.htpasswd "$ROVER_DRIVE_USER" "$ROVER_DRIVE_PASSWORD" >/dev/null

# JSON-escape the few strings that go into config.json.
json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }
num_or() { [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && echo "$1" || echo "$2"; }

cat > /tmp/drive-config.json <<JSON
{
  "namespace": "$(json_str "${ROVER_NAMESPACE:-}")",
  "robotName": "$(json_str "${ROVER_DRIVE_ROBOT_NAME:-${ROVER_NAMESPACE:-rover}}")",
  "maxLinear": $(num_or "${ROVER_DRIVE_MAX_LINEAR:-}" 1.0),
  "maxAngular": $(num_or "${ROVER_DRIVE_MAX_ANGULAR:-}" 1.0),
  "maxRimSpeed": $(num_or "${ROVER_DRIVE_MAX_RIM_SPEED:-}" 1.7),
  "trackWidth": $(num_or "${ROVER_DRIVE_TRACK_WIDTH:-}" 1.0204),
  "expoLinear": $(num_or "${ROVER_DRIVE_EXPO_LINEAR:-}" 0.3),
  "expoAngular": $(num_or "${ROVER_DRIVE_EXPO_ANGULAR:-}" 0.5),
  "auxOutputNames": "$(json_str "${ROVER_DRIVE_AUX_OUTPUT_NAMES:-}")",
  "auxInputNames": "$(json_str "${ROVER_DRIVE_AUX_INPUT_NAMES:-}")"
}
JSON

envsubst '${ROVER_DRIVE_PORT} ${ROVER_DRIVE_BRIDGE}' \
  < /etc/nginx/drive.conf.template > /tmp/nginx.conf
nginx -t -c /tmp/nginx.conf

nginx -c /tmp/nginx.conf -g 'daemon off;' &
NGINX_PID=$!
CHILD_PIDS+=("$NGINX_PID")
echo "Drive interface on :${ROVER_DRIVE_PORT} (user ${ROVER_DRIVE_USER}), bridge ${ROVER_DRIVE_BRIDGE} (PID: $NGINX_PID)"

# **Supervise** - block until the first supervised process exits, then tear down the other and
# exit so `restart: always` brings the whole container back. `|| EXIT_CODE=$?` because this
# script runs under `bash -e`, which would otherwise skip the teardown on a non-zero exit.
EXIT_CODE=0
wait -n "${CHILD_PIDS[@]}" || EXIT_CODE=$?

for entry in "sshd:$SSHD_PID" "nginx:$NGINX_PID"; do
  name=${entry%%:*}
  pid=${entry##*:}
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Supervised process '$name' (PID $pid) exited (code $EXIT_CODE)"
  fi
done

terminate_children
exit "$EXIT_CODE"
