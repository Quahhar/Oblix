import http from 'k6/http';
import ws from 'k6/ws';
import { check } from 'k6';
import { Counter, Rate } from 'k6/metrics';

const baseUrl = __ENV.BASE_URL || 'http://api:8000';
const wsUrl = baseUrl.replace(/^http/, 'ws');
const userCount = Number(__ENV.USER_COUNT || __ENV.VUS || 10);
const duration = __ENV.DURATION || '30s';
const holdSeconds = Number(__ENV.HOLD_SECONDS || 20);
const errors = new Rate('websocket_errors');
const connected = new Counter('websocket_connections');

export const options = {
  vus: Number(__ENV.VUS || 10),
  duration,
  thresholds: {
    websocket_errors: ['rate<0.01'],
  },
};

function registerUser(index, runId) {
  const response = http.post(`${baseUrl}/api/auth/register`, JSON.stringify({
    email: `ws-loadtest-${runId}-${index}@tensoractivity.com`,
    password: 'loadtest-password-not-a-real-secret',
    display_name: `WS load test ${index}`,
  }), { headers: { 'Content-Type': 'application/json' } });
  if (response.status !== 201) throw new Error(`Registration failed: HTTP ${response.status}`);
  return JSON.parse(response.body).access_token;
}

export function setup() {
  const users = [];
  const runId = Date.now();
  for (let index = 0; index < userCount; index += 1) {
    const token = registerUser(index, runId);
    const note = http.post(`${baseUrl}/api/notes`, JSON.stringify({ title: 'WebSocket load test' }), {
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    });
    if (note.status !== 201) throw new Error(`Note creation failed: HTTP ${note.status}`);
    users.push({ token, noteId: JSON.parse(note.body).id });
  }
  return users;
}

export default function (users) {
  const user = users[(__VU - 1) % users.length];
  const response = ws.connect(`${wsUrl}/api/collaboration/notes/${user.noteId}/ws`, {
    headers: { Authorization: `Bearer ${user.token}` },
  }, (socket) => {
    socket.on('open', () => {
      socket.send(JSON.stringify({ type: 'hello', client_id: `loadtest-vu-${__VU}` }));
    });
    socket.on('message', (message) => {
      const parsed = JSON.parse(message);
      if (parsed.type === 'snapshot') connected.add(1);
      if (parsed.type === 'error' || parsed.type === 'access') errors.add(1);
    });
    socket.setTimeout(() => socket.close(), holdSeconds * 1000);
  });
  errors.add(response && response.status !== 101);
  check(response, { 'websocket upgrade succeeds': (r) => r && r.status === 101 });
}
