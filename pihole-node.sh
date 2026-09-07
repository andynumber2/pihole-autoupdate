#!/bin/bash
# Node-local actions for the Pi-hole auto-update workflow.
# Installed identically on both nodes.
#
#   verify         check this node is healthy and owns its home VIP
#   reboot-check   print what the reboot policy would decide, change nothing
#   update         pihole -up, apt update, apt upgrade, then reboot or restart
#                  services according to REBOOT_POLICY
#
# verify and update print one line starting with OK or FAIL, and exit 0 only on
# success. Must be run as root.

set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# shellcheck source=pihole-common.sh
. /usr/local/sbin/pihole-common.sh

# keepalived is configured without nopreempt, so after a reboot this node's
# home VIP returns on its own once pihole-FTL is running again.
verify() {
    if ! systemctl is-active --quiet pihole-FTL; then
        echo "FAIL pihole-FTL-not-active"
        return 1
    fi
    if ! systemctl is-active --quiet keepalived; then
        echo "FAIL keepalived-not-active"
        return 1
    fi
    if ! ip -4 addr show dev "${VRRP_INTERFACE}" | grep -qw "${SELF_VIP}"; then
        echo "FAIL vip-${SELF_VIP}-not-bound-to-${VRRP_INTERFACE}"
        return 1
    fi
    if ! dns_answers "${SELF_IP}"; then
        echo "FAIL no-dns-answer-on-${SELF_IP}"
        return 1
    fi
    if ! dns_answers "${SELF_VIP}"; then
        echo "FAIL no-dns-answer-on-${SELF_VIP}"
        return 1
    fi
    echo "OK ${SELF_NAME} ftl+keepalived+vip-${SELF_VIP}+dns"
    return 0
}

# ---------------------------------------------------------------------------
# Reboot decision
#
# Sets: REBOOT_NEEDED, REBOOT_REASON, STALE_ALL, STALE_ACTIONABLE,
#       UPTIME_DAYS, KERNEL_CUR, KERNEL_EXP
#
# Two independent signals, OR-ed with the age floor:
#   - a kernel upgrade that the running kernel does not reflect
#   - the node simply having been up too long
# Services running against upgraded libraries are NOT a reboot reason. They are
# a restart reason, which is seconds of disruption instead of a minute.
# ---------------------------------------------------------------------------
assess_reboot() {
    REBOOT_NEEDED=no
    REBOOT_REASON=""
    STALE_ALL=""
    STALE_ACTIONABLE=""
    KERNEL_CUR="$(uname -r)"
    KERNEL_EXP="${KERNEL_CUR}"
    UPTIME_DAYS="$(awk '{printf "%d", $1/86400}' /proc/uptime)"

    local kernel_pending=no

    # Some setups create this from an apt hook. Free signal if present.
    if [ -e /var/run/reboot-required ]; then
        kernel_pending=yes
    fi

    if command -v needrestart >/dev/null 2>&1; then
        local nr ksta
        nr="$(needrestart -b 2>&1)"
        ksta="$(printf '%s\n' "${nr}" | awk -F': *' '/^NEEDRESTART-KSTA/ {print $2; exit}')"
        KERNEL_CUR="$(printf '%s\n' "${nr}" | awk -F': *' '/^NEEDRESTART-KCUR/ {print $2; exit}')"
        KERNEL_EXP="$(printf '%s\n' "${nr}" | awk -F': *' '/^NEEDRESTART-KEXP/ {print $2; exit}')"

        # KSTA: 0 unknown, 1 current, 2 ABI-compatible upgrade, 3 version
        # upgrade pending. Only 3 and above genuinely need a boot.
        if printf '%s' "${ksta}" | grep -qE '^[0-9]+$' && [ "${ksta}" -ge 3 ]; then
            kernel_pending=yes
        fi

        STALE_ALL="$(printf '%s\n' "${nr}" |
            awk -F': *' '/^NEEDRESTART-SVC/ {print $2}' | sort -u | tr '\n' ' ')"
    fi

    # Intersect with the allowlist. needrestart also flags login sessions and
    # getty units, which must not be restarted unattended.
    local svc allowed
    for svc in ${STALE_ALL}; do
        for allowed in ${RESTART_SERVICES}; do
            if [ "${svc}" = "${allowed}" ] || [ "${svc}" = "${allowed}.service" ]; then
                STALE_ACTIONABLE="${STALE_ACTIONABLE}${svc} "
            fi
        done
    done

    case "${REBOOT_POLICY}" in
        always)
            REBOOT_NEEDED=yes
            REBOOT_REASON="policy=always"
            ;;
        never)
            REBOOT_NEEDED=no
            REBOOT_REASON="policy=never"
            ;;
        required)
            if [ "${kernel_pending}" = "yes" ]; then
                REBOOT_NEEDED=yes
                REBOOT_REASON="kernel ${KERNEL_CUR} -> ${KERNEL_EXP}"
            elif [ "${REBOOT_MAX_AGE_DAYS}" -gt 0 ] &&
                 [ "${UPTIME_DAYS}" -ge "${REBOOT_MAX_AGE_DAYS}" ]; then
                REBOOT_NEEDED=yes
                REBOOT_REASON="uptime ${UPTIME_DAYS}d reached the ${REBOOT_MAX_AGE_DAYS}d floor"
            else
                REBOOT_NEEDED=no
                REBOOT_REASON="no kernel change, up ${UPTIME_DAYS}d of ${REBOOT_MAX_AGE_DAYS}d"
            fi
            ;;
    esac
}

