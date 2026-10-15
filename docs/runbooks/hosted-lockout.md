# Lockout on hosted production

Getting back in when a login, a second factor, SSH or the firewall stands in the way. Each way in has a fallback that does not depend on it:
the two public consoles have the tunnel, the tunnel has SSH, and SSH has Contabo's console.

**Status, 2026-11-07.** None of these recoveries has run on hosted production: NOT RUN. Grafana's and Infisical's were run against the same
images in Docker, as [`scripts/hosted/README.md`](../../scripts/hosted/README.md) says beside each. The SSH and firewall timers are read from
[`provision-node.sh`](../../scripts/hosted/provision-node.sh) and [`edge.sh`](../../scripts/hosted/edge.sh). The node's SSH settings and its
first firewall stage, read after provisioning, are in [hosted-node-20261106T225936Z.txt](../evidence/runs/hosted-node-20261106T225936Z.txt).

Preamble for raw commands, from the checkout that holds `.local/hosted/plane-prod/`:

```bash
kc() { .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod "$@"; }
```

## Which way in

| What refuses you | Way in | Section |
|---|---|---|
| https://grafana.bereket.dev, with the right password | Wait five minutes, use the tunnel, or replace Grafana's pod | [Grafana](#grafana) |
| Infisical asks for a code you cannot give, or says Account is locked | A recovery code, or the database through the tunnel | [Infisical](#infisical) |
| A console whose route is down | `make remote-ui TARGET=plane-prod UI=<name>` | [The tunnel](#the-tunnel) |
| The tunnel, or every `make remote-*` | SSH | [SSH](#ssh) |
| The site, because 443 is closed | `edge.sh owner <your ipv4>` | [The firewall](#the-firewall) |
| SSH itself | Contabo's console | [SSH](#ssh) |

## Grafana

Grafana has one admin login and a password alone, with no second factor. Its username is `grafana-admin` unless someone changed it, and
the password is in `.local/hosted/plane-prod/grafana-admin-password` and in Secret `monitoring/grafana-admin`.

```bash
make remote-grafana-admin TARGET=plane-prod VERB=login     # prints the URL and username, and copies the password to the clipboard
```

Five failed logins from one address in five minutes make Grafana refuse that address, even with the right password, until five minutes
after the last of them. It counts per address, not per username, so a stranger's guesses lock out only the stranger. A session you already
have keeps working. To get in sooner:

```bash
make remote-ui TARGET=plane-prod UI=grafana                # through the tunnel, so it arrives from inside the cluster, not from your address
kc -n monitoring delete pod -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack
```

Grafana's database is an emptyDir, so a new pod starts with no count and takes its login from the Secret again. It also signs everyone out
and loses whatever was made in the UI since the pod started. A container restart keeps that database, and the count with it.

If the password file is gone from this Mac, `make remote-grafana-admin TARGET=plane-prod CONFIRM=plane-prod VERB=apply` writes it back from
the Secret. If both are gone, the recovery bundle holds a copy. To change the password: `VERB=rotate`, with `CONFIRM=plane-prod`, then
`make remote-bundle TARGET=plane-prod`. Rotate replaces the pod, and it has not run against production.

The count per address rests on Traefik seeing each client's own address. The row `Traefik sees a client's own address` in
`make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=outside` reads that on this cluster: PENDING, from tonight's outside run.

## Infisical

Infisical's one admin signs in at https://infisical.bereket.dev with a password and an authenticator app (TOTP). Email codes cannot be
used, because there is no SMTP. Its route and why it exists are in [ADR 0017](../adr/0017-infisical-public-route.md), and Infisical on this
platform in [Infisical](../infisical.md).

```bash
make remote-infisical-admin TARGET=plane-prod VERB=login   # prints the URL and email, and copies the password to the clipboard
make remote-ui TARGET=plane-prod UI=infisical              # the same sign-in through the tunnel, in Chrome or Firefox
```

Safari drops Infisical's Secure cookies on `http://localhost`, so a sign-in through the tunnel there lasts until the page reloads.

| Situation | Way back |
|---|---|
| Account is locked, after wrong codes: 5 lock it for 5 minutes, 10 for 30, 15 for an hour, 20 until someone unlocks it | Wait, or clear the lock in the database through the tunnel. After 20, Infisical writes an unlock link to its log, and the same path works through the tunnel |
| 429 at sign-in | The route allows an address a burst of 10 tries, then one every 6 seconds, and a full 10 again once it has sent nothing for about 7 seconds. Wait, or use the tunnel |
| Phone lost, recovery codes kept | Sign in, choose **Use a recovery code**, then in Personal Settings, Authentication, **Disable 2FA**, then **Remove** the authenticator app, and set up the new phone |
| Phone and recovery codes both gone | Turn two-factor off in the database through the tunnel, sign in with the password alone, and set it up again at once |
| Password lost | A new hash in the same database: [`infisical/README.md`](../../infisical/README.md), section Admin token and password both gone |
| The admin token ends soon, and two-factor is on | `make remote-status TARGET=plane-prod` says when. Make the next one in the UI, into `.local/hosted/plane-prod/secret-zero/infisical-admin-token.new`, because no script can sign in past the code |

[`scripts/hosted/README.md`](../../scripts/hosted/README.md) has the statements for the database, the labels for each step and the token's
path in the UI, in sections Two-factor for Infisical's admin and Locked out of Infisical. Wrong passwords lock nothing in this version: their
count only asks for a captcha, which needs a key this platform does not set. The last step of setting up two-factor puts its ten recovery
codes, each good once, in the password manager, apart from the phone.

`InfisicalOpenToClaim` is the other way Infisical can go wrong: it no longer reads claimed and closed to sign-up. That is not a lockout, and it
comes first. Close 443, then follow section Infisical reads open in the same README.

## The tunnel

Every `make remote-*` reaches the cluster's API through one SSH tunnel, from 127.0.0.1:16443 here to the node's 6443, and nothing else reaches
that API.

```bash
make remote-tunnel TARGET=plane-prod VERB=status
make remote-tunnel TARGET=plane-prod VERB=start
make remote-kubeconfig TARGET=plane-prod          # if .local/hosted/plane-prod/kubeconfig is gone
```

`start` refuses while something else listens on 16443: free that port, because a stranger answering there must not be taken for the API.
With the tunnel up, `make remote-ui TARGET=plane-prod UI=argocd|grafana|prometheus|alertmanager|infisical` reaches each console on
127.0.0.1, whatever its route does. Argo CD's login is user `admin`, with the password in Secret `argocd/argocd-initial-admin-secret`.

## SSH

| | |
|---|---|
| User | `wayline-admin`, with sudo. Root login is refused |
| Key | `~/.ssh/wayline_contabo_ed25519`. Keys only, no passwords |
| Host key | `.local/hosted/known_hosts`, checked strictly |
| Port | 22, open in every firewall stage |
| Other user | `wayline-pull`: read-only SFTP for the backup pull, with no shell |

```bash
ssh -i ~/.ssh/wayline_contabo_ed25519 -o IdentitiesOnly=yes -o UserKnownHostsFile=.local/hosted/known_hosts wayline-admin@5.253.234.127
```

A change to SSH or to the firewall cannot keep you out for long. `provision-node.sh access` and `edge.sh` each start a timer on the server
before they change anything, 10 minutes for SSH's settings and 2 minutes for the firewall, and stop it only once a new login has worked. A
timer that runs out puts the old SSH settings back, or the firewall's previous stage. So after a failed proof, change nothing until the
timer has run.

If SSH refuses for good, because the key is lost, or because the host key no longer matches `.local/hosted/known_hosts` and you need to
read the new one on the server itself: Contabo's VNC console, from its Control Panel. `provision-node.sh access` leaves the VPS's root
password working there for a lockout. That is the only way in that does not depend on this Mac: NOT RUN.
The recovery bundle holds the pull user's key and the known hosts, and not `~/.ssh/wayline_contabo_ed25519`, so that key needs a copy of
its own away from this Mac.

## The firewall

The node's own nftables table, `inet wayline_edge`, decides what reaches the node from the internet, ahead of K3s's rules, so a hostPort or
NodePort cannot get past it. [`edge.sh`](../../scripts/hosted/edge.sh) moves it between stages:

| Stage | Open | For |
|---|---|---|
| `closed` | 22 | A new node, before anything listens |
| `http` | 22 and 80 | Let's Encrypt's challenge, with the site closed |
| `owner <ipv4>` | 22, 80, and 443 from that one address | The site for one person |
| `open` | 22, 80 and 443 | The public site |

```bash
scripts/hosted/edge.sh status                                                    # the stage in force, and whether the table is loaded
scripts/hosted/edge.sh scan                                                      # what answers from this machine, the check that counts
TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/edge.sh owner <your public ipv4>
TARGET=plane-prod CONFIRM=plane-prod TWO_FACTOR=on scripts/hosted/edge.sh open   # once Infisical's admin has two-factor on
```

`owner` is the way back to the site while 443 is closed to everyone else: after `edge.sh http`, which [`scripts/hosted/README.md`](../../scripts/hosted/README.md)
tells you to run for an Infisical that reads open, or while `open` refuses. Without `TWO_FACTOR=on`, `open` stops at its note on two-factor
before it reads or changes anything, because nothing here can read whether two-factor is on. With it, `open` refuses unless Plane's instance
reads claimed and Infisical reads claimed and closed to sign-up, and it refuses too while Infisical's config does not answer at all, so then
Plane stays off the internet with it. A VPN or another network gives you another address, so run `owner` again then.

`PublicFirewallNotLoaded` means the table is not loaded, so the API's 6443, the kubelet's 10250 and node-exporter's 9100 answer on the public
address. `edge.sh status` says whether it is loaded, and running `edge.sh` again with the stage you want loads it, with its timer. The unit
`wayline-edge.service` loads the stage at every boot.

## What not to do

| Do not | Why |
|---|---|
| Type a production password on a command line | Scripts read secrets from files or hidden prompts, so nothing reaches a process list or the shell's history |
| Stop `wayline-edge.service`, or load this table with Debian's `nftables.service` | Stopping the unit deletes the table, which leaves 6443, 10250 and 9100 open, and stopping Debian's unit flushes every rule, K3s's included |
| Edit `/etc/wayline/edge.nft` on the server | `edge.sh` writes it, with the timer that undoes a stage that locks you out. An edit there has neither |
| Turn on email two-factor, or add a passkey, for Infisical | There is no SMTP to send a code, and a passkey made on the public host does not work through the tunnel |
| Merge `.local/hosted/plane-prod/kubeconfig` into `~/.kube/config` | A plain `kubectl` could then reach production by switching context, which the separate file and the checks in `scripts/hosted/lib.sh` exist to prevent |
| Make the VPS a Terraform resource, to manage it from `prod-host` | As a resource, the Contabo provider can reinstall the disk or cancel the contract, and `prevent_destroy` stops neither. So `prod-host` reads it as a data source only |
