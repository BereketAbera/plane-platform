# Load test

`make test-load ENV=dev` runs `plane.js` as a Job in `plane-dev` and writes
`.local/evidence-raw/load-<run>/results.json`: k6's numbers per load step, Prometheus peaks per pod,
and a CPU, memory and disk sample every 15 seconds.

Needs one earlier `make test-e2e ENV=dev`, whose account in `.local/test-accounts.env` it signs in
with. `THINK=0` makes the saturation pass; run the default pass first, since a think-time pass may never
reach the API's ceiling.

## Why session auth

The obvious way to test Plane's API is `X-Api-Key`. It measures the wrong thing:

- `API_KEY_RATE_LIMIT` defaults to 60 a minute per key, and `api_tokens.allowed_rate_limit` is not
  read, so 5 VUs get 429s almost at once. Raising it means a value on the API and a change to dev that
  prod-sim does not have.
- `APITokenLogMiddleware` queues each request and its whole response through Celery into
  `api_activity_logs`, so reads become writes and the database grows quickly.

A session cookie is what the web app sends. The anonymous throttle does not apply to a signed-in user,
so nothing has to change in the environment, and the only queue traffic is real: `issue_activity` from
the 10% of requests that create work items.

## What to expect

- One gunicorn worker sets the ceiling, so saturation at low concurrency is the expected finding.
- `--max-requests 1200` recycles that worker, which shows as periodic latency spikes.
- Work items are named `k6-<run>-*` in the workspace `k6-load`, so they are easy to find. Delete that
  workspace to remove them. They stay in backups until then.

## Reading the numbers

`k6.metrics` has `http_req_duration{scenario:vus_05}`, `vus_10` and `vus_20`, one per load step.
`disk.vm_var_used_kib` is the VM's real growth. `disk.host_free_gib` is the Mac's, which nothing inside
the cluster can see. Run it twice and take the worse: a laptop has noisy neighbours.
