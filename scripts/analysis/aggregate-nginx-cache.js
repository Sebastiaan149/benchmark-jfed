#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');

const root = path.resolve(process.argv[2] || '.');
const output = path.join(root, 'nginx-cache-stats.csv');

function walk(dir) {
  if (!fs.existsSync(dir)) {
    return [];
  }
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(full) :
      entry.isFile() && entry.name.includes('-cache-') && entry.name.endsWith('-access.log') ? [ full ] : [];
  });
}

const groups = new Map();
for (const file of walk(root)) {
  const parts = path.relative(root, file).split(path.sep);
  const concurrencyIndex = parts.findIndex(part => /^c\d+$/u.test(part));
  if (concurrencyIndex < 3) {
    continue;
  }
  const key = parts.slice(concurrencyIndex - 3, concurrencyIndex + 1).join(';');
  const counts = groups.get(key) || new Map();
  for (const line of fs.readFileSync(file, 'utf8').split(/\r?\n/u).filter(Boolean)) {
    const status = /\s(HIT|MISS|BYPASS|EXPIRED|STALE|UPDATING|REVALIDATED|-)$/u.exec(line)?.[1] || 'UNKNOWN';
    counts.set(status, (counts.get(status) || 0) + 1);
  }
  groups.set(key, counts);
}

const statuses = [ 'HIT', 'MISS', 'BYPASS', 'EXPIRED', 'STALE', 'UPDATING', 'REVALIDATED', 'UNKNOWN' ];
const lines = [ [ 'size', 'framework', 'cacheMode', 'concurrency', 'requests', ...statuses, 'hitRate' ].join(';') ];
for (const [ key, counts ] of [ ...groups ].sort()) {
  const requests = [ ...counts.values() ].reduce((sum, count) => sum + count, 0);
  const hits = counts.get('HIT') || 0;
  lines.push([ key.replace(/;c(\d+)$/u, ';$1'), requests, ...statuses.map(status => counts.get(status) || 0),
    requests ? (hits / requests).toFixed(6) : '0.000000' ].join(';'));
}
fs.writeFileSync(output, `${lines.join('\n')}\n`);
console.log(`Wrote ${output}`);
