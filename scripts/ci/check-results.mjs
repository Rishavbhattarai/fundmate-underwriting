#!/usr/bin/env node
// Fails the build when any Apex test fails or coverage of the run is below the threshold.
// Usage: node scripts/ci/check-results.mjs <sf apex run test --json output> [minCoverage]
import { readFileSync } from 'node:fs';

const [file, minArg] = process.argv.slice(2);
const min = Number(minArg || 85);
const raw = JSON.parse(readFileSync(file, 'utf8'));
const result = raw.result || raw;
const summary = result.summary || {};
const failures = (result.tests || []).filter((t) => t.Outcome !== 'Pass');
const coverage = parseFloat(String(summary.testRunCoverage || summary.orgWideCoverage || '0').replace('%', ''));

console.log(`Tests: ${summary.passing} passed, ${summary.failing} failed. Coverage: ${coverage}% (minimum ${min}%).`);
for (const t of failures) {
  console.log(`FAIL ${t.FullName}: ${t.Message}`);
}
if (failures.length || !(coverage >= min)) {
  process.exit(1);
}
