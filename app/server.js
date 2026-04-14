'use strict';

const { Worker, isMainThread, parentPort, workerData } = require('worker_threads');
const express = require('express');
const client = require('prom-client');

// ---------------------------------------------------------------------------
// Worker thread: CPU burn runs off the main event loop so the server stays
// responsive to other requests during a CPU chaos injection.
// ---------------------------------------------------------------------------
if (!isMainThread) {
  const stopAt = Date.now() + workerData.seconds * 1000;
  let accumulator = 0;
  while (Date.now() < stopAt) {
    accumulator += Math.sqrt(Math.random() * Number.MAX_SAFE_INTEGER);
  }
  parentPort.postMessage({ done: true, accumulator });
  process.exit(0);
}

// ---------------------------------------------------------------------------
// Main thread
// ---------------------------------------------------------------------------

const app = express();
app.use(express.json());

const port = Number(process.env.PORT || 8080);

// Optional API key for chaos control endpoints. When set, requests to
// /chaos/* must supply the matching "x-chaos-key" header.
const CHAOS_API_KEY = process.env.CHAOS_API_KEY || '';

const MEMORY_HARD_LIMIT_MB = 1024;

const state = {
  errorRatePercent: 0,
  latencyMs: 0,
  dependencyDown: false,
  retainedMemoryMb: 0,
  memoryChunks: []
};

const register = new client.Registry();
client.collectDefaultMetrics({ register, prefix: 'chaos_' });

const requestCounter = new client.Counter({
  name: 'chaos_http_requests_total',
  help: 'Total HTTP requests handled by the demo API',
  labelNames: ['route', 'method', 'status'],
  registers: [register]
});

const errorCounter = new client.Counter({
  name: 'chaos_errors_total',
  help: 'Total injected or simulated request failures',
  labelNames: ['route', 'reason'],
  registers: [register]
});

const latencyHistogram = new client.Histogram({
  name: 'chaos_http_request_duration_seconds',
  help: 'Request latency in seconds',
  labelNames: ['route', 'method', 'status'],
  buckets: [0.05, 0.1, 0.25, 0.5, 1, 2, 5],
  registers: [register]
});

const errorRateGauge = new client.Gauge({
  name: 'chaos_error_injection_percent',
  help: 'Current random error injection percent (0-100)',
  registers: [register]
});

const latencyGauge = new client.Gauge({
  name: 'chaos_latency_injection_ms',
  help: 'Current additional latency injection in milliseconds',
  registers: [register]
});

const dependencyGauge = new client.Gauge({
  name: 'chaos_dependency_available',
  help: 'Whether dependency is available (1) or down (0)',
  registers: [register]
});

const retainedMemoryGauge = new client.Gauge({
  name: 'chaos_retained_memory_mb',
  help: 'Application memory intentionally retained for testing (MB)',
  registers: [register]
});

const incidentModeGauge = new client.Gauge({
  name: 'chaos_incident_mode',
  help: 'Whether any active fault injection is enabled (1=true, 0=false)',
  registers: [register]
});

// Tracks how many times chaos state has been reset — useful for audit/review.
const chaosResetCounter = new client.Counter({
  name: 'chaos_resets_total',
  help: 'Total number of times /chaos/reset has been called',
  registers: [register]
});

function updateGauges() {
  errorRateGauge.set(state.errorRatePercent);
  latencyGauge.set(state.latencyMs);
  dependencyGauge.set(state.dependencyDown ? 0 : 1);
  retainedMemoryGauge.set(state.retainedMemoryMb);

  const incidentEnabled =
    state.errorRatePercent > 0 ||
    state.latencyMs > 0 ||
    state.dependencyDown ||
    state.retainedMemoryMb > 0;
  incidentModeGauge.set(incidentEnabled ? 1 : 0);
}

updateGauges();

