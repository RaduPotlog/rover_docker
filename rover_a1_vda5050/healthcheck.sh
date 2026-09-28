#!/bin/bash
# rover-a1-vda5050 health: the local Mosquitto broker accepts connections. Healthy when the
# service idles (ROVER_START_VDA5050 false) or uses a remote broker - there is nothing local to
# check, and an unhealthy container gets restarted by balenaEngine. The connector processes are
# supervised by start.sh, which exits (and so restarts the container) when one of them dies.

norm_bool() {
  case "${1:-$2}" in
    [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Oo][Nn]) echo true ;;
    *) echo false ;;
  esac
}

if [ "$(norm_bool "${ROVER_START_VDA5050:-}" false)" != true ] ||
   [ "$(norm_bool "${ROVER_VDA5050_LOCAL_BROKER:-}" true)" != true ]; then
  exit 0
fi

exec 3<>/dev/tcp/127.0.0.1/1883