reboot_check() {
    assess_reboot
    echo "policy:          ${REBOOT_POLICY} (floor ${REBOOT_MAX_AGE_DAYS}d)"
    echo "running kernel:  ${KERNEL_CUR}"
    echo "expected kernel: ${KERNEL_EXP}"
    echo "uptime:          ${UPTIME_DAYS} days"
    echo "stale services:  ${STALE_ALL:-none}"
    echo "would restart:   ${STALE_ACTIONABLE:-none}"
    if [ "${REBOOT_NEEDED}" = "yes" ]; then
        echo "decision:        REBOOT (${REBOOT_REASON})"
    else
        echo "decision:        no reboot (${REBOOT_REASON})"
    fi
    if ! command -v needrestart >/dev/null 2>&1 && [ "${REBOOT_POLICY}" != "always" ]; then
        echo
        echo "WARNING: needrestart is not installed, so kernel and stale-service"
        echo "detection are blind. Only /var/run/reboot-required is consulted."
    fi
}

# Restart the allowlisted services that are running against upgraded libraries.
# keepalived goes last: restarting it briefly hands this node's VIP to the peer.
#
# stdout carries only the comma-separated list of what was restarted, because
# the caller captures it. Progress goes to stderr so it still reaches the log.
restart_stale() {
    local svc done_list=""
    for svc in ${STALE_ACTIONABLE}; do
        case "${svc}" in
            keepalived|keepalived.service) continue ;;
        esac
        echo "restarting ${svc}" >&2
        systemctl restart "${svc}" >&2 || return 1
        done_list="${done_list}${svc},"
    done
    for svc in ${STALE_ACTIONABLE}; do
        case "${svc}" in
            keepalived|keepalived.service) ;;
            *) continue ;;
        esac
        echo "restarting ${svc} (last: this moves the VIP briefly)" >&2
        systemctl restart "${svc}" >&2 || return 1
        done_list="${done_list}${svc},"
    done
    printf '%s' "${done_list%,}"
    return 0
}

update() {
    echo "=== pihole -up ==="
    if ! pihole -up; then
        echo "FAIL pihole-up"
        return 1
    fi

    echo "=== apt-get update ==="
    if ! apt-get update; then
        echo "FAIL apt-update"
        return 1
    fi

    # Non-interactive with conffile defaults, otherwise a package that ships a
    # changed config file blocks the run waiting for input that never comes.
    echo "=== apt-get upgrade ==="
    if ! DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        upgrade; then
        echo "FAIL apt-upgrade"
        return 1
    fi

    echo "=== autoremove ==="
    DEBIAN_FRONTEND=noninteractive apt-get -y autoremove || true

    echo "=== reboot decision ==="
    assess_reboot
    echo "policy=${REBOOT_POLICY} decision=${REBOOT_NEEDED} reason=${REBOOT_REASON}"
    echo "stale=${STALE_ALL:-none} actionable=${STALE_ACTIONABLE:-none}"

    if [ "${REBOOT_NEEDED}" != "yes" ]; then
        local restarted=""
        if [ -n "${STALE_ACTIONABLE}" ]; then
            echo "=== restarting stale services ==="
            if ! restarted="$(restart_stale)"; then
                echo "FAIL restart-stale-services"
                return 1
            fi
        fi
        # The orchestrator reads this line to know not to wait for a reboot
        # that is never coming.
        echo "OK update-complete-no-reboot restarted=${restarted:-none} reason=${REBOOT_REASON}"
        return 0
    fi

    # Detached so the calling SSH session closes cleanly before we go down.
    # A bare "shutdown -r now" tears down the connection mid-command and the
    # orchestrator cannot tell success from a dropped link.
    echo "=== scheduling reboot in 5s ==="
    if ! systemd-run --on-active=5 --unit=pihole-autoupdate-reboot \
        /usr/bin/systemctl reboot; then
        echo "FAIL schedule-reboot"
        return 1
    fi

    echo "OK update-complete-rebooting reason=${REBOOT_REASON}"
    return 0
}

case "${1:-}" in
    verify)       verify ;;
    reboot-check) reboot_check ;;
    update)       update ;;
    *) echo "usage: pihole-node.sh verify|reboot-check|update"; exit 2 ;;
esac
