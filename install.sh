#!/bin/bash
# Installs the Pi-hole auto-update workflow on the node it is run from.
# Run it on BOTH nodes. It reads the config to work out which role this
# machine has and installs only the pieces that role needs.
#
#   sudo ./install.sh              install, and enable the weekly timer
#   sudo ./install.sh --no-timer   install without arming the schedule
#
# Prerequisite: pihole-autoupdate.conf must exist, either already at
# /etc/pihole-autoupdate.conf or beside this script, where it will be
# installed from.

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
CONF=/etc/pihole-autoupdate.conf
SBIN=/usr/local/sbin
UNITS=/etc/systemd/system
ENABLE_TIMER=yes

if [ "${1:-}" = "--no-timer" ]; then
    ENABLE_TIMER=no
elif [ -n "${1:-}" ]; then
    echo "usage: $0 [--no-timer]" >&2
    exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

# --- config -------------------------------------------------------------
if [ ! -f "${CONF}" ]; then
    if [ -f "${SRC}/pihole-autoupdate.conf" ]; then
        install -o root -g root -m 0600 "${SRC}/pihole-autoupdate.conf" "${CONF}"
        echo "installed ${CONF}"
    else
        echo "no ${CONF} and no ${SRC}/pihole-autoupdate.conf to install from." >&2
        echo "Copy pihole-autoupdate.conf.example, fill it in, and try again." >&2
        exit 1
    fi
else
    echo "keeping existing ${CONF}"
fi

# shellcheck source=pihole-autoupdate.conf.example
. "${CONF}"

for required in NODE1_NAME NODE1_IP NODE1_VIP \
                NODE2_NAME NODE2_IP NODE2_VIP \
                ORCHESTRATOR VRRP_INTERFACE SSH_USER PROBE_DOMAIN; do
    if [ -z "${!required:-}" ]; then
        echo "${CONF} is missing ${required}. Compare it against pihole-autoupdate.conf.example." >&2
        exit 1
    fi
done

SELF="$(hostname -s)"
case "${SELF}" in
    "${NODE1_NAME}") PEER="${NODE2_NAME}" ;;
    "${NODE2_NAME}") PEER="${NODE1_NAME}" ;;
    *)
        echo "hostname ${SELF} matches neither NODE1_NAME (${NODE1_NAME}) nor NODE2_NAME (${NODE2_NAME})." >&2
        echo "Fix the names in ${CONF}, or rename this host." >&2
        exit 1
        ;;
esac

# --- every node ---------------------------------------------------------
install -o root -g root -m 0755 "${SRC}/pihole-common.sh" "${SBIN}/pihole-common.sh"
install -o root -g root -m 0755 "${SRC}/pihole-node.sh"   "${SBIN}/pihole-node.sh"
install -d -o root -g root -m 0755 /var/lib/pihole-autoupdate
touch /var/log/pihole-autoupdate.log
chmod 640 /var/log/pihole-autoupdate.log
install -o root -g root -m 0644 "${SRC}/pihole-autoupdate.logrotate" /etc/logrotate.d/pihole-autoupdate

# Superseded by pihole-common.sh in the parameterized layout.
rm -f "${SBIN}/pihole-notify.sh"

# --- reboot policy tooling ----------------------------------------------
# Any policy other than 'always' needs needrestart to see kernel upgrades and
# stale services. Without it the decision degrades silently to "never reboot".
if [ "${REBOOT_POLICY:-always}" != "always" ]; then
    # The drop-in goes down FIRST, so needrestart can never prompt or act on
    # its own, not even during its own installation.
    install -d -o root -g root -m 0755 /etc/needrestart/conf.d
    install -o root -g root -m 0644 \
        "${SRC}/needrestart-pihole-autoupdate.conf" \
        /etc/needrestart/conf.d/pihole-autoupdate.conf

    if ! command -v needrestart >/dev/null 2>&1; then
        echo "installing needrestart (required by REBOOT_POLICY=${REBOOT_POLICY})"
        DEBIAN_FRONTEND=noninteractive apt-get install -y needrestart
    fi
fi

if [ "${SELF}" = "${ORCHESTRATOR}" ]; then
    # --- orchestrator only ----------------------------------------------
    install -o root -g root -m 0755 "${SRC}/pihole-autoupdate.sh"            "${SBIN}/pihole-autoupdate.sh"
    install -o root -g root -m 0755 "${SRC}/pihole-autoupdate-finish.sh"     "${SBIN}/pihole-autoupdate-finish.sh"
    install -o root -g root -m 0755 "${SRC}/pihole-autoupdate-testnotify.sh" "${SBIN}/pihole-autoupdate-testnotify.sh"
    install -o root -g root -m 0755 "${SRC}/setup-peer-key.sh"               "${SBIN}/pihole-autoupdate-setup-peer-key.sh"

    install -o root -g root -m 0644 "${SRC}/pihole-autoupdate.service"        "${UNITS}/pihole-autoupdate.service"
    install -o root -g root -m 0644 "${SRC}/pihole-autoupdate.timer"          "${UNITS}/pihole-autoupdate.timer"
    install -o root -g root -m 0644 "${SRC}/pihole-autoupdate-finish.service" "${UNITS}/pihole-autoupdate-finish.service"

    systemctl daemon-reload
    systemctl enable pihole-autoupdate-finish.service

    if [ "${ENABLE_TIMER}" = "yes" ]; then
        systemctl enable --now pihole-autoupdate.timer
    else
        echo "timer NOT enabled: run 'systemctl enable --now pihole-autoupdate.timer' when ready"
    fi

    echo
    echo "installed as ORCHESTRATOR (${SELF})"
    systemctl list-timers pihole-autoupdate.timer --all --no-pager || true
    echo
    echo "Next: run pihole-autoupdate-setup-peer-key.sh to create the SSH key to ${PEER}."
else
    # --- peer only --------------------------------------------------------
    install -o root -g root -m 0755 "${SRC}/pihole-ssh-wrapper.sh" "${SBIN}/pihole-ssh-wrapper.sh"
    echo
    echo "installed as PEER (${SELF}); the orchestrator is ${ORCHESTRATOR}"
fi

echo
echo "health check:"
"${SBIN}/pihole-node.sh" verify
echo
echo "reboot policy:"
"${SBIN}/pihole-node.sh" reboot-check
