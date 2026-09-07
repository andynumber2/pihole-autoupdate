#!/bin/bash
# Runs at every boot on the orchestrator, and does nothing unless a self-update
# was in flight when the machine went down.
#
# This is the second half of pihole-autoupdate.sh. That script cannot report on
# its own reboot, so the verdict for the whole weekly run is sent from here.

set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# shellcheck source=pihole-common.sh
. /usr/local/sbin/pihole-common.sh

if [ ! -e "${INFLIGHT}" ]; then
    exit 0
fi

peer_verify() {
    timeout 60 ssh -n -i "${SSH_KEY}" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="${KNOWN_HOSTS}" \
        "${SSH_USER}@${PEER_IP}" verify 2>&1
}

# keepalived needs pihole-FTL up before its track script will let this node's
# VIP come back from the peer, so poll rather than judge on the first sample.
self_out="not-run"
for i in $(seq 1 30); do   # 30 x 10s = 5 minutes
    self_out="$(/usr/local/sbin/pihole-node.sh verify 2>&1)"
    if is_ok "${self_out}"; then
        break
    fi
    sleep 10
done

peer_out="not-run"
for i in $(seq 1 12); do   # 12 x 10s = 2 minutes
    peer_out="$(peer_verify)"
    if is_ok "${peer_out}"; then
        break
    fi
    sleep 10
done

rm -f "${INFLIGHT}"

problems=""
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
    notify SUCCESS "both nodes updated and rebooted, FTL and keepalived running, VIPs ${SELF_VIP} and ${PEER_VIP} back home and answering DNS"
else
    date -Is >"${FAIL_LATCH}"
    notify FAIL "post-reboot verification failed:${problems}"
fi
