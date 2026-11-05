#!/usr/bin/env node
/**
 * Plays the Underwriting API: signs a decisions payload and POSTs it to the
 * Salesforce endpoint.
 *
 *   node scripts/send-decisions.mjs <payload.json> [--org <alias>] [--tamper] [--stale] [--no-signature]
 *   node scripts/send-decisions.mjs --generate 200 --from-org [--org <alias>]   # 200 decisions for Acknowledged apps
 *
 * Signature: hex(HMAC-SHA256(SIGNING_SECRET, timestamp + "." + body)) in X-Signature,
 * with the Unix timestamp in X-Timestamp. SIGNING_SECRET is read from .env.local.
 *
 * Auth, in order:
 *  1. PARTNER_CLIENT_ID + PARTNER_CLIENT_SECRET (.env.local): OAuth client credentials, so the call runs
 *     as the integration user, exactly like the real Underwriting API. The endpoint only accepts that user.
 *  2. SF_INSTANCE_URL + SF_ACCESS_TOKEN.
 *  3. --as-cli: the Salesforce CLI session for --org (refused with 403 unless that user holds
 *     FundMate_Post_Underwriting_Decisions). Useful to show the 403.
 */
import { createHmac } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const flag = (name) => args.includes(`--${name}`);
const option = (name, fallback) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith('--') ? args[i + 1] : fallback;
};

function env() {
  const file = resolve(root, '.env.local');
  const values = {};
  if (existsSync(file)) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^\s*([A-Z_]+)\s*=\s*(.*)\s*$/);
      if (m) values[m[1]] = m[2];
    }
  }
  return { ...values, ...process.env };
}

const orgArgs = (org) => (org ? ['--target-org', org] : []);

function sfJson(cmd) {
  const out = execFileSync('sf', [...cmd, '--json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  return JSON.parse(out).result;
}

async function connection(org) {
  const e = env();
  const cli = () => {
    const r = sfJson(['org', 'display', ...orgArgs(org)]);
    return { instanceUrl: r.instanceUrl, accessToken: r.accessToken, as: 'CLI session user' };
  };
  if (flag('as-cli')) return cli();
  if (e.PARTNER_CLIENT_ID && e.PARTNER_CLIENT_SECRET) {
    const instanceUrl = e.SF_INSTANCE_URL || sfJson(['org', 'display', ...orgArgs(org)]).instanceUrl;
    const res = await fetch(`${instanceUrl}/services/oauth2/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'client_credentials', client_id: e.PARTNER_CLIENT_ID, client_secret: e.PARTNER_CLIENT_SECRET })
    });
    const json = await res.json();
    if (!json.access_token) throw new Error(`Client-credentials token failed: ${json.error || res.status} ${json.error_description || ''}`);
    return { instanceUrl: json.instance_url, accessToken: json.access_token, as: 'integration user (client credentials)' };
  }
  if (e.SF_INSTANCE_URL && e.SF_ACCESS_TOKEN) {
    return { instanceUrl: e.SF_INSTANCE_URL, accessToken: e.SF_ACCESS_TOKEN, as: 'SF_ACCESS_TOKEN' };
  }
  return cli();
}

/** Builds n decisions for applications that are Acknowledged in the org. */
function generate(org, n) {
  const q = `SELECT Name, Tracking_Id__c, Requested_Amount__c FROM Funding_Application__c WHERE Status__c = 'Acknowledged' AND Tracking_Id__c != null ORDER BY Name LIMIT ${n}`;
  const rows = sfJson(['data', 'query', ...orgArgs(org), '--query', q]).records;
  const stamp = Date.now();
  const choices = ['Approved', 'Approved', 'Approved', 'Declined', 'Needs More Info'];
  return {
    decisions: rows.map((r, i) => {
      const decision = choices[i % choices.length];
      const base = {
        decisionId: `DEC-${stamp}-${i}`,
        trackingId: r.Tracking_Id__c,
        applicationReference: r.Name,
        decision,
        decisionReason:
          decision === 'Approved' ? 'Meets guidelines.' : decision === 'Declined' ? 'Cash flow below guidelines.' : 'Need the most recent bank statement.'
      };
      if (decision !== 'Approved') return { ...base, offers: [] };
      const amount = Math.round((r.Requested_Amount__c || 50000) / 1000) * 1000;
      return {
        ...base,
        offers: [
          { offerId: `OFR-${stamp}-${i}-A`, fundingAmount: amount, factorRate: 1.32, termMonths: 12, paymentFrequency: 'Weekly' },
          { offerId: `OFR-${stamp}-${i}-B`, fundingAmount: Math.round(amount * 0.8), factorRate: 1.24, termMonths: 9, paymentFrequency: 'Daily' }
        ]
      };
    })
  };
}

async function main() {
  const org = option('org', ''); // empty: the Salesforce CLI default org
  const e = env();
  if (!e.SIGNING_SECRET) throw new Error('SIGNING_SECRET is missing. Add it to .env.local.');

  let payload;
  if (flag('generate')) {
    payload = generate(org, Number(option('generate', '200')));
    if (!payload.decisions.length) throw new Error('No Acknowledged applications with a tracking id were found.');
  } else {
    const file = args.find((a) => !a.startsWith('--') && a.endsWith('.json'));
    if (!file) throw new Error('Pass a payload file or --generate <n>.');
    payload = JSON.parse(readFileSync(resolve(file), 'utf8'));
  }

  const body = JSON.stringify(payload);
  const timestamp = String(Math.floor(Date.now() / 1000) - (flag('stale') ? 3600 : 0));
  let signature = createHmac('sha256', e.SIGNING_SECRET).update(`${timestamp}.${body}`).digest('hex');
  if (flag('tamper')) signature = signature.replace(/.$/, (c) => (c === '0' ? '1' : '0'));

  const { instanceUrl, accessToken, as } = await connection(org);
  const headers = { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' };
  if (!flag('no-signature')) {
    headers['X-Timestamp'] = timestamp;
    headers['X-Signature'] = signature;
  }

  const started = Date.now();
  const res = await fetch(`${instanceUrl}/services/apexrest/underwriting/decisions`, { method: 'POST', headers, body });
  const text = await res.text();
  console.log(`HTTP ${res.status} in ${Date.now() - started} ms, ${payload.decisions.length} decisions sent as ${as}`);
  try {
    const json = JSON.parse(text);
    if (Array.isArray(json.results) && json.results.length > 10 && !flag('verbose')) {
      console.log(JSON.stringify({ ...json, results: `${json.results.length} results (use --verbose to print)` }, null, 2));
    } else {
      console.log(JSON.stringify(json, null, 2));
    }
  } catch {
    console.log(text);
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exit(1);
});
