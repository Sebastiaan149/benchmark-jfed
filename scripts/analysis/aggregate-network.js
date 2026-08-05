#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const benchRoot = path.resolve(__dirname, '..', '..');
const resultsRoot = process.env.RESULTS_ROOT || path.join(benchRoot, 'watdiv-results');
const outputFile = path.join(resultsRoot, 'network-averages.csv');
const clientOutputFile = path.join(resultsRoot, 'network-clients.csv');

function walk(dir) {
  if (!fs.existsSync(dir)) {
    return [];
  }
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      return walk(full);
    }
    return entry.isFile() && entry.name === 'client-netns.csv' ? [ full ] : [];
  });
}

function summarize(file) {
  const runSummaryFile = path.join(path.dirname(file), 'summary.json');
  if (!fs.existsSync(runSummaryFile)) {
    throw new Error(`Missing run summary for network measurements: ${runSummaryFile}`);
  }
  const runSummaries = JSON.parse(fs.readFileSync(runSummaryFile, 'utf8'));
  const iterations = Array.isArray(runSummaries) ? runSummaries.length : 1;
  if (iterations < 1) {
    throw new Error(`No iterations found in ${runSummaryFile}`);
  }
  const rows = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/u).slice(1).filter(Boolean).map((line) => {
    const [ timestamp, client, rxBytes, txBytes, rxPackets, txPackets ] = line.split(';');
    return { timestamp: Date.parse(timestamp), client, rxBytes: Number(rxBytes), txBytes: Number(txBytes),
      rxPackets: Number(rxPackets), txPackets: Number(txPackets) };
  });
  const byClient = new Map();
  for (const row of rows) {
    const bucket = byClient.get(row.client) || [];
    bucket.push(row);
    byClient.set(row.client, bucket);
  }
  const clients = [];
  const totals = { iterations, clients: byClient.size, durationSeconds: 0, rxBytes: 0, txBytes: 0,
    rxPackets: 0, txPackets: 0 };
  for (const [ client, samples ] of byClient) {
    samples.sort((a, b) => a.timestamp - b.timestamp);
    const first = samples[0];
    const last = samples.at(-1);
    const value = {
      client,
      iterations,
      durationSeconds: (last.timestamp - first.timestamp) / 1_000 / iterations,
      rxBytes: Math.max(0, last.rxBytes - first.rxBytes) / iterations,
      txBytes: Math.max(0, last.txBytes - first.txBytes) / iterations,
      rxPackets: Math.max(0, last.rxPackets - first.rxPackets) / iterations,
      txPackets: Math.max(0, last.txPackets - first.txPackets) / iterations,
    };
    clients.push(value);
    totals.durationSeconds = Math.max(totals.durationSeconds, value.durationSeconds);
    totals.rxBytes += value.rxBytes;
    totals.txBytes += value.txBytes;
    totals.rxPackets += value.rxPackets;
    totals.txPackets += value.txPackets;
  }
  return { totals, clients };
}

const groups = new Map();
const clientRows = [];
for (const file of walk(resultsRoot)) {
  const rel = path.relative(resultsRoot, file).split(path.sep);
  if (rel.length < 5 || !rel[3].startsWith('c')) {
    continue;
  }
  const key = rel.slice(0, 4).join(';');
  const summary = summarize(file);
  const bucket = groups.get(key) || [];
  bucket.push(summary.totals);
  groups.set(key, bucket);
  const clientNode = rel.length >= 6 ? rel[4] : 'local';
  for (const client of summary.clients) {
    clientRows.push({ key, clientNode, ...client });
  }
}

const lines = [ 'size;framework;cacheMode;concurrency;iterations;clientNodes;clients;avgDurationSeconds;avgRxBytes;avgTxBytes;avgTotalBytes;avgRxPackets;avgTxPackets;avgTotalPackets;averageMbps' ];
for (const [ key, values ] of [ ...groups ].sort()) {
  const sum = field => values.reduce((total, value) => total + value[field], 0);
  const duration = Math.max(...values.map(value => value.durationSeconds));
  const iterations = Math.max(...values.map(value => value.iterations));
  const rxBytes = sum('rxBytes');
  const txBytes = sum('txBytes');
  const totalBytes = rxBytes + txBytes;
  lines.push([ key.replace(/;c(\d+)$/u, ';$1'), iterations, values.length, sum('clients'), duration.toFixed(3),
    rxBytes.toFixed(2), txBytes.toFixed(2), totalBytes.toFixed(2), sum('rxPackets').toFixed(2),
    sum('txPackets').toFixed(2), (sum('rxPackets') + sum('txPackets')).toFixed(2),
    duration > 0 ? (totalBytes * 8 / duration / 1_000_000).toFixed(3) : '0.000' ].join(';'));
}

fs.mkdirSync(resultsRoot, { recursive: true });
fs.writeFileSync(outputFile, `${lines.join('\n')}\n`);
console.log(`Wrote ${outputFile}`);

const clientLines = [ 'size;framework;cacheMode;concurrency;iterations;clientNode;client;avgDurationSeconds;avgRxBytes;avgTxBytes;avgTotalBytes;avgRxPackets;avgTxPackets;avgTotalPackets;averageMbps' ];
for (const row of clientRows.sort((left, right) =>
  left.key.localeCompare(right.key) || Number(left.client) - Number(right.client))) {
  const totalBytes = row.rxBytes + row.txBytes;
  clientLines.push([
    row.key.replace(/;c(\d+)$/u, ';$1'),
    row.iterations,
    row.clientNode,
    row.client,
    row.durationSeconds.toFixed(3),
    row.rxBytes.toFixed(2),
    row.txBytes.toFixed(2),
    totalBytes.toFixed(2),
    row.rxPackets.toFixed(2),
    row.txPackets.toFixed(2),
    (row.rxPackets + row.txPackets).toFixed(2),
    row.durationSeconds > 0 ? (totalBytes * 8 / row.durationSeconds / 1_000_000).toFixed(3) : '0.000',
  ].join(';'));
}
fs.writeFileSync(clientOutputFile, `${clientLines.join('\n')}\n`);
console.log(`Wrote ${clientOutputFile}`);
