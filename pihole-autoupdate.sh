#!/bin/bash
# Weekly Pi-hole HA-pair update orchestrator.
# Runs only on the node named as ORCHESTRATOR in the config.
#
# Order of operations:
#   1. refuse to start if the last run failed and nobody acknowledged it
#   2. verify BOTH nodes healthy before touching either one
#   3. update the peer, wait for its reboot, verify it fully recovered
#   4. stop and alert if anything above failed, leaving this node untouched
#   5. only then update this node
#
# Step 5 reboots this machine and kills this script mid-run. The verdict for
# the self-update half is sent by pihole-autoupdate-finish.sh on the way back.
#
# Every address comes from the config as a literal IP on purpose. DNS is the
# service being restarted, so resolving a hostname to decide whether DNS works
# would be circular.

set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# shellcheck source=pihole-common.sh
. /usr/local/sbin/pihole-common.sh

if [ "${IS_ORCHESTRATOR}" != "yes" ]; then
    echo "FAIL ${SELF_NAME} is not the configured orchestrator (${ORCHESTRATOR})" >&2
    exit 3
fi

mkdir -p "${STATE_DIR}"

fail() {
    # The latch blocks the next run until a human looks at this one. Without it,
    # a pair that is already half-broken gets updated again seven days later.
    date -Is >"${FAIL_LATCH}"
    notify FAIL "$*"
}

peer_cmd() {
    # 45 minute ceiling: apt upgrade over a slow mirror is the long pole.
    timeout 2700 ssh -n -i "${SSH_KEY}" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=8 \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${KNOWN_HOSTS}" \
        "${SSH_USER}@${PEER_IP}" "$1" 2>&1
}

ssh_port_open() {
    timeout 3 bash -c "cat < /dev/null > /dev/tcp/${PEER_IP}/22" >/dev/null 2>&1
}

