#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const resultsRoot = path.resolve(process.argv[2] || '.');
const serverOutput = path.join(resultsRoot, 'server-resource-timeseries.csv');
const networkOutput = path.join(resultsRoot, 'network-timeseries.csv');

function walk(root, predicate) {
  if (!fs.existsSync(root)) {
    return [];
  }
  return fs.readdirSync(root, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(root, entry.name);
    return entry.isDirectory() ? walk(full, predicate) : predicate(full) ? [ full ] : [];
  });
}

function parseCsv(file) {
  const lines = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/u).filter(Boolean);
  if (lines.length < 2) {
    return [];
  }
  const headers = lines[0].split(';');
  return lines.slice(1).map(line => Object.fromEntries(
    line.split(';').slice(0, headers.length).map((value, index) => [ headers[index], value ]),
  ));
}

function stageFor(framework, cacheMode) {
  if (framework.endsWith('-cache') && cacheMode === 'server-warm') {
    return { frameworkFamily: framework.slice(0, -6), stageOrder: 3, condition: 'nginx-warm' };
  }
  if (framework.endsWith('-cache') && cacheMode === 'cold') {
    return { frameworkFamily: framework.slice(0, -6), stageOrder: 2, condition: 'nginx-cold-building' };
  }
  if (!framework.endsWith('-cache') && cacheMode === 'cold') {
    return { frameworkFamily: framework, stageOrder: 1, condition: 'no-nginx' };
  }
  return undefined;
}

function csvNumber(value, digits = 3) {
  return Number.isFinite(value) ? value.toFixed(digits) : '';
}

function addTimeline(rows, groupFields) {
  const groups = new Map();
  for (const row of rows) {
    const key = groupFields.map(field => row[field]).join(';');
    const bucket = groups.get(key) || [];
    bucket.push(row);
    groups.set(key, bucket);
  }
  for (const values of groups.values()) {
    const stages = new Map();
    for (const row of values) {
      const bucket = stages.get(row.stageOrder) || [];
      bucket.push(row);
      stages.set(row.stageOrder, bucket);
    }
    let offset = 0;
    for (const stageOrder of [ 1, 2, 3 ]) {
      const stageRows = stages.get(stageOrder) || [];
      stageRows.sort((left, right) => left.stageElapsedSeconds - right.stageElapsedSeconds);
      for (const row of stageRows) {
        row.timelineSeconds = offset + row.stageElapsedSeconds;
      }
      if (stageRows.length > 0) {
        offset += Math.max(...stageRows.map(row => row.stageElapsedSeconds)) + 1;
      }
    }
  }
}

function aggregateServerResources() {
  const metricsRoot = path.join(resultsRoot, 'server-metrics');
  const files = walk(metricsRoot, file => path.basename(file) === 'server-resources.csv');
  const outputRows = [];
  for (const file of files) {
    const rel = path.relative(metricsRoot, file).split(path.sep);
    const concurrencyIndex = rel.findIndex(part => /^c\d+$/u.test(part));
    if (concurrencyIndex < 4) {
      continue;
    }
    const [ runId, size, framework, cacheMode ] = rel.slice(concurrencyIndex - 4, concurrencyIndex);
    const stage = stageFor(framework, cacheMode);
    if (!stage) {
      continue;
    }
    const samples = parseCsv(file).map(row => ({
      timestamp: row.timestamp,
      timestampMs: Date.parse(row.timestamp.replace(',', '.')),
      pid: Number(row.pid),
      processCount: Number(row.processCount),
      cpuPercent: Number(row.cpuPercent),
      rssMb: Number(row.rssMb),
    })).filter(row => Number.isFinite(row.timestampMs)).sort((left, right) => left.timestampMs - right.timestampMs);
    if (samples.length === 0) {
      continue;
    }
    const started = samples[0].timestampMs;
    for (let index = 0; index < samples.length; index++) {
      outputRows.push({
        runId,
        size,
        ...stage,
        framework,
        cacheMode,
        concurrency: Number(rel[concurrencyIndex].slice(1)),
        sampleIndex: index,
        stageElapsedSeconds: (samples[index].timestampMs - started) / 1_000,
        ...samples[index],
      });
    }
  }
  addTimeline(outputRows, [ 'runId', 'size', 'frameworkFamily', 'concurrency' ]);
  outputRows.sort((left, right) =>
    left.runId.localeCompare(right.runId) || left.size.localeCompare(right.size) ||
    left.frameworkFamily.localeCompare(right.frameworkFamily) || left.concurrency - right.concurrency ||
    left.stageOrder - right.stageOrder || left.stageElapsedSeconds - right.stageElapsedSeconds);
  const lines = [
    'runId;size;frameworkFamily;framework;serverCacheCondition;cacheMode;concurrency;stageOrder;sampleIndex;timestamp;stageElapsedSeconds;timelineSeconds;pid;processCount;cpuPercent;rssMb',
    ...outputRows.map(row => [
      row.runId, row.size, row.frameworkFamily, row.framework, row.condition, row.cacheMode,
      row.concurrency, row.stageOrder, row.sampleIndex, row.timestamp,
      csvNumber(row.stageElapsedSeconds), csvNumber(row.timelineSeconds), row.pid,
      row.processCount, csvNumber(row.cpuPercent, 2), csvNumber(row.rssMb, 2),
    ].join(';')),
  ];
  fs.writeFileSync(serverOutput, `${lines.join('\n')}\n`);
  console.log(`Wrote ${serverOutput} (${outputRows.length} samples)`);
}

