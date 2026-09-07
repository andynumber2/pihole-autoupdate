# Pi-hole HA pair weekly auto-update

Updates and reboots one node of a keepalived Pi-hole pair, verifies it fully
recovered, and only then does the same to the other. Stops and alerts if the
first half fails, so one working DNS server is always left standing.

Written for a two-node pair with two keepalived VIPs, one owned by each node,
with clients pointed at both.

## How it decides it is safe

1. Refuse to start if the last run failed and nobody acknowledged it.
2. Verify **both** nodes before touching either one. Abort if either is unhealthy.
3. `pihole -up`, `apt-get update`, `apt-get upgrade` on the peer, then either a
   detached reboot or a restart of just the stale services, per the reboot
   policy below. The peer reports which it did, so the orchestrator knows
   whether to expect it to disappear.
4. Wait for the peer to come back if it rebooted, then verify it either way:
   `pihole-FTL` running, `keepalived` running, its home VIP bound to its own
   interface, DNS answering on both its real IP and its VIP, and that VIP
   answering when queried from the orchestrator.
5. On any failure above, alert and stop. The orchestrator is untouched and is
   serving both VIPs.
6. Only then update the orchestrator itself.
7. The orchestrator's reboot kills the script mid-run, so a boot-time unit
   re-verifies both nodes and sends the final verdict.

The reboot is scheduled with `systemd-run --on-active=5` rather than
`shutdown -r now`. A bare shutdown tears down the SSH connection mid-command,
and the orchestrator cannot then tell success from a dropped link.

Every address is a literal IP from the config, never a hostname. DNS is the
service being restarted, so resolving a name to decide whether DNS works would
be circular.

Health is judged by real `dig` queries, not by whether a process is running. A
`pihole-FTL` that is running but not answering fails these checks.

## Reboot policy

Reboots are governed by two settings in the config, OR-ed together.

```
REBOOT_POLICY=required     # always | required | never
REBOOT_MAX_AGE_DAYS=30     # 0 disables the floor
```

| POLICY | Kernel pending | Uptime past floor | Action |
|---|---|---|---|
| `always` | any | any | reboot |
| `required` | yes | any | reboot |
| `required` | no | yes | reboot, floor reached |
| `required` | no | no | restart stale services only |
| `never` | any | any | restart stale services only |

`MAX_AGE` is a **floor on boot-testing**, not a rate limit: it can only make
reboots more frequent, never less. A rate limiter would leave a kernel security
update landing early in the window unapplied for the rest of it.
`REBOOT_POLICY=never` with a non-zero floor is contradictory and is rejected at
startup.

`required` and `never` need the `needrestart` package, which `install.sh`
installs along with a drop-in setting `$nrconf{restart} = 'l'`. Without that
drop-in, needrestart prompts during apt runs and would hang an unattended 3am
update until it timed out. If needrestart is missing at run time the
orchestrator aborts at preflight rather than silently never rebooting again.

Services running against upgraded libraries are a restart reason, not a reboot
reason: seconds of disruption rather than a minute. Only units named in
`RESTART_SERVICES` are touched, because needrestart also flags login sessions
and getty units that must not be restarted unattended. `keepalived` is
restarted last, since doing so briefly moves its VIP.

To see what the next run would decide, on either node:

    sudo /usr/local/sbin/pihole-node.sh reboot-check

    policy:          required (floor 30d)
    running kernel:  6.12.34+rpt-rpi-v8
    expected kernel: 6.12.34+rpt-rpi-v8
    uptime:          4 days
    stale services:  none
    would restart:   none
    decision:        no reboot (no kernel change, up 4d of 30d)

## Requirements

- Two nodes running Pi-hole with `keepalived` in the **dual-VIP** arrangement
  described in the next section. A single-VIP active/passive setup will not
  work as shipped.
- Debian 12 or newer, systemd 252 or newer (for the timezone suffix in
  `OnCalendar`). Verify with `systemd-analyze calendar "Mon *-*-* 03:00:00 America/Los_Angeles"`.
