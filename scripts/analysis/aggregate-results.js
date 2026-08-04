#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const benchRoot = path.resolve(__dirname, '..', '..');
const resultsRoot = process.env.RESULTS_ROOT || path.join(benchRoot, 'watdiv-results');
const outputFile = path.join(resultsRoot, 'averages.csv');

function walk(dir) {
  if (!fs.existsSync(dir)) {
    return [];
  }
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      out.push(...walk(full));
    } else if (entry.isFile() && entry.name === 'summary.json' &&
      path.basename(path.dirname(full)).startsWith('iteration-')) {
      out.push(full);
    }
  }
  return out;
}

function weightedAverage(values, valueField, weightField) {
  const weight = values.reduce((sum, value) => sum + Number(value[weightField] || 0), 0);
  return weight === 0 ? 0 : values.reduce((sum, value) =>
    sum + Number(value[valueField] || 0) * Number(value[weightField] || 0), 0) / weight;
}

const nodeSummaries = walk(resultsRoot).map(file => JSON.parse(fs.readFileSync(file, 'utf8')));
const iterations = new Map();
for (const summary of nodeSummaries) {
  const key = [ summary.size, summary.framework, summary.cacheMode, summary.concurrency, summary.iteration ].join(';');
  const bucket = iterations.get(key) || [];
  bucket.push(summary);
  iterations.set(key, bucket);
}

const mergedIterations = [];
for (const values of iterations.values()) {
  const first = values[0];
  mergedIterations.push({
    size: first.size,
    framework: first.framework,
    cacheMode: first.cacheMode,
    concurrency: first.concurrency,
    iteration: first.iteration,
    clientNodeCount: values.length,
    wallTimeMs: Math.max(...values.map(value => Number(value.wallTimeMs || 0))),
    queryInvocations: values.reduce((sum, value) => sum + Number(value.queryInvocations || 0), 0),
    failures: values.reduce((sum, value) => sum + Number(value.failures || 0), 0),
    totalResults: values.reduce((sum, value) => sum + Number(value.totalResults || 0), 0),
    averageTimeMs: weightedAverage(values, 'averageTimeMs', 'queryInvocations'),
    averageFirstResultTimeMs: weightedAverage(values, 'averageFirstResultTimeMs', 'queryInvocations'),
    resultThroughputPerSec: values.reduce((sum, value) => sum + Number(value.resultThroughputPerSec || 0), 0),
    clientAvgCpuPercent: weightedAverage(values, 'clientAvgCpuPercent', 'localConcurrency'),
    clientMaxCpuPercent: Math.max(...values.map(value => Number(value.clientMaxCpuPercent || 0))),
    clientAvgRssMb: weightedAverage(values, 'clientAvgRssMb', 'localConcurrency'),
    clientMaxRssMb: Math.max(...values.map(value => Number(value.clientMaxRssMb || 0))),
    serverAvgCpuPercent: values.reduce((sum, value) => sum + Number(value.serverAvgCpuPercent || 0), 0) / values.length,
    serverMaxCpuPercent: Math.max(...values.map(value => Number(value.serverMaxCpuPercent || 0))),
    serverAvgRssMb: values.reduce((sum, value) => sum + Number(value.serverAvgRssMb || 0), 0) / values.length,
    serverMaxRssMb: Math.max(...values.map(value => Number(value.serverMaxRssMb || 0))),
  });
}

const groups = new Map();
for (const summary of mergedIterations) {
  const key = [ summary.size, summary.framework, summary.cacheMode, summary.concurrency ].join(';');
  const bucket = groups.get(key) || [];
  bucket.push(summary);
  groups.set(key, bucket);
}

const columns = [
  'size', 'framework', 'cacheMode', 'concurrency', 'iterations', 'clientNodeCount',
  'avgWallTimeMs', 'avgQueryTimeMs', 'avgFirstResultTimeMs', 'avgResultThroughputPerSec',
  'avgFailures', 'avgTotalResults', 'clientAvgCpuPercent', 'clientMaxCpuPercent',
  'clientAvgRssMb', 'clientMaxRssMb', 'serverAvgCpuPercent', 'serverMaxCpuPercent',
  'serverAvgRssMb', 'serverMaxRssMb',
];
const lines = [ columns.join(';') ];
for (const [ key, values ] of [ ...groups ].sort()) {
  const avg = field => values.reduce((sum, value) => sum + Number(value[field] || 0), 0) / values.length;
  const max = field => Math.max(...values.map(value => Number(value[field] || 0)));
  lines.push([
    key,
    values.length,
    max('clientNodeCount'),
    Math.round(avg('wallTimeMs')),
    Math.round(avg('averageTimeMs')),
    Math.round(avg('averageFirstResultTimeMs')),
    avg('resultThroughputPerSec').toFixed(2),
    avg('failures').toFixed(2),
    avg('totalResults').toFixed(2),
    avg('clientAvgCpuPercent').toFixed(2),
    max('clientMaxCpuPercent').toFixed(2),
    avg('clientAvgRssMb').toFixed(2),
    max('clientMaxRssMb').toFixed(2),
    avg('serverAvgCpuPercent').toFixed(2),
    max('serverMaxCpuPercent').toFixed(2),
    avg('serverAvgRssMb').toFixed(2),
    max('serverMaxRssMb').toFixed(2),
  ].join(';'));
}

fs.mkdirSync(resultsRoot, { recursive: true });
fs.writeFileSync(outputFile, `${lines.join('\n')}\n`);
console.log(`Wrote ${outputFile}`);
