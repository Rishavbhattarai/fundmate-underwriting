/**
 * Mock FundMate Underwriting API (Cloudflare Worker).
 *
 * POST /v1/applications/batch
 *   Header X-Api-Key must match the API_KEY secret, otherwise 401.
 *   Body { "applications": [ ... up to 50 ... ] }
 *   Returns { batchId, results: [ { applicationReference, status, statusReason, trackingId? } ] }
 *
 * Failure simulation is driven by the data, so it is repeatable in a demo:
 *   business.legalName contains "RATE LIMIT"   -> 429 with Retry-After: 60
 *   business.legalName contains "SERVER ERROR" -> 503 with Retry-After: 30
 *   business.legalName contains "TIMEOUT"      -> waits 25 s (longer than the Salesforce timeout)
 *   business.legalName contains "BAD REQUEST"  -> 400
 *
 * Per-application outcome:
 *   no owners, or an owner without SSN/date of birth -> Rejected "Identity not verified."
 *   averageMonthlyDeposits below 10,000              -> Rejected "Average monthly deposits below 10,000."
 *   otherwise                                        -> Acknowledged with a trackingId
 */
const MAX_APPLICATIONS = 50;

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/health') {
      return json({ ok: true, service: 'fundmate-underwriting-mock' });
    }
    if (url.pathname !== '/v1/applications/batch') {
      return json({ error: 'not_found' }, 404);
    }
    if (request.method !== 'POST') {
      return json({ error: 'method_not_allowed' }, 405);
    }
    if (!env.API_KEY || request.headers.get('X-Api-Key') !== env.API_KEY) {
      return json({ error: 'unauthorized', message: 'Missing or invalid X-Api-Key.' }, 401);
    }

    let body;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'invalid_json' }, 400);
    }
    const apps = Array.isArray(body?.applications) ? body.applications : null;
    if (!apps || apps.length === 0) {
      return json({ error: 'validation_error', message: '"applications" must be a non-empty array.' }, 400);
    }
    if (apps.length > MAX_APPLICATIONS) {
      return json({ error: 'validation_error', message: `At most ${MAX_APPLICATIONS} applications per request.` }, 400);
    }

    const names = apps.map((a) => String(a?.business?.legalName || '').toUpperCase());
    if (names.some((n) => n.includes('RATE LIMIT'))) {
      return json({ error: 'rate_limited', message: 'Too many requests.' }, 429, { 'Retry-After': '60' });
    }
    if (names.some((n) => n.includes('SERVER ERROR'))) {
      return json({ error: 'unavailable', message: 'Underwriting is temporarily unavailable.' }, 503, { 'Retry-After': '30' });
    }
    if (names.some((n) => n.includes('BAD REQUEST'))) {
      return json({ error: 'validation_error', message: 'Simulated validation failure.' }, 400);
    }
    if (names.some((n) => n.includes('TIMEOUT'))) {
      await new Promise((r) => setTimeout(r, 25000));
    }

    const results = [];
    for (const app of apps) {
      results.push(await evaluate(app));
    }
    return json({ batchId: batchId(request.headers.get('Idempotency-Key')), results });
  }
};

async function evaluate(app) {
  const reference = app?.applicationReference;
  if (!reference) {
    return { applicationReference: null, status: 'Rejected', statusReason: 'applicationReference is required.' };
  }
  const owners = Array.isArray(app.owners) ? app.owners : [];
  if (owners.length === 0 || owners.some((o) => !o?.ssn || !o?.dateOfBirth)) {
    return { applicationReference: reference, status: 'Rejected', statusReason: 'Identity not verified.' };
  }
  const deposits = Number(app?.financials?.averageMonthlyDeposits || 0);
  if (deposits < 10000) {
    return { applicationReference: reference, status: 'Rejected', statusReason: 'Average monthly deposits below 10,000.' };
  }
  return {
    applicationReference: reference,
    status: 'Acknowledged',
    statusReason: 'Queued for review.',
    trackingId: `UW-${(await hash(reference)).slice(0, 8).toUpperCase()}`
  };
}

function batchId(idempotencyKey) {
  const d = new Date().toISOString().slice(0, 10).replaceAll('-', '');
  const suffix = (idempotencyKey || crypto.randomUUID()).replace(/[^a-z0-9]/gi, '').slice(0, 6);
  return `b-${d}-${suffix}`;
}

async function hash(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function json(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', ...headers } });
}