- `dig`, `curl`, `flock`, `systemd-run` on both nodes, all present by default on
  Raspberry Pi OS. `install.sh` adds `needrestart` when `REBOOT_POLICY` is not
  `always`.
- Passwordless sudo for the SSH user on both nodes.
- An existing `~/.ssh/authorized_keys` on the peer for that user. Step 3 appends
  to it and backs it up first.
- Home Assistant, for notifications. Optional: leave `HA_WEBHOOK_URL` empty and
  results only go to the log and syslog.

## The keepalived topology this assumes

This software never writes `keepalived.conf`. It reads the state that config
produces, so what follows is a set of requirements on your config, not something
the installer sets up. See keepalived's own documentation for the syntax.

### The arrangement

Two nodes, **two** virtual IPs. Each node is MASTER for one VIP and BACKUP for
the other, so in normal operation both nodes carry one VIP each and both are
actively serving. Clients are configured with both VIPs as their DNS servers.

| | node 1 | node 2 |
|---|---|---|
| own address | 192.0.2.11 | 192.0.2.12 |
| VIP it owns at rest | 192.0.2.21 | 192.0.2.22 |
| MASTER for | 192.0.2.21, priority 255 | 192.0.2.22, priority 255 |
| BACKUP for | 192.0.2.22, priority 254 | 192.0.2.21, priority 254 |

When one node goes down for its update, the other takes over its VIP and holds
both until it returns, so at no point is any VIP unserved. That is the whole
basis of the safety argument.

### Why a single-VIP setup will not work with this software

Whether one floating VIP or two is the better keepalived design is a question
about keepalived, and out of scope here. This is only about what this software
requires.

`pihole-node.sh verify` requires each node to have its own VIP bound to its
interface. In a single-VIP active/passive setup the backup node has no VIP bound
while the master is healthy, so that check can never pass there, preflight fails
every time, and no update ever runs. Supporting active/passive would mean
changing what `verify` considers healthy, which is a code change, not a config
change.

### What your config must provide

1. **Two `vrrp_instance` blocks per node**, with mirrored `state` and
   `priority`, and a **different `virtual_router_id` per VIP**. Reusing one
   router id for both VIPs makes the two instances fight.
2. **No `nopreempt`.** Preemption is what returns each VIP to its home node
   after that node reboots. Without it a VIP stays wherever it landed, the
   post-reboot check fails, and the run stops with a false alarm.
3. **A `track_script` tied to `pihole-FTL`.** Without it the VIP does not move
   when Pi-hole stops, so updating a node produces a real DNS outage on that
   VIP instead of a failover.

The `interface` those instances bind to must match `VRRP_INTERFACE` in
`pihole-autoupdate.conf`.

### Checking what you actually have

On each node, confirm it carries exactly one VIP and that it is the one you
named as that node's VIP:

    ip -4 addr show dev eth0

Each node should show its own address plus one `secondary` VIP. If one node
shows both VIPs and the other shows none, the pair has not settled; check that
preemption is working and that `pihole-FTL` is running on both.

## Fresh install

### 1. Configure

    cp pihole-autoupdate.conf.example pihole-autoupdate.conf
    $EDITOR pihole-autoupdate.conf

Fill in both nodes' names, real IPs and home VIPs, which one is the
orchestrator, the VRRP interface, and the SSH user. The names must match
`hostname -s` exactly. This file is gitignored.

Generate a webhook id for the notification URL. Any long random string:

    echo "pihole-autoupdate-$(openssl rand -hex 8)"

### 2. Install on both nodes

Copy this directory, including your filled-in `pihole-autoupdate.conf`, to each
node. Either order; neither install touches the other machine.

    scp -rp . <user>@<node>:/tmp/pihole-au-src

The `-p` matters. Common transfer paths strip the executable bit (GitHub's
"Download ZIP", `rsync` without `-p`), and the failure then looks like a missing
file rather than a permissions problem. On each node:

    cd /tmp/pihole-au-src
    chmod +x *.sh
    sudo ./install.sh --no-timer

