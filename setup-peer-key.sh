#!/bin/bash
# Creates the orchestrator's dedicated SSH key to its peer, and prints the
# exact line to add on the peer.
#
# Run as root on the orchestrator. Safe to re-run: an existing key is kept and
# the same line is printed again.
#
# This deliberately does NOT edit the peer's authorized_keys for you. Appending
# to that file over SSH is the one step where a mistake locks you out of the
# machine, so it stays a copy-paste you can see before you run it.

set -euo pipefail

CONF=/etc/pihole-autoupdate.conf
KEY=/root/.ssh/id_pihole_autoupdate
KNOWN_HOSTS=/root/.ssh/known_hosts

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root" >&2
    exit 1
fi

# shellcheck source=pihole-autoupdate.conf.example
. "${CONF}"

SELF="$(hostname -s)"
case "${SELF}" in
    "${NODE1_NAME}") PEER_NAME="${NODE2_NAME}" ; PEER_IP="${NODE2_IP}" ;;
    "${NODE2_NAME}") PEER_NAME="${NODE1_NAME}" ; PEER_IP="${NODE1_IP}" ;;
    *) echo "hostname ${SELF} is in neither NODE slot in ${CONF}" >&2; exit 1 ;;
esac

mkdir -p /root/.ssh
chmod 700 /root/.ssh

if [ ! -f "${KEY}" ]; then
    ssh-keygen -t ed25519 -N "" -C "pihole-autoupdate ${SELF}->${PEER_NAME}" -f "${KEY}"
    echo "created ${KEY}"
else
    echo "keeping existing ${KEY}"
fi

# StrictHostKeyChecking=yes is used by the orchestrator, so the peer's host key
# has to be known in advance rather than accepted on first contact.
ssh-keyscan -H "${PEER_IP}" >>"${KNOWN_HOSTS}"
sort -u "${KNOWN_HOSTS}" -o "${KNOWN_HOSTS}"
chmod 600 "${KNOWN_HOSTS}"
echo "recorded ${PEER_IP} host key in ${KNOWN_HOSTS}"

PUB="$(cat "${KEY}.pub")"
LINE="command=\"/usr/local/sbin/pihole-ssh-wrapper.sh\",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ${PUB}"

cat <<BANNER

------------------------------------------------------------------------
Add this key on ${PEER_NAME}. Run these three commands THERE, as ${SSH_USER}:

  cp -a ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-preautoupdate
  chmod 600 ~/.ssh/authorized_keys
  cat >> ~/.ssh/authorized_keys <<'EOF'
${LINE}
EOF

The command= prefix pins this key to the update wrapper, so it can only run
'verify' or 'update'. It cannot open a shell even if the key is stolen.

Then come back here and check it:

  sudo /usr/local/sbin/pihole-autoupdate-setup-peer-key.sh --test
------------------------------------------------------------------------

BANNER

if [ "${1:-}" = "--test" ]; then
    echo "testing..."
    if ssh -n -i "${KEY}" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=yes -o UserKnownHostsFile="${KNOWN_HOSTS}" \
        "${SSH_USER}@${PEER_IP}" verify; then
        echo "peer reachable and healthy"
    else
        echo "peer check failed: is the key line installed on ${PEER_NAME}?" >&2
        exit 1
    fi
fi
