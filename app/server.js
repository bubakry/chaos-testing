'use strict';

const express = require('express');
const client = require('prom-client');

const app = express();
app.use(express.json());

const port = Number(process.env.PORT || 8080);

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

function burnCpu(seconds) {
  const stopAt = Date.now() + seconds * 1000;
  let accumulator = 0;

  while (Date.now() < stopAt) {
    accumulator += Math.sqrt(Math.random() * Number.MAX_SAFE_INTEGER);
  }

  return accumulator;
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

app.get('/chaos/state', (req, res) => {
  return res.status(200).json({
    errorRatePercent: state.errorRatePercent,
    latencyMs: state.latencyMs,
    dependencyDown: state.dependencyDown,
    retainedMemoryMb: state.retainedMemoryMb
  });
});

app.post('/chaos/error-rate', (req, res) => {
  const percent = parseBoundedNumber(req.body.percent, 0, 100);
  if (percent === null) {
    return res.status(400).json({ error: 'percent must be a number between 0 and 100' });
  }

  state.errorRatePercent = percent;
  updateGauges();

  return res.status(200).json({ message: 'Error injection updated', percent: state.errorRatePercent });
});

app.post('/chaos/latency', (req, res) => {
  const latencyMs = parseBoundedNumber(req.body.ms, 0, 30000);
  if (latencyMs === null) {
    return res.status(400).json({ error: 'ms must be a number between 0 and 30000' });
  }

  state.latencyMs = latencyMs;
  updateGauges();

  return res.status(200).json({ message: 'Latency injection updated', ms: state.latencyMs });
});

app.post('/chaos/dependency', (req, res) => {
  const down = parseBoolean(req.body.down);
  if (down === null) {
    return res.status(400).json({ error: 'down must be true or false' });
  }

  state.dependencyDown = down;
  updateGauges();

  return res.status(200).json({ message: 'Dependency state updated', dependencyDown: state.dependencyDown });
});

app.post('/chaos/memory', (req, res) => {
  const mb = parseBoundedNumber(req.body.mb, 1, 1024);
  if (mb === null) {
    return res.status(400).json({ error: 'mb must be a number between 1 and 1024' });
  }

  state.memoryChunks.push(Buffer.alloc(mb * 1024 * 1024, 0xff));
  state.retainedMemoryMb += mb;
  updateGauges();

  return res.status(200).json({
    message: 'Memory retained for chaos simulation',
    retainedMemoryMb: state.retainedMemoryMb
  });
});

app.post('/chaos/cpu', (req, res) => {
  const seconds = parseBoundedNumber(req.body.seconds, 1, 120);
  if (seconds === null) {
    return res.status(400).json({ error: 'seconds must be a number between 1 and 120' });
  }

  burnCpu(seconds);

  return res.status(200).json({ message: 'CPU burn completed', seconds });
});

app.post('/chaos/reset', (req, res) => {
  state.errorRatePercent = 0;
  state.latencyMs = 0;
  state.dependencyDown = false;
  state.retainedMemoryMb = 0;
  state.memoryChunks = [];
  updateGauges();

  if (global.gc) {
    global.gc();
  }

  return res.status(200).json({ message: 'Chaos state reset' });
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

app.listen(port, () => {
  console.log(`chaos-testing demo app listening on :${port}`);
});