It works out this machine's role from its hostname and installs only what that
role needs, ending with a health check and the current reboot decision.

**Use `--no-timer` here.** Armed now, the schedule could fire before the SSH key
exists (step 3) and before Home Assistant is listening (step 4). That run fails,
writes the failure latch, and alerts nowhere, which then blocks step 5 until you
delete the latch file. Step 6 arms it once everything is proven.

### 3. Create the SSH key to the peer

On the orchestrator:

    sudo /usr/local/sbin/pihole-autoupdate-setup-peer-key.sh

It generates a dedicated key, records the peer's host key, and prints the line
to add to the peer's `authorized_keys` with the commands to add it safely. Run
those on the peer, then confirm:

    sudo /usr/local/sbin/pihole-autoupdate-setup-peer-key.sh --test

The key is pinned to a forced command, so it can only run `verify` or `update`.
It cannot open a shell even if it leaks.

### 4. Set up Home Assistant

**The helper first**, or the SUCCESS branch silently does nothing and the
deadman then fires every week on a healthy pair.

**Settings > Devices & Services > Helpers > Create Helper > Date and/or time**.
Tick both date and time. Name it exactly `Pi-hole autoupdate last success`,
which produces `input_datetime.pi_hole_autoupdate_last_success`. Note the
underscore in `pi_hole`; that is the id the automations reference.

Then create two automations. For each, **Settings > Automations > Create
Automation > Create new automation > three dots > Edit in YAML**, then select
all and paste the file over the default content:

| File | Automation |
|---|---|
| `homeassistant/automation-notifications.yaml` | receives status posts, pushes only on failure |
| `homeassistant/automation-deadman.yaml` | alerts if a run never reports at all |

Both files are bare mappings, so they paste in with nothing to reshape. In each,
change `notify.mobile_app_CHANGE_ME` to your phone's notify service, findable
under **Developer Tools > Actions** by searching `notify`. In the notifications
one, also set `webhook_id` to the id you generated in step 1.

### 5. Verify before arming anything

On each node:

    sudo /usr/local/sbin/pihole-node.sh verify

On the orchestrator only:

    sudo /usr/local/sbin/pihole-autoupdate-testnotify.sh FAIL   # phone should buzz

Then, when you can watch it, run the real thing once:

    sudo systemctl start pihole-autoupdate.service
    journalctl -u pihole-autoupdate.service -f

With the shipped default of `required`, freshly updated nodes have no pending
kernel and little uptime, so usually **neither node reboots** and the run takes
about a minute. With a kernel update pending or the age floor reached, it
reboots each node in turn and takes closer to ten minutes.

A successful run is silent. Confirm it worked by checking that
`input_datetime.pi_hole_autoupdate_last_success` updated, and:

    sudo tail /var/log/pihole-autoupdate.log

If the run failed, clear the latch before retrying:

    sudo rm /var/lib/pihole-autoupdate/last-failure

### 6. Arm the schedule

Only once step 5 passes, on the orchestrator:

    sudo systemctl enable --now pihole-autoupdate.timer
    systemctl list-timers pihole-autoupdate.timer --all

## Changing the schedule

Edit `OnCalendar` in `pihole-autoupdate.timer`, reinstall, and reload:

    sudo install -m 0644 pihole-autoupdate.timer /etc/systemd/system/
    sudo systemctl daemon-reload
    sudo systemctl restart pihole-autoupdate.timer

The hosts can stay on UTC; systemd resolves the timezone suffix and follows DST
itself. Check any change before trusting it:

    systemd-analyze calendar "Mon *-*-* 03:00:00 America/Los_Angeles"

Keep the deadman automation's trigger time and its 5400 second threshold in
step with whatever you choose.

## Files

Repo:

