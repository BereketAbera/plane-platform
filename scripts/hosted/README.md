# scripts/hosted: everything that touches the VPS

`lib.sh` is the only way to reach the cluster from a script that needs it. It sources `scripts/lib/common.sh`, which stays hard-wired to
kind, overrides `KUBECONFIG`, `KUBE_CONTEXT`, `LOCAL_DIR` and `kc`, needs `TARGET=plane-prod`, and refuses to go on unless the live
`kube-system` UID and node name match [`infrastructure/hosted/plane-prod/target.yaml`](../../infrastructure/hosted/plane-prod/target.yaml).
What changes something also needs `CONFIRM=plane-prod`, and `CONFIRM=yes` does not count. `provision-node.sh` and `edge.sh` stand apart from
it, because they run before there is a cluster to compare with.

Through make: `make remote-<verb> TARGET=plane-prod`. No local target can reach this cluster.

| Script | Does | Target |
|---|---|---|
| `tunnel.sh` | SSH tunnel, 127.0.0.1:16443 to the node's 6443. Started by `lib.sh` when needed | `remote-tunnel` |
| `kubeconfig.sh` | Fetch K3s's kubeconfig, rewrite it for the tunnel, and print the UID for `target.yaml` | `remote-kubeconfig` |
| `status.sh` | Read-only summary | `remote-status` |
| `bootstrap.sh` | Deploy key, Grafana's login, port 80, Terraform, backup folders, restic password, secret zero, Infisical, alerts, bundle | `remote-bootstrap` |
| `ui.sh` | Port-forward an admin UI. None has a public route but Grafana and Infisical, which this also reaches when a route is down | `remote-ui` |
| `grafana-admin.sh` | Make Grafana's admin login once and write its Secret (`apply`), replace its password (`rotate`), or print the URL and username and copy the password (`login`) | `remote-grafana-admin` |
| `infisical-admin.sh` | Print Infisical's URL and admin email, and copy its password to the clipboard (`login`). Bootstrap makes that login, and this only reads it | `remote-infisical-admin` |
| `alerts.sh` | Render `alertmanager.yaml` from the owner's files into a Secret, and say COMPLETE or INCOMPLETE | `remote-alerts` |
| `bundle.sh` | The age-encrypted recovery bundle, proved by decrypting it again | `remote-bundle` |
| `backup.sh` | Run tonight's backups now, from the CronJobs | `remote-backup` |
| `pull-backups.sh` | Copy the encrypted repositories here, over a read-only SFTP user | `remote-pull-setup`, `remote-pull-backups` |
| `backup-dest.sh` | `verify`, `push` and `status` of the copies off the VPS | `remote-backup-dest` |
| `restore-test.sh` | Restore into an isolated namespace, prove it, and remove it, on the VPS or in kind | `remote-restore-test` |
| `restart-check.sh` | Restart Plane's pods one at a time, compare what Postgres holds before and after, and say how long the site was down | `remote-restart-check` |
| `smoke.sh` | `tests/e2e/smoke.py --env hosted --mode verify` on an existing account, asked at a hidden prompt | `remote-smoke` |
| `test-hosted.sh` | The hosted test suite. Exits 0, 1 or 2, and says BLOCKED or INCOMPLETE plainly | `remote-test` |
| `scrub-values.sh` | Keep the values of its Secrets, and Grafana's admin password from its file, in a file for `scripts/publish-evidence.sh` to scrub, which reaches no cluster here | `remote-publish-evidence` |
| `target.sh` | The opt-in shared scripts source when `WAYLINE_TARGET` is set: `scripts/secret-zero.sh`, `infisical-bootstrap.sh`, `infisical-seed.sh`, `test-netpol.sh`, `infisical/tests/rendered-secrets.sh`. It needs `CONFIRM=plane-prod` too, so a leaked variable aims nothing | `remote-netpol`, and through `remote-bootstrap` and `remote-test` |

Local state lives in `.local/hosted/plane-prod/`, mode 0700, and never in Git. Bash 3.2, because macOS ships it.

