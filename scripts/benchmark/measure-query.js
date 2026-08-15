#!/usr/bin/env node
'use strict';

const fs = require('fs');
const { spawn } = require('child_process');
const { performance } = require('perf_hooks');
const { FirstResultDetector, ResultLineCounter } = require('./first-result-detector');

const [ engine, source, queryFile, timeoutSeconds = '1800' ] = process.argv.slice(2);
if (!engine || !source || !queryFile) {
  throw new Error('Usage: measure-query.js <engine-bin> <source> <query-file> [timeout-seconds]');
}

const query = fs.readFileSync(queryFile, 'utf8');
const started = performance.now();
const child = spawn('node', [ engine, source, query ], { stdio: [ 'ignore', 'pipe', 'pipe' ] });
let firstResultTimeMs;
let stderr = '';
let timedOut = false;
const detector = new FirstResultDetector(() => {
  firstResultTimeMs = Math.round(performance.now() - started);
});
const resultCounter = new ResultLineCounter();

child.stdout.on('data', (chunk) => {
  const text = String(chunk);
  detector.push(text);
  resultCounter.push(text);
});
child.stderr.on('data', (chunk) => {
  stderr = `${stderr}${String(chunk)}`.slice(-65_536);
});

const timer = setTimeout(() => {
  timedOut = true;
  child.kill('SIGTERM');
  setTimeout(() => child.kill('SIGKILL'), 5_000).unref();
}, Number(timeoutSeconds) * 1_000);

child.on('close', (status, signal) => {
  clearTimeout(timer);
  process.stdout.write(`${JSON.stringify({
    query: queryFile,
    status,
    signal,
    timedOut,
    results: resultCounter.finish(),
    firstResultTimeMs: firstResultTimeMs ?? null,
    elapsedTimeMs: Math.round(performance.now() - started),
    stderr: status === 0 && !timedOut ? '' : stderr,
  })}\n`);
});