| File | Purpose |
|---|---|
| `install.sh` | installs the right pieces for this node's role |
| `setup-peer-key.sh` | creates the orchestrator's key, prints the peer's line |
| `pihole-common.sh` | config loading, role detection, `notify`, health helpers |
| `pihole-node.sh` | node-local `verify` / `update` |
| `pihole-autoupdate.sh` | orchestrator |
| `pihole-autoupdate-finish.sh` | post-reboot verdict |
| `pihole-autoupdate-testnotify.sh` | fire a test notification |
| `pihole-ssh-wrapper.sh` | forced command pinning the orchestrator's key |
| `pihole-autoupdate.{service,timer}` | the weekly job and its schedule |
| `pihole-autoupdate-finish.service` | boot-time finisher |
| `pihole-autoupdate.logrotate` | log rotation |
| `needrestart-pihole-autoupdate.conf` | stops needrestart prompting during upgrades |
| `pihole-autoupdate.conf.example` | config template |
| `homeassistant/automation-notifications.yaml` | HA automation, paste as-is |
| `homeassistant/automation-deadman.yaml` | HA automation, paste as-is |

Installed, on every node:

| Path | Purpose |
|---|---|
| `/etc/pihole-autoupdate.conf` | all addresses and the webhook, 0600 root |
| `/usr/local/sbin/pihole-common.sh` | sourced by everything else |
| `/usr/local/sbin/pihole-node.sh` | `verify` / `update` |
| `/var/lib/pihole-autoupdate/` | `last-failure`, `self-update-inflight`, `lock` |
| `/var/log/pihole-autoupdate.log` | rotated monthly, 12 kept |

Orchestrator only: `pihole-autoupdate.sh`, `pihole-autoupdate-finish.sh`,
`pihole-autoupdate-testnotify.sh`, `pihole-autoupdate-setup-peer-key.sh`, the
three systemd units, and `/root/.ssh/id_pihole_autoupdate`.

Peer only: `pihole-ssh-wrapper.sh`.

## Notifications

**A run that works produces no notification of any kind.** Only problems are
reported.

- `FAIL` and `ABORT` push to your phone and raise a persistent notification.
- `SUCCESS` is silent. It reaches Home Assistant only to stamp the timestamp
  the deadman reads, and clears any stale failure notice.
- `START` and `PROGRESS` never leave the node. They stay in
  `/var/log/pihole-autoupdate.log`, which is the audit trail.
- **`Pi-hole auto-update deadman`** fires 90 minutes after the job starts. If
  the success timestamp was not stamped, it alerts. This catches the
  orchestrator dying during its own update, which it cannot report itself, and
  is why the silence of a successful run can be trusted.

## The failure latch

Any failure writes `/var/lib/pihole-autoupdate/last-failure`. While that file
exists the next run refuses to start and sends an `ABORT`, so an already
half-broken pair is not updated again a week later.

Clear it once the problem is fixed:

    sudo rm /var/lib/pihole-autoupdate/last-failure

## Operations

    # what is scheduled
    systemctl list-timers pihole-autoupdate.timer --all

    # run now, supervised (may reboot each node in turn, see reboot policy)
    sudo systemctl start pihole-autoupdate.service
    journalctl -u pihole-autoupdate.service -f

    # history
    sudo cat /var/log/pihole-autoupdate.log

    # test notifications without updating anything
    sudo /usr/local/sbin/pihole-autoupdate-testnotify.sh FAIL

    # health of one node, on demand
    sudo /usr/local/sbin/pihole-node.sh verify

    # what the next run would decide about rebooting, changes nothing
    sudo /usr/local/sbin/pihole-node.sh reboot-check

    # turn the whole thing off
    sudo systemctl disable --now pihole-autoupdate.timer

## Scope

This updates and verifies the two nodes. It does not touch `keepalived.conf`,
and it does not synchronise blocklists or local DNS records between the nodes.

The reboot path only runs when a kernel upgrade is pending or the age floor is
reached, so a first install and a test run on current nodes will not exercise
it. The first kernel update after installation is when it first runs for real.
