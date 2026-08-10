#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      const next = argv[i + 1];
      if (!next || next.startsWith('--')) {
        args[key] = true;
      } else {
        args[key] = next;
        i++;
      }
    }
  }
  return args;
}

function readServerResourceSummary(file) {
  if (!file || !fs.existsSync(file)) {
    return {};
  }
  const lines = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/u).slice(1).filter(Boolean);
  const rows = lines.map((line) => {
    const [ timestamp, pid, processCount, cpuPercent, rssMb ] = line.split(';');
    return {
      timestamp,
      pid: Number(pid),
      processCount: Number(processCount),
      cpuPercent: Number(cpuPercent),
      rssMb: Number(rssMb),
    };
  }).filter(row => row.processCount > 0);
  if (rows.length === 0) {
    return {};
  }
  return {
    serverResourceSampleCount: rows.length,
    serverAvgCpuPercent: rows.reduce((sum, row) => sum + row.cpuPercent, 0) / rows.length,
    serverMaxCpuPercent: Math.max(...rows.map(row => row.cpuPercent)),
    serverAvgRssMb: rows.reduce((sum, row) => sum + row.rssMb, 0) / rows.length,
    serverMaxRssMb: Math.max(...rows.map(row => row.rssMb)),
  };
}

function mergeObjectFile(file, extra) {
  if (!fs.existsSync(file)) {
    return;
  }
  const value = JSON.parse(fs.readFileSync(file, 'utf8'));
  fs.writeFileSync(file, `${JSON.stringify({ ...value, ...extra }, null, 2)}\n`);
}

function mergeArrayFile(file, extra) {
  if (!fs.existsSync(file)) {
    return;
  }
  const values = JSON.parse(fs.readFileSync(file, 'utf8'));
  fs.writeFileSync(file, `${JSON.stringify(values.map(value => ({ ...value, ...extra })), null, 2)}\n`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const runRoot = args['run-root'];
  const serverResourceFile = args['server-resource-file'];
  if (!runRoot || !serverResourceFile) {
    throw new Error('Usage: merge-server-resource-summary.js --run-root <watdiv-results/.../cN> --server-resource-file <csv>');
  }

  const summary = {
    ...readServerResourceSummary(serverResourceFile),
    serverDowntimeCount: Number(args['server-downtime-count'] || 0),
    serverRecoveryWarning: args['server-recovery-warning'] || '',
  };
  mergeArrayFile(path.join(runRoot, 'summary.json'), summary);
  for (const entry of fs.readdirSync(runRoot, { withFileTypes: true })) {
    if (entry.isDirectory() && entry.name.startsWith('iteration-')) {
      mergeObjectFile(path.join(runRoot, entry.name, 'summary.json'), summary);
    }
  }
}

main();
