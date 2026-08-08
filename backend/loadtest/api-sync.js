import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const baseUrl = __ENV.BASE_URL || 'http://api:8000';
const userCount = Number(__ENV.USER_COUNT || __ENV.VUS || 10);
const duration = __ENV.DURATION || '30s';
const errors = new Rate('application_errors');
const syncLatency = new Trend('sync_duration', true);
const createdNotes = new Counter('sync_notes_created');

export const options = {
  vus: Number(__ENV.VUS || 10),
  duration,
  thresholds: {
    http_req_failed: ['rate<0.01'],
    application_errors: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

function uuidv4() {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (character) => {
    const value = Math.floor(Math.random() * 16);
    const nibble = character === 'x' ? value : (value & 0x3) | 0x8;
    return nibble.toString(16);
  });
}

function jsonHeaders(token) {
  return {
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    },
  };
}

export function setup() {
  const users = [];
  const runId = Date.now();
  for (let index = 0; index < userCount; index += 1) {
    const response = http.post(`${baseUrl}/api/auth/register`, JSON.stringify({
      email: `loadtest-${runId}-${index}@oblix.invalid`,
      password: 'loadtest-password-not-a-real-secret',
      display_name: `Load test ${index}`,
      device_id: `loadtest-${index}`,
    }), { headers: { 'Content-Type': 'application/json' } });
    if (response.status !== 201) {
      throw new Error(`Could not create test user ${index}: HTTP ${response.status} ${response.body}`);
    }
    users.push(JSON.parse(response.body).access_token);
  }
  return users;
}

export default function (tokens) {
  const token = tokens[(__VU - 1) % tokens.length];
  const headers = jsonHeaders(token);
  const notes = http.get(`${baseUrl}/api/notes?page_size=50`, headers);
  const pulled = http.get(`${baseUrl}/api/sync/pull?limit=100`, headers);
  const readsOk = check(notes, { 'notes list succeeds': (r) => r.status === 200 }) &&
    check(pulled, { 'sync pull succeeds': (r) => r.status === 200 });
  errors.add(!readsOk);

  // Twenty percent of normal client cycles include a small offline-sync write.
  if (Math.random() < 0.2) {
    const now = new Date().toISOString();
    const started = Date.now();
    const pushed = http.post(`${baseUrl}/api/sync/push`, JSON.stringify({
      changes: [{
        entity_type: 'note',
        entity_id: uuidv4(),
        action: 'create',
        data: { title: 'Load test note', content: 'small sync payload', content_type: 'plain' },
        device_id: `loadtest-vu-${__VU}`,
        timestamp: now,
      }],
      last_sync_at: null,
    }), headers);
    syncLatency.add(Date.now() - started);
    const pushOk = check(pushed, { 'sync push succeeds': (r) => r.status === 200 });
    errors.add(!pushOk);
    if (pushOk) createdNotes.add(1);
  }
  sleep(1);
}