function sleep(ms) {
  if (ms <= 0) {
    return Promise.resolve();
  }

  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function parseBoolean(value) {
  if (typeof value === 'boolean') {
    return value;
  }

  if (typeof value === 'string') {
    if (value.toLowerCase() === 'true') {
      return true;
    }

    if (value.toLowerCase() === 'false') {
      return false;
    }
  }

  return null;
}

function parseBoundedNumber(value, min, max) {
  if (typeof value !== 'number' || Number.isNaN(value)) {
    return null;
  }

  if (value < min || value > max) {
    return null;
  }

  return value;
}

// Runs CPU-intensive work in a Worker thread so the main event loop is not
// blocked. Returns a Promise that resolves when the burn completes.
function burnCpu(seconds) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(__filename, { workerData: { seconds } });
    worker.once('message', resolve);
    worker.once('error', reject);
    worker.once('exit', (code) => {
      if (code !== 0) {
        reject(new Error(`CPU burn worker exited with code ${code}`));
      }
    });
  });
}

function maybeFail(route) {
  if (state.dependencyDown) {
    errorCounter.inc({ route, reason: 'dependency_down' });
    return {
      status: 503,
      body: {
        ok: false,
        error: 'Simulated dependency outage'
      }
    };
  }

  if (Math.random() * 100 < state.errorRatePercent) {
    errorCounter.inc({ route, reason: 'error_injection' });
    return {
      status: 500,
      body: {
        ok: false,
        error: 'Injected server error'
      }
    };
  }

  return null;
}

async function handleBusinessRequest(route, req, res, payloadBuilder) {
  const startedAt = process.hrtime.bigint();
  let status = '200';

  try {
    await sleep(state.latencyMs);

    const failure = maybeFail(route);
    if (failure) {
      status = String(failure.status);
      return res.status(failure.status).json(failure.body);
    }

    const payload = payloadBuilder();
    return res.status(200).json(payload);
  } finally {
    const durationSeconds = Number(process.hrtime.bigint() - startedAt) / 1e9;
    requestCounter.inc({ route, method: req.method, status });
    latencyHistogram.observe({ route, method: req.method, status }, durationSeconds);
  }
}

// ---------------------------------------------------------------------------
// Authentication middleware for chaos control endpoints.
// Only enforced when CHAOS_API_KEY is set in the environment.
// ---------------------------------------------------------------------------
function requireChaosKey(req, res, next) {
  if (!CHAOS_API_KEY) {
    return next();
  }

  const provided = req.headers['x-chaos-key'];
  if (!provided || provided !== CHAOS_API_KEY) {
    return res.status(401).json({ error: 'Missing or invalid x-chaos-key header' });
  }

  return next();
}

// ---------------------------------------------------------------------------
// Ensure req.body is a plain object (guards against missing Content-Type or
// empty body producing undefined/null, which would crash parseBoundedNumber).
// ---------------------------------------------------------------------------
function requireBody(req, res, next) {
  if (!req.body || typeof req.body !== 'object' || Array.isArray(req.body)) {
    return res.status(400).json({ error: 'Request body must be a JSON object' });
  }

  return next();
}

// ---------------------------------------------------------------------------
// Health / readiness probes
// ---------------------------------------------------------------------------

app.get('/healthz', (req, res) => {
  if (state.dependencyDown) {
    return res.status(503).json({ ok: false, status: 'degraded' });
  }

  return res.status(200).json({ ok: true, status: 'healthy' });
});

app.get('/readyz', (req, res) => {
  if (state.retainedMemoryMb > 512) {
    return res.status(503).json({ ok: false, reason: 'retained memory exceeds threshold' });
  }

  return res.status(200).json({ ok: true });
});

// ---------------------------------------------------------------------------
// Business endpoints
// ---------------------------------------------------------------------------

app.get('/api/orders', async (req, res) => {
  return handleBusinessRequest('/api/orders', req, res, () => ({
    ok: true,
    orderId: `ord-${Date.now()}`,
    status: 'accepted',
    traceId: `trace-${Math.random().toString(16).slice(2, 10)}`
  }));
});

app.get('/api/payments', async (req, res) => {
  return handleBusinessRequest('/api/payments', req, res, () => ({
    ok: true,
    paymentId: `pay-${Date.now()}`,
    status: 'captured',
    traceId: `trace-${Math.random().toString(16).slice(2, 10)}`
  }));
});

app.get('/api/notifications', async (req, res) => {
  return handleBusinessRequest('/api/notifications', req, res, () => ({
    ok: true,
    notificationId: `ntf-${Date.now()}`,
    status: 'queued',
    traceId: `trace-${Math.random().toString(16).slice(2, 10)}`
  }));
});

