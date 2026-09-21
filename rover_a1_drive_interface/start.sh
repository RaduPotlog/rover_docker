#!/bin/bash -e
# Entrypoint of rover-a1-drive-interface: render the runtime config (config.json for the
# page) and the login, then run nginx in the foreground.

norm_bool() {
  case "${1:-$2}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) echo true ;;
    *) echo false ;;
  esac
}

# Idle rather than exit when disabled: `restart: always` would otherwise crash-loop.
if [ "$(norm_bool "${ROVER_DRIVE_ENABLE:-}" true)" != true ]; then
  echo "Drive interface disabled (ROVER_DRIVE_ENABLE=false); idling"
  trap 'exit 0' TERM INT
  sleep infinity &
  wait $!
fi

export ROVER_DRIVE_PORT="${ROVER_DRIVE_PORT:-5000}"
export ROVER_DRIVE_BRIDGE="${ROVER_DRIVE_BRIDGE:-127.0.0.1:8765}"
ROVER_DRIVE_USER="${ROVER_DRIVE_USER:-rover}"

# foxglove_bridge can drive the rover and trip the e-stop; never serve it without a login.
if [ -z "${ROVER_DRIVE_PASSWORD:-}" ]; then
  echo "ERROR: ROVER_DRIVE_PASSWORD is not set - refusing to expose the drive interface without a login" >&2
  sleep 30  # slow the restart loop down
  exit 1
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
  "maxAngular": $(num_or "${ROVER_DRIVE_MAX_ANGULAR:-}" 1.0)
}
JSON

envsubst '${ROVER_DRIVE_PORT} ${ROVER_DRIVE_BRIDGE}' \
  < /etc/nginx/drive.conf.template > /tmp/nginx.conf
nginx -t -c /tmp/nginx.conf

echo "Drive interface on :${ROVER_DRIVE_PORT} (user ${ROVER_DRIVE_USER}), bridge ${ROVER_DRIVE_BRIDGE}"
exec nginx -c /tmp/nginx.conf -g 'daemon off;'
