// Load test for one Plane environment, run in the cluster by tests/load/run.sh with grafana/k6:2.3.0.
//
// Session auth, not X-Api-Key, because of two traps in Plane's code:
//   1. API_KEY_RATE_LIMIT defaults to 60/minute per key, so 5 VUs would 429 almost at once.
//   2. APITokenLogMiddleware queues every X-Api-Key request and its whole response body for
//      api_activity_logs, so an API-key test measures log writes and grows the database quickly.
// A signed-in session is what the web app really sends. DRF's anonymous throttle does not apply to it,
// and writes still go through Celery. Only the one sign-in in setup() counts against the
// sign-in limit of 10 a minute per IP.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate, Trend } from 'k6/metrics';

const BASE = __ENV.BASE_URL; // Traefik's Service, with the public host in the Host header
const HOST = __ENV.PLANE_HOST;
const RUN = __ENV.RUN_ID;
// 1 is the realistic pass, about 8 requests a second at 20 VUs. 0 is the saturation pass.
const THINK = Number(__ENV.THINK === undefined ? 1 : __ENV.THINK);
const WORKSPACE = 'k6-load';
const IDENTIFIER = 'K6RUN'; // Not the first five letters of the name: the seed task claims those.

const throttled = new Rate('throttled');
const writeTime = new Trend('write_duration', true);

function step(vus, startMinutes) {
  return {
    executor: 'constant-vus',
    vus,
    duration: '3m',
    startTime: `${startMinutes}m`,
    gracefulStop: '20s',
  };
}

const LIMIT = { reads: 'p(95)<3000', writes: 'p(95)<5000' };

export const options = {
  // One scenario per load step, so every step gets its own numbers in the summary.
  scenarios: {
    vus_05: step(5, 0),
    vus_10: step(10, 3),
    vus_20: step(20, 6),
  },
  // Starting points. The single API worker sets the ceiling, so tune these after a first baseline.
  thresholds: {
    http_req_failed: [{ threshold: 'rate<0.05', abortOnFail: true, delayAbortEval: '2m' }],
    throttled: ['rate<0.01'],
    'http_req_duration{name:read}': [LIMIT.reads],
    'http_req_duration{name:write}': [LIMIT.writes],
    // Thresholds on tagged metrics are also what makes k6 report per-step figures in the summary.
    'http_req_duration{scenario:vus_05}': [LIMIT.writes],
    'http_req_duration{scenario:vus_10}': [LIMIT.writes],
    'http_req_duration{scenario:vus_20}': [LIMIT.writes],
    'http_req_failed{scenario:vus_05}': ['rate<0.05'],
    'http_req_failed{scenario:vus_10}': ['rate<0.05'],
    'http_req_failed{scenario:vus_20}': ['rate<0.05'],
  },
  discardResponseBodies: true,
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

function textParams(extra) {
  return Object.assign({ headers: { Host: HOST }, responseType: 'text', redirects: 0 }, extra || {});
}

function jsonParams(session, name) {
  return {
    headers: { Host: HOST, 'Content-Type': 'application/json' },
    cookies: { 'session-id': session },
    responseType: 'text',
    tags: { name },
    responseCallback: http.expectedStatuses(200, 201, 404),
  };
}

function signIn() {
  const token = http.get(`${BASE}/auth/get-csrf-token/`, textParams());
  if (token.status !== 200) throw new Error(`csrf token: ${token.status}`);
  const res = http.post(
    `${BASE}/auth/sign-in/`,
    {
      csrfmiddlewaretoken: token.json('csrf_token'),
      email: __ENV.PLANE_EMAIL,
      password: __ENV.PLANE_PASSWORD,
    },
    textParams(),
  );
  // Form endpoints answer 302 either way, so the error shows only in Location.
  const location = res.headers.Location || '';
  if (res.status !== 302 || location.includes('error_code')) throw new Error(`sign-in: ${res.status}`);
  const cookies = res.cookies['session-id'];
  if (!cookies || !cookies.length) throw new Error('sign-in set no session-id cookie');
  return cookies[0].value;
}

export function setup() {
  const session = signIn();
  const params = jsonParams(session, 'setup');

  const workspace = http.get(`${BASE}/api/workspaces/${WORKSPACE}/`, params);
  if (workspace.status === 404) {
    const created = http.post(
      `${BASE}/api/workspaces/`,
      JSON.stringify({ name: 'k6 load', slug: WORKSPACE, organization_size: '1-10' }),
      params,
    );
    if (created.status !== 201) throw new Error(`create workspace: ${created.status}`);
  } else if (workspace.status !== 200) {
    throw new Error(`read workspace: ${workspace.status}`);
  }

  const listed = http.get(`${BASE}/api/workspaces/${WORKSPACE}/projects/`, params);
  if (listed.status !== 200) throw new Error(`list projects: ${listed.status}`);
  const body = listed.json();
  const projects = Array.isArray(body) ? body : body.results || [];
  let project = projects.find((p) => p.identifier === IDENTIFIER);
  if (!project) {
    const created = http.post(
      `${BASE}/api/workspaces/${WORKSPACE}/projects/`,
      JSON.stringify({ name: 'k6 load', identifier: IDENTIFIER }),
      params,
    );
    if (created.status !== 201) throw new Error(`create project: ${created.status}`);
    project = created.json();
  }
  return { session, projectId: project.id };
}

export default function (data) {
  const read = {
    headers: { Host: HOST },
    cookies: { 'session-id': data.session },
    tags: { name: 'read' },
    responseCallback: http.expectedStatuses(200),
  };
  const issues = `${BASE}/api/workspaces/${WORKSPACE}/projects/${data.projectId}/issues/`;
  const dice = Math.random();
  let res;
  if (dice < 0.15) {
    res = http.get(`${BASE}/api/users/me/`, read);
  } else if (dice < 0.35) {
    res = http.get(`${BASE}/api/workspaces/${WORKSPACE}/projects/`, read);
  } else if (dice < 0.9) {
    res = http.get(`${issues}?per_page=20`, read);
  } else {
    // A write fans out to Celery through issue_activity, so this is what exercises the queue.
    res = http.post(issues, JSON.stringify({ name: `k6-${RUN}-${__VU}-${__ITER}` }), {
      headers: { Host: HOST, 'Content-Type': 'application/json' },
      cookies: { 'session-id': data.session },
      tags: { name: 'write' },
      responseCallback: http.expectedStatuses(201),
    });
    writeTime.add(res.timings.duration);
  }
  throttled.add(res.status === 429);
  check(res, { 'status ok': (r) => r.status === 200 || r.status === 201 });
  if (THINK > 0) sleep(THINK + Math.random() * 2 * THINK);
}

// The Job's logs are the only way out of the pod, so the summary goes to stdout between markers.
export function handleSummary(data) {
  return { stdout: `\n@@K6-SUMMARY-BEGIN@@\n${JSON.stringify(data)}\n@@K6-SUMMARY-END@@\n` };
}
