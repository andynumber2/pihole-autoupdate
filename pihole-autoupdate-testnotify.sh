#!/bin/bash
# Sends one test notification through the real notify path, so the config file,
# the webhook id, and the Home Assistant automation can be checked without
# running an actual update.
#
#   sudo pihole-autoupdate-testnotify.sh            -> PROGRESS (silent, HA only)
#   sudo pihole-autoupdate-testnotify.sh FAIL       -> pushes to the phone

set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# shellcheck source=pihole-common.sh
. /usr/local/sbin/pihole-common.sh

if [ -z "${HA_WEBHOOK_URL:-}" ]; then
    echo "HA_WEBHOOK_URL is empty in ${PIHOLE_AU_CONF}: notifications are disabled"
    exit 1
fi

notify "${1:-PROGRESS}" "test notification from ${SELF_NAME}, no update was performed"
echo "sent ${1:-PROGRESS} as ${SELF_NAME}"
