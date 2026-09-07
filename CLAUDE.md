# Working on this repo

The README is for a human deploying this. This file is for whoever is editing it.

## What you are touching

The target nodes serve DNS for everything on their network, including the SSH
path you would use to fix a mistake. There is no test environment. Assume both
nodes are in production unless told otherwise.

## Invariants

Do not break these without the user explicitly asking. Each exists because of a
specific failure it prevents.

1. **The peer is updated first, the orchestrator last.** A peer failure is
   reported by an orchestrator that is still running. The reverse is not true:
   the peer is passive, has no timers, and never initiates anything, so it
   cannot notice the orchestrator failing. An orchestrator that reboots and does
   not return is caught only by the Home Assistant deadman, and only if Home
   Assistant is up when that automation is due to fire.
2. **Both nodes are verified before either is touched.** Updating a peer while
   the orchestrator is already unhealthy is how you end up with zero working DNS
   servers.
3. **Any failure stops the run.** The second node is never touched after the
   first fails. There is no "try anyway" path and there should not be one.
4. **Every address is a literal IP from the config, never a hostname.** DNS is
   the service being restarted. Resolving a name to decide whether DNS works is
   circular and will produce a confidently wrong answer.
5. **Reboots go through `systemd-run --on-active=5`, never `shutdown -r now`
   over SSH.** A bare shutdown tears down the connection mid-command and the
   orchestrator cannot distinguish success from a dropped link.
6. **`verify` must make real DNS queries.** Reducing it to `systemctl is-active`
   would make it blind to a wedged `pihole-FTL`, which is the exact failure the
   checks exist to catch. Query both the node's own IP and its VIP.
7. **A clean run produces no notification.** Only `FAIL` and `ABORT` push.
   `SUCCESS` reaches Home Assistant solely to stamp the deadman's timestamp and
   must stay silent in the UI. `START` and `PROGRESS` never leave the node.

## Configuration

- `/etc/pihole-autoupdate.conf` lives on **both** nodes, mode 0600 root, and
  must be identical on both. Each node reads it to work out which node it is.
- `pihole-autoupdate.conf` in this directory is **gitignored**. Never commit it.
- Nothing tracked in git may contain the real node IPs, the real Home Assistant
  address, the webhook id, or a personal device name. The `.example` file uses
  RFC 5737 documentation addresses (`192.0.2.x`). Check before committing:

      grep -rnE "10\.|192\.168\.|mobile_app_" . --exclude=pihole-autoupdate.conf

## Deploy loop

    scp -rp . <user>@<node>:/tmp/pihole-au-src
    ssh <user>@<node> 'cd /tmp/pihole-au-src && sudo ./install.sh --no-timer'

The `-p` on `scp` matters. Without it the executable bit is lost and
`install.sh` fails with `command not found`, which reads like a missing file.

Either node can be installed first; `install.sh` never contacts the other one.
The peer's install must precede the orchestrator's `setup-peer-key.sh --test`,
which calls the wrapper on the peer.

Use `--no-timer` on a first install. Arming the schedule before the SSH key and
the Home Assistant automations exist risks a run that fails, writes the latch,
and alerts nowhere.

## Testing without breaking DNS

Safe, in increasing order of consequence:

    sudo /usr/local/sbin/pihole-node.sh reboot-check      # decision only, no changes
    sudo /usr/local/sbin/pihole-node.sh verify            # health only, no changes
    sudo /usr/local/sbin/pihole-autoupdate-testnotify.sh FAIL   # real notify path, pushes to phone
    sudo systemctl start pihole-autoupdate.service        # a REAL run, may reboot both nodes

Only run the last one when the user is present and expecting it.

After any failed run, the latch blocks the next one until cleared:

    sudo rm /var/lib/pihole-autoupdate/last-failure

## Design choices, not accidents

These are not oversights to tidy up; changing them changes behaviour people are
relying on.

- **The shipped default is `REBOOT_POLICY=required` with a 30 day floor.** The
  floor exists so nodes are proven bootable on a schedule rather than during an
  outage.
- **The floor is OR-ed with the kernel check, deliberately not a rate limiter.**
  A rate limiter would leave a kernel security update unapplied for weeks.
- **Stale libraries restart services, they do not trigger a reboot.** Seconds of
  disruption instead of a minute, and the VIP absorbs it.
- **Notifications are problems-only.** Adding progress notifications defeats the
  design; the deadman is what makes a silent success trustworthy.

## Home Assistant side

The two files in `homeassistant/` are **copies** of what is deployed, not the
source of truth. The live automations are in Home Assistant. If you change one,
change both, and keep the tracked copies' placeholders (`CHANGE-ME`,
`notify.mobile_app_CHANGE_ME`) rather than pasting the real values back in.

Each file is a bare mapping so it pastes directly into HA's per-automation
"Edit in YAML" editor. Do not merge them back into a single list; that form
belongs in `/config/automations.yaml` and will not load in the editor.

`note:` keys on individual triggers, conditions and actions are valid (HA
2026.6+) and survive a round-trip through the config API. They are not stray
keys to be cleaned up.

The deadman automation's trigger time and its 5400 second threshold must stay in
step with the `OnCalendar` line in `pihole-autoupdate.timer`. Changing one and
not the other produces a deadman that fires every week on a healthy pair, or one
that never fires at all.

## Out of scope

`keepalived.conf`, and blocklist or local-DNS synchronisation between the nodes.
This software reads the keepalived state it needs and never writes that config.
