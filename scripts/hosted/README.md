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
| `ui.sh` | Port-forward an admin UI. None has a public route but Grafana, which this also reaches when that route is down | `remote-ui` |
| `grafana-admin.sh` | Make Grafana's admin login once and write its Secret (`apply`), or print the URL and username and copy the password (`login`) | `remote-grafana-admin` |
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

`grafana-tls` can fail one way more: DNS. The zone's wildcard answers for any name with no record of its own, and that points at Vercel, so its
A record has to be live before Argo CD first sees that Certificate.

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