## The first certificate

cert-manager's self-check goes through the CoreDNS rewrite and never leaves the node, so it passes behind a closed firewall. cert-manager
then asks Let's Encrypt, whose connection to port 80 is dropped, and the order fails. The next try is an hour away, doubling up to 32, and
opening the firewall retriggers nothing. So `bootstrap.sh` opens port 80 before Argo CD starts. If an order failed anyway, then with port
80 open, this removes the backoff, and cert-manager tries again at once. For Grafana's the namespace is `monitoring` and the name `grafana-tls`:

```
.tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod -n plane-prod patch certificate wayline-tls \
  --subresource=status --type=json -p '[{"op":"remove","path":"/status/lastFailureTime"}]'
```

That is read from cert-manager v1.21.3's `shouldBackoffReissuingOnFailure` and has not run on this cluster. Moving `issuerRef` from
staging to production also tries at once, because the next request no longer matches the Certificate.

`grafana-tls` and `infisical-tls` can fail one way more: DNS. The zone's wildcard answers for any name with no record of its own, and that
points at Vercel, so each A record has to be live before Argo CD first sees that Certificate. For Infisical's the namespace is `infisical`.

`infisical-tls` has one more condition, at its first order and at every renewal, about every 60 days. Its solver pod takes 64Mi of the
namespace's `limits.memory` quota, 1376Mi of 2400Mi is used steady, and the server's rollout and the nightly backup each take 1024Mi more, so
the quota fits one of the three at a time, and the node has no memory to raise it. A pod the quota refuses is never created, so it never fails
either. A solver that meets a rollout or a backup waits for it to finish. A solver whose self-check keeps failing holds its 64Mi until its
challenge passes or is deleted, and meanwhile the next rollout's new pod and the backup's pod are refused. The backup Job then ends at its
2-hour deadline with no pod failed, and `PlaneBackupFailed`, which counts failed pods, stays quiet. kube-prometheus-stack's `KubeJobFailed`
warns 15 minutes later, and `BackupTooOld` pages 26 hours after the last good backup. Argo CD reads the server's Deployment as Degraded once a
rollout passes its 10-minute progress deadline, and `ArgoAppDegraded` fires for infisical 5 minutes after. A solver that waits shows as
`CertificateNotReady` once the Certificate has not been Ready for 30 minutes, which is only at the first order: at a renewal the old
certificate is still Ready, and nothing fires for it until `CertificateExpiringSoon` at 21 days. `kc -n infisical get challenges,pods` shows
the solver, and `kc -n infisical describe challenge` why it waits, in the Challenge's reason and events: the quota's refusal of its pod, with
the quota's numbers, or the self-check that fails. The values that come with the route roll the server, so they go out in a push of their own,
and the Certificate in a later one, once that rollout has finished. On a new VPS there is nothing to roll, and both fit.

Port 80 alone is enough for a retry. If 443 was closed as well, `edge.sh open` refuses while Infisical's config does not answer, so with
Infisical down Plane stays off the internet too: `TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/edge.sh owner <your ipv4>` reaches the
site from one address meanwhile.

## Infisical's public route

