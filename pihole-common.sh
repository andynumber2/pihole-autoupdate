#!/bin/bash
# Shared setup for every script in the Pi-hole auto-update workflow.
# Sourced, never executed directly.
#
# Loads /etc/pihole-autoupdate.conf, validates it, and works out which of the
# two configured nodes this machine is. After sourcing, these are set:
#
#   SELF_NAME SELF_IP SELF_VIP     this machine
#   PEER_NAME PEER_IP PEER_VIP     the other node
#   IS_ORCHESTRATOR                yes or no
#
# and these functions are available: notify, is_ok, dns_answers.

PIHOLE_AU_CONF="${PIHOLE_AU_CONF:-/etc/pihole-autoupdate.conf}"
PIHOLE_AU_LOG=/var/log/pihole-autoupdate.log

if [ ! -r "${PIHOLE_AU_CONF}" ]; then
    echo "FAIL cannot read ${PIHOLE_AU_CONF} (run as root?)" >&2
    exit 3
fi

# shellcheck source=pihole-autoupdate.conf.example
. "${PIHOLE_AU_CONF}"

# Fail loudly and early on a half-filled config rather than three steps into an
# update with an empty address in hand.
for _required in NODE1_NAME NODE1_IP NODE1_VIP \
                 NODE2_NAME NODE2_IP NODE2_VIP \
                 ORCHESTRATOR VRRP_INTERFACE SSH_USER PROBE_DOMAIN \
                 REBOOT_POLICY REBOOT_MAX_AGE_DAYS; do
    if [ -z "${!_required:-}" ]; then
        echo "FAIL ${PIHOLE_AU_CONF} is missing ${_required}" >&2
        exit 3
    fi
done
unset _required

case "${REBOOT_POLICY}" in
    always|required|never) ;;
    *)
        echo "FAIL REBOOT_POLICY must be always, required or never, not '${REBOOT_POLICY}'" >&2
        exit 3
        ;;
esac

if ! printf '%s' "${REBOOT_MAX_AGE_DAYS}" | grep -qE '^[0-9]+$'; then
    echo "FAIL REBOOT_MAX_AGE_DAYS must be a whole number of days, not '${REBOOT_MAX_AGE_DAYS}'" >&2
    exit 3
fi

# A floor that can force a reboot contradicts a policy that forbids one. Reject
# it rather than silently picking whichever the code happens to check first.
if [ "${REBOOT_POLICY}" = "never" ] && [ "${REBOOT_MAX_AGE_DAYS}" -ne 0 ]; then
    echo "FAIL REBOOT_POLICY=never requires REBOOT_MAX_AGE_DAYS=0 (got ${REBOOT_MAX_AGE_DAYS})" >&2
    exit 3
fi

RESTART_SERVICES="${RESTART_SERVICES:-}"

SELF_NAME="$(hostname -s)"

case "${SELF_NAME}" in
    "${NODE1_NAME}")
        SELF_IP="${NODE1_IP}" ; SELF_VIP="${NODE1_VIP}"
        PEER_NAME="${NODE2_NAME}" ; PEER_IP="${NODE2_IP}" ; PEER_VIP="${NODE2_VIP}"
        ;;
    "${NODE2_NAME}")
        SELF_IP="${NODE2_IP}" ; SELF_VIP="${NODE2_VIP}"
        PEER_NAME="${NODE1_NAME}" ; PEER_IP="${NODE1_IP}" ; PEER_VIP="${NODE1_VIP}"
        ;;
    *)
        echo "FAIL hostname ${SELF_NAME} matches neither NODE1_NAME (${NODE1_NAME}) nor NODE2_NAME (${NODE2_NAME})" >&2
        exit 3
        ;;
esac

if [ "${SELF_NAME}" = "${ORCHESTRATOR}" ]; then
    IS_ORCHESTRATOR=yes
else
    IS_ORCHESTRATOR=no
fi

SSH_KEY="${SSH_KEY:-/root/.ssh/id_pihole_autoupdate}"
KNOWN_HOSTS="${KNOWN_HOSTS:-/root/.ssh/known_hosts}"

STATE_DIR=/var/lib/pihole-autoupdate
INFLIGHT="${STATE_DIR}/self-update-inflight"
FAIL_LATCH="${STATE_DIR}/last-failure"
LOCK="${STATE_DIR}/lock"

# Output is matched line-wise, not by prefix: ssh can prepend its own warnings
# and the update verb prints a full transcript before its OK line.
is_ok() {
    printf '%s\n' "$1" | grep -qE '^OK '
}

# Resolve PROBE_DOMAIN through a given address. Proves real resolution rather
# than just a listening port.
dns_answers() {
    dig +time=3 +tries=2 +short "@$1" "${PROBE_DOMAIN}" A 2>&1 |
        grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# notify <STATUS> <message words...>
# STATUS is one of START PROGRESS SUCCESS FAIL ABORT.
#
# Everything is logged locally. Only three statuses reach Home Assistant:
# FAIL and ABORT, which you need to see, and SUCCESS, which is silent in the UI
# but is what the deadman automation reads to know the run finished at all.
# START and PROGRESS stay in the log; a clean run should produce no notification
# of any kind, and a running commentary is not information.
#
# A notification failure must never fail the caller, so this always returns 0.
notify() {
    local status="$1"
    shift
    local message="$*"

    # Strip anything that would break the JSON body. Messages are built by this
    # workflow, so plain ASCII with no quotes is the contract.
    message="${message//\\/ }"
    message="${message//\"/ }"
    message="$(printf '%s' "${message}" | tr -d '\r\n\t')"

    logger -t pihole-autoupdate "${status}: ${message}"
    printf '%s %s: %s\n' "$(date -Is)" "${status}" "${message}" >>"${PIHOLE_AU_LOG}" 2>&1

    case "${status}" in
        FAIL|ABORT|SUCCESS) ;;
        *) return 0 ;;
    esac

    if [ -z "${HA_WEBHOOK_URL:-}" ]; then
        return 0
    fi

    curl -sS --max-time 10 --retry 2 --retry-delay 3 \
        -X POST -H 'Content-Type: application/json' \
        -d "{\"status\":\"${status}\",\"host\":\"${SELF_NAME}\",\"message\":\"${message}\"}" \
        "${HA_WEBHOOK_URL}" >/dev/null 2>&1

    return 0
}