# Wait for the peer to actually stop responding. If it never goes down, the
# reboot did not take and continuing would be unsafe.
wait_peer_down() {
    local i
    for i in $(seq 1 60); do   # 60 x 3s = 3 minutes
        if ! ping -c1 -W2 "${PEER_IP}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

wait_peer_ssh() {
    local i
    for i in $(seq 1 150); do  # 150 x 4s = 10 minutes
        if ssh_port_open; then
            return 0
        fi
        sleep 4
    done
    return 1
}

# Health lags SSH by a minute or two: pihole-FTL has to start before
# keepalived's track script lets the VIP come home. Retry rather than
# snapshot once and call it a failure.
verify_peer_settled() {
    local i out
    out="not-run"
    for i in $(seq 1 30); do   # 30 x 10s = 5 minutes
        out="$(peer_cmd verify)"
        if is_ok "${out}" && dns_answers "${PEER_VIP}"; then
            echo "${out}"
            return 0
        fi
        sleep 10
    done
    if is_ok "${out}"; then
        echo "vip-${PEER_VIP}-not-answering-dns-from-${SELF_NAME}"
    else
        echo "${out}"
    fi
    return 1
}

# Nothing rebooted, so the boot-time finish unit will never run. Send the
# verdict from here instead, or the deadman fires on a run that actually worked.
finish_without_reboot() {
    local self_out peer_out problems="" i

    self_out="not-run"
    for i in $(seq 1 12); do   # 12 x 5s = 1 minute; only a service restart to absorb
        self_out="$(/usr/local/sbin/pihole-node.sh verify 2>&1)"
        if is_ok "${self_out}"; then
            break
        fi
        sleep 5
    done

    peer_out="$(peer_cmd verify)"

    if ! is_ok "${self_out}"; then
        problems="${problems} ${SELF_NAME}:${self_out}"
    fi
    if ! is_ok "${peer_out}"; then
        problems="${problems} ${PEER_NAME}:${peer_out}"
    fi
    if ! dns_answers "${SELF_VIP}"; then
        problems="${problems} vip-${SELF_VIP}-not-answering-dns"
    fi
    if ! dns_answers "${PEER_VIP}"; then
        problems="${problems} vip-${PEER_VIP}-not-answering-dns"
    fi

    if [ -z "${problems}" ]; then
        notify SUCCESS "both nodes updated, no reboot required, VIPs ${SELF_VIP} and ${PEER_VIP} answering DNS"
        return 0
    fi

    fail "verification failed after updating without a reboot:${problems}"
    return 1
}

# A policy of 'required' or 'never' depends on needrestart to see kernel
# upgrades. Without it the decision silently degrades to "never reboot", and a
# kernel security update would sit unapplied for weeks with nothing to say so.
# Catch that at preflight rather than discovering it months later.
check_reboot_tooling() {
    local out
    if [ "${REBOOT_POLICY}" = "always" ]; then
        return 0
    fi
    out="$(/usr/local/sbin/pihole-node.sh reboot-check 2>&1)"
    if printf '%s\n' "${out}" | grep -q 'needrestart is not installed'; then
        echo "${SELF_NAME}"
        return 1
    fi
    out="$(peer_cmd reboot-check)"
    if printf '%s\n' "${out}" | grep -q 'needrestart is not installed'; then
        echo "${PEER_NAME}"
        return 1
    fi
    return 0
}

run() {
    if [ -e "${FAIL_LATCH}" ]; then
        notify ABORT "previous run failed and was never acknowledged, nothing was updated. Clear ${FAIL_LATCH} on ${SELF_NAME} to re-enable"
        return 1
    fi

    notify START "weekly update starting, ${PEER_NAME} first"

    local out

    out="$(/usr/local/sbin/pihole-node.sh verify)"
    if ! is_ok "${out}"; then
        fail "preflight: ${SELF_NAME} is not healthy, nothing was updated: ${out}"
        return 1
    fi

    out="$(peer_cmd verify)"
    if ! is_ok "${out}"; then
        fail "preflight: ${PEER_NAME} is not healthy, nothing was updated: ${out}"
        return 1
    fi

    if ! out="$(check_reboot_tooling)"; then
        fail "preflight: REBOOT_POLICY=${REBOOT_POLICY} but needrestart is missing on ${out}, so kernel updates would never trigger a reboot. Nothing was updated"
        return 1
    fi

    notify PROGRESS "preflight passed, updating ${PEER_NAME}"

    out="$(peer_cmd update)"
    if ! is_ok "${out}"; then
        fail "${PEER_NAME} update failed, ${SELF_NAME} untouched and still serving both VIPs: $(printf '%s\n' "${out}" | tail -3 | tr '\n' ' ')"
        return 1
    fi

    # The node tells us what it decided. Waiting for a reboot that is never
    # coming would time out and be reported as a failure.
    if printf '%s\n' "${out}" | grep -q 'update-complete-no-reboot'; then
        notify PROGRESS "${PEER_NAME} updated with no reboot required"
    else
        if ! wait_peer_down; then
            fail "${PEER_NAME} scheduled a reboot but never went down, ${SELF_NAME} untouched"
            return 1
        fi

        if ! wait_peer_ssh; then
            fail "${PEER_NAME} did not come back within 10 minutes, ${SELF_NAME} untouched and still serving both VIPs"
            return 1
        fi
    fi

    if ! out="$(verify_peer_settled)"; then
        fail "${PEER_NAME} came back unhealthy, stopping before ${SELF_NAME}: ${out}"
        return 1
    fi

    notify PROGRESS "${PEER_NAME} updated and healthy, updating ${SELF_NAME} now"

    # From here the reboot cuts us off. The finish unit sends the verdict.
    date -Is >"${INFLIGHT}"

    out="$(/usr/local/sbin/pihole-node.sh update 2>&1)"
    if ! is_ok "${out}"; then
        rm -f "${INFLIGHT}"
        fail "${SELF_NAME} update failed, ${PEER_NAME} is updated and healthy: $(printf '%s\n' "${out}" | tail -3 | tr '\n' ' ')"
        return 1
    fi

    if printf '%s\n' "${out}" | grep -q 'update-complete-no-reboot'; then
        rm -f "${INFLIGHT}"
        finish_without_reboot
        return $?
    fi

    # Reboot is queued about 5 seconds out. Nothing left to do in this process;
    # pihole-autoupdate-finish.sh sends the verdict after the boot.
    return 0
}

exec 9>"${LOCK}"
if ! flock -n 9; then
    notify ABORT "another update run is already in progress"
    exit 1
fi

run
