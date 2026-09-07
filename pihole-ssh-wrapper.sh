#!/bin/bash
# Forced command for the orchestrator's SSH key on pihole2.
# The key is pinned to this script in authorized_keys, so the orchestrator can
# run exactly two verbs and nothing else. An interactive shell is not reachable
# through this key even if it is stolen.

set -uo pipefail

case "${SSH_ORIGINAL_COMMAND:-}" in
    verify)       exec sudo -n /usr/local/sbin/pihole-node.sh verify ;;
    reboot-check) exec sudo -n /usr/local/sbin/pihole-node.sh reboot-check ;;
    update)       exec sudo -n /usr/local/sbin/pihole-node.sh update ;;
    *)
        echo "DENIED: this key permits only 'verify', 'reboot-check' or 'update'"
        exit 2
        ;;
esac
