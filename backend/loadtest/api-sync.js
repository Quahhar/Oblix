import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

const baseUrl = __ENV.BASE_URL || 'http://api:8000';
const userCount = Number(__ENV.USER_COUNT || __ENV.VUS || 10);
const duration = __ENV.DURATION || '30s';
const syncIntervalSeconds = Number(__ENV.SYNC_INTERVAL_SECONDS || 1);
const writeRate = Number(__ENV.WRITE_RATE || 0.2);
const errors = new Rate('application_errors');
const syncLatency = new Trend('sync_duration', true);
const createdNotes = new Counter('sync_notes_created');
let cursor = null;

export const options = {
  vus: Number(__ENV.VUS || 10),
  duration,
  setupTimeout: __ENV.SETUP_TIMEOUT || '5m',
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
      email: `loadtest-${runId}-${index}@tensoractivity.com`,
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
  // Match the production client: one push request both drains the local
  // outbox and pulls server changes since this device's cursor. Most cycles
  // are idle; WRITE_RATE controls how often a small offline edit is included.
  const writes = Math.random() < writeRate;
  const changes = writes
    ? [{
        entity_type: 'note',
        entity_id: uuidv4(),
        action: 'create',
        data: { title: 'Load test note', content: 'small sync payload', content_type: 'plain' },
        device_id: `loadtest-vu-${__VU}`,
        timestamp: new Date().toISOString(),
      }]
    : [];

  const started = Date.now();
  const synced = http.post(`${baseUrl}/api/sync/push`, JSON.stringify({
    changes,
    last_sync_at: cursor,
  }), headers);
  syncLatency.add(Date.now() - started);
  const syncOk = check(synced, { 'sync cycle succeeds': (r) => r.status === 200 });
  errors.add(!syncOk);
  if (syncOk) {
    const body = JSON.parse(synced.body);
    cursor = body.server_time || cursor;
    if (writes) createdNotes.add(1);
  }
  sleep(syncIntervalSeconds);
}
