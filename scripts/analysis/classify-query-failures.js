#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function argument(name, fallback = '') {
  const index = process.argv.indexOf(`--${name}`);
  return index < 0 ? fallback : process.argv[index + 1];
}

function walk(dir, filename) {
  if (!fs.existsSync(dir)) {
    return [];
  }
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...walk(full, filename));
    } else if (entry.isFile() && entry.name === filename) {
      files.push(full);
    }
  }
  return files;
}

function clean(value) {
  return String(value ?? '').replaceAll(';', ',').replaceAll(/\r?\n/g, ' ').trim();
}

function stderrExcerpt(csvFile, stderrFile) {
  if (!stderrFile) {
    return '';
  }
  const file = path.resolve(path.dirname(csvFile), stderrFile);
  if (!fs.existsSync(file)) {
    return `stderr file missing: ${stderrFile}`;
  }
  return clean(fs.readFileSync(file, 'utf8')).slice(0, 500);
}

const runRoot = path.resolve(argument('run-root'));
const detailLog = path.resolve(argument('detail-log'));
const maxMinorFailures = Number(argument('max-minor-failures', '5'));
const maxMinorFailurePercent = Number(argument('max-minor-failure-percent', '10'));
const metadata = {
  timestamp: new Date().toISOString(),
  runId: argument('run-id'),
  size: argument('size'),
  framework: argument('framework'),
  cacheMode: argument('cache'),
  concurrency: argument('concurrency'),
  serverLog: argument('server-log'),
};

const csvFiles = walk(runRoot, 'query-times.csv');
if (csvFiles.length === 0) {
  console.error(`No query-times.csv files found under ${runRoot}.`);
  process.exit(20);
}

const rows = [];
for (const csvFile of csvFiles) {
  const lines = fs.readFileSync(csvFile, 'utf8').trim().split(/\r?\n/);
  const headers = lines.shift().split(';');
  for (const line of lines) {
    if (!line) {
      continue;
    }
    const values = line.split(';');
    const row = Object.fromEntries(headers.map((header, index) => [ header, values[index] ?? '' ]));
    row.csvFile = path.relative(path.dirname(detailLog), csvFile);
    rows.push(row);
  }
}

const failures = rows.filter(row => row.status !== '0' || row.timedOut === 'true');
if (failures.length === 0) {
  process.exit(0);
}

fs.mkdirSync(path.dirname(detailLog), { recursive: true });
if (!fs.existsSync(detailLog)) {
  fs.writeFileSync(detailLog, [
    'timestamp', 'runId', 'size', 'framework', 'cacheMode', 'concurrency', 'classification',
    'client', 'queryIndex', 'query', 'queryInstance', 'status', 'signal', 'timedOut', 'results',
    'timeMs', 'queryTimesFile', 'stderrFile', 'errorExcerpt', 'serverLog',
  ].join(';') + '\n');
}

const timeoutFailures = failures.filter(row => row.timedOut === 'true').length;
const nonTimeoutFailures = failures.length - timeoutFailures;
const allFailed = failures.length === rows.length;
const nonTimeoutFailurePercent = rows.length === 0 ? 100 : nonTimeoutFailures * 100 / rows.length;
const recoverable = nonTimeoutFailures === 0 || (!allFailed && nonTimeoutFailures <= maxMinorFailures &&
  nonTimeoutFailurePercent <= maxMinorFailurePercent);
const classification = recoverable ? 'recoverable-query-failure' : 'fatal-processing-failure';

for (const row of failures) {
  fs.appendFileSync(detailLog, [
    metadata.timestamp, metadata.runId, metadata.size, metadata.framework, metadata.cacheMode,
    metadata.concurrency, classification, row.client, row.queryIndex, row.query, row.queryInstance,
    row.status, row.signal, row.timedOut, row.results, row.timeMs, row.csvFile, row.stderrFile,
    stderrExcerpt(path.resolve(path.dirname(detailLog), row.csvFile), row.stderrFile), metadata.serverLog,
  ].map(clean).join(';') + '\n');
}

console.error(`${classification}: ${failures.length}/${rows.length} queries failed ` +
  `(${timeoutFailures} timeout, ${nonTimeoutFailures} other).`);
process.exit(recoverable ? 10 : 20);