function aggregateNetwork() {
  const files = walk(resultsRoot, file => path.basename(file) === 'client-netns.csv');
  const intervals = [];
  for (const file of files) {
    const rel = path.relative(resultsRoot, file).split(path.sep);
    const concurrencyIndex = rel.findIndex(part => /^c\d+$/u.test(part));
    if (concurrencyIndex < 3) {
      continue;
    }
    const [ size, framework, cacheMode ] = rel.slice(concurrencyIndex - 3, concurrencyIndex);
    const stage = stageFor(framework, cacheMode);
    const summaryFile = path.join(path.dirname(file), 'summary.json');
    if (!stage || !fs.existsSync(summaryFile)) {
      continue;
    }
    const byClient = new Map();
    for (const row of parseCsv(file)) {
      const sample = {
        timestamp: row.timestamp,
        timestampMs: Date.parse(row.timestamp.replace(',', '.')),
        rxBytes: Number(row.rxBytes),
        txBytes: Number(row.txBytes),
        rxPackets: Number(row.rxPackets),
        txPackets: Number(row.txPackets),
      };
      if (!Number.isFinite(sample.timestampMs)) {
        continue;
      }
      const bucket = byClient.get(row.client) || [];
      bucket.push(sample);
      byClient.set(row.client, bucket);
    }
    for (const samples of byClient.values()) {
      samples.sort((left, right) => left.timestampMs - right.timestampMs);
      for (let index = 1; index < samples.length; index++) {
        const previous = samples[index - 1];
        const current = samples[index];
        const durationSeconds = (current.timestampMs - previous.timestampMs) / 1_000;
        if (durationSeconds <= 0) {
          continue;
        }
        intervals.push({
          size,
          ...stage,
          framework,
          cacheMode,
          concurrency: Number(rel[concurrencyIndex].slice(1)),
          timestamp: current.timestamp,
          timestampMs: current.timestampMs,
          durationSeconds,
          rxBytes: Math.max(0, current.rxBytes - previous.rxBytes),
          txBytes: Math.max(0, current.txBytes - previous.txBytes),
          rxPackets: Math.max(0, current.rxPackets - previous.rxPackets),
          txPackets: Math.max(0, current.txPackets - previous.txPackets),
        });
      }
    }
  }

  const stageStarts = new Map();
  for (const row of intervals) {
    const key = [ row.size, row.framework, row.cacheMode, row.concurrency ].join(';');
    stageStarts.set(key, Math.min(stageStarts.get(key) ?? row.timestampMs, row.timestampMs));
  }
  const buckets = new Map();
  for (const row of intervals) {
    const stageKey = [ row.size, row.framework, row.cacheMode, row.concurrency ].join(';');
    const elapsedSecond = Math.max(0, Math.round((row.timestampMs - stageStarts.get(stageKey)) / 1_000));
    const key = `${stageKey};${elapsedSecond}`;
    const bucket = buckets.get(key) || { ...row, stageElapsedSeconds: elapsedSecond,
      rxBytes: 0, txBytes: 0, rxPackets: 0, txPackets: 0, rxMbps: 0, txMbps: 0 };
    bucket.rxBytes += row.rxBytes;
    bucket.txBytes += row.txBytes;
    bucket.rxPackets += row.rxPackets;
    bucket.txPackets += row.txPackets;
    bucket.rxMbps += row.rxBytes * 8 / row.durationSeconds / 1_000_000;
    bucket.txMbps += row.txBytes * 8 / row.durationSeconds / 1_000_000;
    buckets.set(key, bucket);
  }
  const outputRows = [ ...buckets.values() ];
  addTimeline(outputRows, [ 'size', 'frameworkFamily', 'concurrency' ]);
  const groups = new Map();
  for (const row of outputRows) {
    const key = [ row.size, row.frameworkFamily, row.concurrency ].join(';');
    const bucket = groups.get(key) || [];
    bucket.push(row);
    groups.set(key, bucket);
  }
  for (const values of groups.values()) {
    values.sort((left, right) => left.stageOrder - right.stageOrder || left.stageElapsedSeconds - right.stageElapsedSeconds);
    let timelineBytes = 0;
    let timelinePackets = 0;
    let currentStage;
    let stageBytes = 0;
    let stagePackets = 0;
    for (const row of values) {
      if (currentStage !== row.stageOrder) {
        currentStage = row.stageOrder;
        stageBytes = 0;
        stagePackets = 0;
      }
      const totalBytes = row.rxBytes + row.txBytes;
      const totalPackets = row.rxPackets + row.txPackets;
      stageBytes += totalBytes;
      stagePackets += totalPackets;
      timelineBytes += totalBytes;
      timelinePackets += totalPackets;
      row.stageCumulativeTotalBytes = stageBytes;
      row.stageCumulativeTotalPackets = stagePackets;
      row.timelineCumulativeTotalBytes = timelineBytes;
      row.timelineCumulativeTotalPackets = timelinePackets;
    }
  }
  outputRows.sort((left, right) =>
    left.size.localeCompare(right.size) || left.frameworkFamily.localeCompare(right.frameworkFamily) ||
    left.concurrency - right.concurrency || left.stageOrder - right.stageOrder ||
    left.stageElapsedSeconds - right.stageElapsedSeconds);
  const lines = [
    'size;frameworkFamily;framework;serverCacheCondition;cacheMode;concurrency;stageOrder;timestamp;stageElapsedSeconds;timelineSeconds;rxBytes;txBytes;totalBytes;rxPackets;txPackets;totalPackets;rxMbps;txMbps;totalMbps;stageCumulativeTotalBytes;stageCumulativeTotalPackets;timelineCumulativeTotalBytes;timelineCumulativeTotalPackets',
    ...outputRows.map(row => [
      row.size, row.frameworkFamily, row.framework, row.condition, row.cacheMode, row.concurrency,
      row.stageOrder, row.timestamp, csvNumber(row.stageElapsedSeconds), csvNumber(row.timelineSeconds),
      row.rxBytes, row.txBytes, row.rxBytes + row.txBytes, row.rxPackets, row.txPackets,
      row.rxPackets + row.txPackets, csvNumber(row.rxMbps), csvNumber(row.txMbps),
      csvNumber(row.rxMbps + row.txMbps), row.stageCumulativeTotalBytes,
      row.stageCumulativeTotalPackets, row.timelineCumulativeTotalBytes,
      row.timelineCumulativeTotalPackets,
    ].join(';')),
  ];
  fs.writeFileSync(networkOutput, `${lines.join('\n')}\n`);
  console.log(`Wrote ${networkOutput} (${outputRows.length} samples)`);
}

fs.mkdirSync(resultsRoot, { recursive: true });
aggregateServerResources();
aggregateNetwork();