// ---------------------------------------------------------------------------
// Chaos control endpoints — protected by requireChaosKey + requireBody
// ---------------------------------------------------------------------------

app.get('/chaos/state', requireChaosKey, (req, res) => {
  return res.status(200).json({
    errorRatePercent: state.errorRatePercent,
    latencyMs: state.latencyMs,
    dependencyDown: state.dependencyDown,
    retainedMemoryMb: state.retainedMemoryMb
  });
});

app.post('/chaos/error-rate', requireChaosKey, requireBody, (req, res) => {
  const percent = parseBoundedNumber(req.body.percent, 0, 100);
  if (percent === null) {
    return res.status(400).json({ error: 'percent must be a number between 0 and 100' });
  }

  state.errorRatePercent = percent;
  updateGauges();

  return res.status(200).json({ message: 'Error injection updated', percent: state.errorRatePercent });
});

app.post('/chaos/latency', requireChaosKey, requireBody, (req, res) => {
  const latencyMs = parseBoundedNumber(req.body.ms, 0, 30000);
  if (latencyMs === null) {
    return res.status(400).json({ error: 'ms must be a number between 0 and 30000' });
  }

  state.latencyMs = latencyMs;
  updateGauges();

  return res.status(200).json({ message: 'Latency injection updated', ms: state.latencyMs });
});

app.post('/chaos/dependency', requireChaosKey, requireBody, (req, res) => {
  const down = parseBoolean(req.body.down);
  if (down === null) {
    return res.status(400).json({ error: 'down must be true or false' });
  }

  state.dependencyDown = down;
  updateGauges();

  return res.status(200).json({ message: 'Dependency state updated', dependencyDown: state.dependencyDown });
});

app.post('/chaos/memory', requireChaosKey, requireBody, (req, res) => {
  const mb = parseBoundedNumber(req.body.mb, 1, 1024);
  if (mb === null) {
    return res.status(400).json({ error: 'mb must be a number between 1 and 1024' });
  }

  // Prevent cumulative allocations from exceeding the hard limit.
  if (state.retainedMemoryMb + mb > MEMORY_HARD_LIMIT_MB) {
    return res.status(400).json({
      error: `Allocation would exceed the ${MEMORY_HARD_LIMIT_MB} MB hard limit`,
      retainedMemoryMb: state.retainedMemoryMb,
      requestedMb: mb
    });
  }

  state.memoryChunks.push(Buffer.alloc(mb * 1024 * 1024, 0xff));
  state.retainedMemoryMb += mb;
  updateGauges();

  return res.status(200).json({
    message: 'Memory retained for chaos simulation',
    retainedMemoryMb: state.retainedMemoryMb
  });
});

app.post('/chaos/cpu', requireChaosKey, requireBody, async (req, res) => {
  const seconds = parseBoundedNumber(req.body.seconds, 1, 120);
  if (seconds === null) {
    return res.status(400).json({ error: 'seconds must be a number between 1 and 120' });
  }

  try {
    await burnCpu(seconds);
  } catch (err) {
    console.error('CPU burn worker error:', err);
    return res.status(500).json({ error: 'CPU burn failed internally' });
  }

  return res.status(200).json({ message: 'CPU burn completed', seconds });
});

app.post('/chaos/reset', requireChaosKey, (req, res) => {
  state.errorRatePercent = 0;
  state.latencyMs = 0;
  state.dependencyDown = false;
  state.retainedMemoryMb = 0;
  state.memoryChunks = [];
  updateGauges();
  chaosResetCounter.inc();

  if (global.gc) {
    global.gc();
  }

  return res.status(200).json({ message: 'Chaos state reset' });
});

// ---------------------------------------------------------------------------
// Metrics
// ---------------------------------------------------------------------------

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.listen(port, () => {
  console.log(`chaos-testing demo app listening on :${port}`);
  if (CHAOS_API_KEY) {
    console.log('Chaos control endpoints are protected by x-chaos-key authentication.');
  } else {
    console.log('Warning: CHAOS_API_KEY is not set. Chaos endpoints are unauthenticated.');
  }
});