`https://infisical.bereket.dev` is for one person's browser: Infisical's admin, with an authenticator app. Its route,
[`route.yaml`](../../gitops/clusters/plane-prod/platform/infisical/route.yaml), passes the sign-in, two-factor and session endpoints under a limit
per address, the API families its web client calls, and its pages. Traefik answers 404 to the rest: every machine login, the OpenAPI document,
SCIM, sign-up, invitations, account recovery, shared secrets, the SSO logins, and any call carrying a machine's credential. The operator does not
use it, and reads Infisical through its Service. [`docs/infisical.md`](../../docs/infisical.md#the-public-route) says what stays reachable, and
[ADR 0017](../../docs/adr/0017-infisical-public-route.md) why it exists at all.

`make remote-infisical-admin TARGET=plane-prod VERB=login` prints the URL and email, and puts the password on the clipboard. The tunnel still
works when the route does not: `make remote-ui TARGET=plane-prod UI=infisical`, in Chrome or Firefox. Safari drops Infisical's cookies on
`http://localhost`, because they are Secure, so a sign-in there lasts until the page reloads.

The Secret Sharing pages, member invitations and the SSO logins do not work through the route, on purpose. A token made on a machine identity's
Token Auth tab works only inside the cluster, because the route refuses a machine's credential.

## Two-factor for Infisical's admin

Email codes are not an option: with no SMTP this version shows them as Unavailable, and its API refuses them. Use an authenticator app. Set it
up through the tunnel before 443 is open to everyone, which on a new VPS means after `bootstrap.sh` and before `edge.sh open`, so the account
is never on the internet with a password alone. Nothing here can read whether it is on, so `edge.sh open` only says so. These are this
version's steps and labels, as they were run in Chrome against its image in Docker, through the pinned Traefik and through a tunnel's
`http://localhost`, which works the same:

1. Sign in. Until someone has finished it, a sign-in opens **Control who can join** first: keep **Invite-only**, then **Continue**, then **Finish
   setup**, then **Go to dashboard**. Anyone would open sign-up to the internet, and `InfisicalOpenToClaim` would page.
2. **Server Console**, at the top, then **Authentication**: turn off Google SSO, GitHub SSO, GitLab SSO, SAML SSO, OIDC SSO and LDAP, keep Email,
   and **Save**. The sign-in page then shows email and password alone. The route refuses those logins anyway.
3. The person icon at the top right, then **Personal Settings**, then the tab **Authentication**.
4. At **Authenticator app**, choose **Set up**. Scan the QR code, or type the key under it, click the first of the six boxes and type the code.
   It saves by itself, and says Authenticator app configured.
5. **Preferred 2FA method** now reads Authenticator app. Choose **Enable two-factor authentication**, then **Enable**.
6. Unless a code was typed in the last 10 minutes, a window asks for one from the app, and closes by itself. Allow pop-ups for this site if the
   browser blocks it.
7. **Save your recovery codes**: ten codes, each good once. **Download** or **Copy** them into the password manager, apart from the phone, tick
   that you saved them, and **Done**.

From then on a sign-in asks for the app's code after the password, with **Use a recovery code** under it. Recovery codes can be read again,
or replaced, in the same tab: **View**, **Regenerate**. A passkey is not an option: it is bound to the host it was made on, so one made on the
public host would not work through the tunnel.

## Locked out of Infisical

Five wrong codes in a row lock the account for 5 minutes, ten for 30, fifteen for an hour, and twenty until someone unlocks it. A lock refuses even
the right password, with Account is locked, and a sign-in that gets through clears the count. A stranger cannot cause any of this without the
password: wrong passwords lock nothing in this version, because their count only asks for a captcha, which needs a key this platform does not set,
and the route's limit is 10 a minute per address. That limit answers 429 and lets one more try through every 6 seconds: wait, or use the tunnel.

Locked, with the phone at hand: wait, or clear the lock in the database through the tunnel, and sign in with the password and a code. After twenty,
Infisical writes an unlock link to its log, because there is no SMTP to mail it. The link names the public host, which refuses it, and the same
path through the tunnel unlocks the account. Infisical then redirects to the public host's `/login` whether the unlock worked or not, and
before the route is up that shows a TLS error. So go back to `http://localhost:<port>/login` yourself: if a sign-in still reads Account is
locked, the unlock failed, and the first statement below clears it.

```
EMAIL="$(jq -r .email .local/hosted/plane-prod/secret-zero/infisical-admin.json)"
printf "UPDATE users SET \"consecutiveFailedMfaAttempts\" = 0, \"isLocked\" = false, \"temporaryLockDateEnd\" = NULL WHERE email = '%s';\n" "$EMAIL" \
  | .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod -n infisical exec -i infisical-postgres-0 -c postgres -- \
    sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Lost the phone, with the recovery codes kept: sign in, choose **Use a recovery code**, type one and **Continue**. In Personal Settings,
Authentication, choose **Disable 2FA**, then **Disable**. Then at Authenticator app **Remove**, then **Remove**, and set up the new phone from step 4
above. While two-factor is on, removing its only method is refused, which is why it goes off first.

The phone and the codes both gone: turn two-factor off in the database, and remove the old app and codes, then sign in with the password alone and
set two-factor up again at once, from step 4. It takes effect with no restart, and leaves the password as it is:

```
EMAIL="$(jq -r .email .local/hosted/plane-prod/secret-zero/infisical-admin.json)"
printf "UPDATE users SET \"isMfaEnabled\" = false, \"selectedMfaMethod\" = NULL, \"consecutiveFailedMfaAttempts\" = 0, \"isLocked\" = false, \"temporaryLockDateEnd\" = NULL WHERE email = '%s';\nDELETE FROM totp_configs WHERE \"userId\" = (SELECT id FROM users WHERE email = '%s');\nDELETE FROM user_mfa_recovery_codes WHERE \"userId\" = (SELECT id FROM users WHERE email = '%s');\n" "$EMAIL" "$EMAIL" "$EMAIL" \
  | .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod -n infisical exec -i infisical-postgres-0 -c postgres -- \
    sh -c 'psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

Each of those, the locks, the unlock link, the recovery code, Disable 2FA and both statements, was run against this image in Docker, and not on
this cluster. A lost password is in [`infisical/README.md`](../../infisical/README.md#admin-token-and-password-both-gone): the same database, a new
hash.

**The admin token, once two-factor is on.** Scripts reach Infisical with the instance admin identity's token in
`.local/hosted/plane-prod/secret-zero/infisical-admin.json`, which ends 90 days after it was made, and `make remote-status TARGET=plane-prod`
says when. They replace it by signing in with the password, and with two-factor on that stops at the code: bootstrap's step 6,
`scripts/infisical-bootstrap.sh` and a restore stop with the steps for a person, the UI's first. So make the next one before it ends: sign in,
then Access Control, Machine Identities, Instance Admin Identity, Token Auth, Add Token, and write the token to
`.local/hosted/plane-prod/secret-zero/infisical-admin-token.new`, one line, mode 0600. The next `make remote-bootstrap TARGET=plane-prod
CONFIRM=plane-prod`, or a restore, checks it against the server, moves it into place and records that it did. A token made there works only
inside the cluster, because the route refuses a machine's credential, and that is where the scripts use it.

## Infisical reads open

`InfisicalOpenToClaim` is critical: through its public route, Infisical did not say that it has its admin and is closed to sign-up. Either way the
next person to sign up or to claim it may own every production secret. The route refuses the sign-up and bootstrap calls, so the alert means that
layer is the one left, and it is not to be left alone.

1. Close 443 first, so nothing else reaches it: `TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/edge.sh http`. Plane goes off the internet
   with it, and stays off until step 4. `edge.sh owner <your ipv4>` reaches the site from one address meanwhile.
2. Through the tunnel, read `/api/v1/admin/config`. With `initialized` false, the database is not the one the platform had: stop, and read
   [`docs/disaster-recovery.md`](../../docs/disaster-recovery.md#scenario-infisical-lost), because the bootstrap would make new secrets. With
   `allowSignUp` true, sign in as the admin through the tunnel, set **Server Console**, **General**, **Signup mode** to Disabled, and save, which
   the config shows at once. Or run `UPDATE super_admin SET "allowSignUp" = false;` through `psql` as above: Infisical keeps the config in Redis
   for 60 seconds, and only a change through its API clears that, so this one shows within a minute.
3. In Server Console, **Resource Overview**, **User Identities**, look for anyone who is not the admin, and remove them, before 443 opens again.
4. `TARGET=plane-prod CONFIRM=plane-prod scripts/hosted/edge.sh open`, which refuses until Infisical reads claimed and closed, so for up to a
   minute after a `psql` change. It refuses as well while Infisical's config does not answer at all, and then Plane stays off the internet with
   it: `edge.sh owner <your ipv4>` until Infisical answers.

## Locked out of Grafana

Grafana refuses even the right password from an address with five failed logins in the last five minutes, and that clears by itself five minutes after
the last of them. It counts per address and not per username, so a stranger's guesses at `grafana-admin` lock out only the stranger, and the name needs no
secrecy. That rests on Traefik seeing each client's own address. `make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=outside` reads that on this
cluster, in the row `Traefik sees a client's own address`. If it fails, every client shares one count, and anyone's guesses lock out everyone.

If it is your address, any of these gets you in before the five minutes are up. A session from before still works. `make remote-ui TARGET=plane-prod UI=grafana`
arrives from another address, the pod's own. A new pod starts with an empty database, so it clears at once, and takes its login from the Secret again, where a
container restart keeps the database, and the count with it. All of that was run on Grafana 13.3.0 in Docker, through Traefik, from two addresses, with this
configuration, and not on this cluster:

```
.tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod -n monitoring delete pod \
  -l app.kubernetes.io/name=grafana,app.kubernetes.io/instance=kube-prometheus-stack
```

## After a rollback: the database does not go back

A revert on main, or promoting an older set, moves the images and not the database. A migration the newer image ran stays applied. If the
older image runs on that schema, stop there. If it does not, or if the migration itself did the damage, restore the dump from before it.
Everything written since that dump is lost, so a person decides that. A revert of the first promotion is refused instead:
[`docs/evidence/promotions/README.md`](../../docs/evidence/promotions/README.md) says why. None of this has run on a real cluster yet, so
read each step before running it.

**Which dump.** Each backend image gets one, taken by Job `plane-prod-predeploy-dump` just before that image's migrator ran. It is named
`<UTC time>-<first 16 hex of the backend digest>`, and its `manifest.json` names the whole image. So to undo backend X's migrations, take the
dump named for X, and not the one for the image you are going back to. The names of the last five are the folders under
`/srv/wayline/backups/plane-prod/predeploy` on the node. Until that night's backup such a folder holds the dump, in plain. After that it
is empty, and the dump is a restic snapshot, tag `predeploy`, of that path, kept for 90 days. Off the VPS there is no copy of these: a pull
takes tag `wayline`, so past that the nearest thing is the nightly from before the promotion.

**In this order:**

1. `make remote-backup TARGET=plane-prod CONFIRM=plane-prod ONLY=plane-prod`, so what is there now is kept too.
2. Roll back first: the revert on main, and wait for `release-plane-prod` and for Argo CD to take it. With the newer image still deployed, its
   migrator would run the same migrations again on what you are about to restore.
3. Pause auto-sync, root first or it puts the other back, and wait until neither has a sync Running. A failing one never ends by itself, because
   it retries for ever: `monitoring/ops/lib.sh`'s `argo_wait_idle` shows how to terminate it.
   ```
   kc() { .tools/bin/kubectl --kubeconfig .local/hosted/plane-prod/kubeconfig --context plane-prod "$@"; }
   kc -n argocd patch application root --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
   kc -n argocd patch application plane-prod --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false}}}}'
   ```
4. Stop what writes: `for d in plane-api-wl plane-worker-wl plane-beat-worker-wl plane-live-wl; do kc -n plane-prod scale deployment/$d --replicas=0; done`
5. Restore, through a Job in plane-prod. It carries the label that lets a backup Job reach Postgres, and it uses the images in Git. `dropdb` and
   not `pg_restore --clean`, so tables newer than the dump cannot survive. The dump holds no objects, and Silo stays as it is: restored rows
   still find theirs, and what was uploaded since is left over and harmless.

```
NAME=<the folder's name>
POSTGRES_IMAGE="$(.tools/bin/yq -r '.images[] | select(.name == "postgres") | .newName + ":" + .newTag + "@" + .digest' helm/plane/overlays/prod/kustomization.yaml)"
RESTIC_IMAGE="$(.tools/bin/yq -r 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[] | select(.name == "seal") | .image' gitops/clusters/plane-prod/platform/backup/plane-prod.yaml)"
kc apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata: {name: restore-predeploy, namespace: plane-prod}
spec:
  backoffLimit: 0
  template:
    metadata:
      labels: {app.kubernetes.io/name: restore-predeploy, app.kubernetes.io/component: backup}
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 70, runAsGroup: 70, fsGroup: 70, seccompProfile: {type: RuntimeDefault}}
      volumes:
        - {name: backups, persistentVolumeClaim: {claimName: backups, readOnly: true}}
        - {name: restic-password, secret: {secretName: restic-password, defaultMode: 0440}}
        - {name: work, emptyDir: {sizeLimit: 30Gi}}
      initContainers:
        - name: unseal
          image: $RESTIC_IMAGE
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          resources: {requests: {cpu: 50m, memory: 128Mi}, limits: {cpu: "1", memory: 1Gi}}
          env:
            - {name: RESTIC_REPOSITORY, value: /backups/restic}
            - {name: RESTIC_PASSWORD_FILE, value: /run/restic/password}
            - {name: RESTIC_CACHE_DIR, value: /work/cache}
            - {name: TMPDIR, value: /work}
            - {name: HOME, value: /work}
          volumeMounts:
            - {name: backups, mountPath: /backups, readOnly: true}
            - {name: restic-password, mountPath: /run/restic, readOnly: true}
            - {name: work, mountPath: /work}
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              if [ -f /backups/predeploy/$NAME/plane.dump ]; then cp /backups/predeploy/$NAME/plane.dump /work/plane.dump; exit 0; fi
              restic --no-lock restore latest --tag predeploy --path /backups/predeploy/$NAME --target /work/restored --verify
              cp /work/restored/backups/predeploy/$NAME/plane.dump /work/plane.dump
      containers:
        - name: restore
          image: $POSTGRES_IMAGE
          securityContext: {allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: [ALL]}}
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: "1", memory: 512Mi}}
          env:
            - {name: PGHOST, value: plane-pgdb}
            - {name: PGUSER, valueFrom: {secretKeyRef: {name: plane-pgdb, key: POSTGRES_USER}}}
            - {name: PGPASSWORD, valueFrom: {secretKeyRef: {name: plane-pgdb, key: POSTGRES_PASSWORD}}}
            - {name: POSTGRES_DB, valueFrom: {secretKeyRef: {name: plane-pgdb, key: POSTGRES_DB}}}
          volumeMounts:
            - {name: work, mountPath: /work}
          command: [/bin/sh, -c]
          args:
            - |
              set -eu
              dropdb --maintenance-db=postgres --force --if-exists "\$POSTGRES_DB"
              createdb --maintenance-db=postgres "\$POSTGRES_DB"
              pg_restore --no-owner --no-privileges --exit-on-error --single-transaction -d "\$POSTGRES_DB" /work/plane.dump
              vacuumdb --analyze-only "\$POSTGRES_DB"
YAML
kc -n plane-prod wait --for=condition=Complete job/restore-predeploy --timeout=1h
```
6. Old cache entries and queued tasks describe rows from before the restore:
   `kc -n plane-prod exec plane-redis-wl-0 -c plane-redis -- valkey-cli FLUSHALL`, and
   `kc -n plane-prod exec plane-rabbitmq-wl-0 -c plane-rabbitmq -- rabbitmqctl -q purge_queue celery`.
7. Delete the Job, and put auto-sync back, plane-prod first and root last:
   `kc -n argocd patch application <name> --type json -p '[{"op":"remove","path":"/spec/syncPolicy/automated/enabled"}]'`. Argo CD puts the
   replicas back, unless you terminated a sync in step 3: it does not retry that revision by itself, and the next commit starts a new one.
   Then `make remote-test TARGET=plane-prod CONFIRM=plane-prod ONLY=argo`, and `make remote-smoke TARGET=plane-prod`.
