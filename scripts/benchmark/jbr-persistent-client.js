#!/usr/bin/env node
'use strict';

// JBR's WatDiv and SPARQL-custom experiments delegate query execution to
// sparql-benchmark-runner. This adapter uses that same runner while adding the
// per-query measurement boundaries required by benchmark-jfed.
const fs = require('fs');
const path = require('path');
const { execFile, spawn } = require('child_process');
const { performance } = require('perf_hooks');
const { SparqlBenchmarkRunner } = require('sparql-benchmark-runner');

function execFileText(command, args) {
  return new Promise(resolve => execFile(command, args, { encoding: 'utf8' }, (error, stdout) => {
    resolve(error ? '' : stdout);
  }));
}

async function listProcesses() {
  const stdout = await execFileText('ps', [ '-eo', 'pid=,ppid=,pcpu=,rss=' ]);
  return stdout.trim().split('\n').filter(Boolean).map((line) => {
    const match = /^\s*(\d+)\s+(\d+)\s+([0-9.]+)\s+(\d+)$/u.exec(line);
    return match ? {
      pid: Number(match[1]),
      ppid: Number(match[2]),
      cpuPercent: Number(match[3]),
      rssKb: Number(match[4]),
    } : undefined;
  }).filter(Boolean);
}

function processTree(processes, rootPid) {
  const byParent = new Map();
  for (const process of processes) {
    const children = byParent.get(process.ppid) || [];
    children.push(process);
    byParent.set(process.ppid, children);
  }
  const result = [];
  const pending = [ rootPid ];
  const seen = new Set();
  while (pending.length > 0) {
    const pid = pending.shift();
    if (seen.has(pid)) {
      continue;
    }
    seen.add(pid);
    const process = processes.find(candidate => candidate.pid === pid);
    if (process) {
      result.push(process);
    }
    for (const child of byParent.get(pid) || []) {
      pending.push(child.pid);
    }
  }
  return result;
}

async function sampleProcessTree(rootPid) {
  const tree = processTree(await listProcesses(), rootPid);
  return {
    processCount: tree.length,
    rssMb: tree.reduce((sum, process) => sum + process.rssKb, 0) / 1024,
  };
}

async function processCpuTicks(rootPid) {
  const tree = processTree(await listProcesses(), rootPid);
  let ticks = 0;
  for (const process of tree) {
    try {
      // Fields 14 and 15 are user and system CPU ticks. Strip the comm field
      // first because it may contain spaces and parentheses.
      const stat = fs.readFileSync(`/proc/${process.pid}/stat`, 'utf8');
      const fields = stat.slice(stat.lastIndexOf(')') + 2).trim().split(/\s+/u);
      ticks += Number(fields[11]) + Number(fields[12]);
    } catch {
      // A process may exit between ps and reading /proc.
    }
  }
  return ticks;
}

function summarizeSamples(samples) {
  if (samples.length === 0) {
    return { sampleCount: 0, avgCpuPercent: 0, maxCpuPercent: 0, avgRssMb: 0, maxRssMb: 0 };
  }
  return {
    sampleCount: samples.length,
    avgCpuPercent: samples.reduce((sum, sample) => sum + sample.cpuPercent, 0) / samples.length,
    maxCpuPercent: Math.max(...samples.map(sample => sample.cpuPercent)),
    avgRssMb: samples.reduce((sum, sample) => sum + sample.rssMb, 0) / samples.length,
    maxRssMb: Math.max(...samples.map(sample => sample.rssMb)),
  };
}

async function startSampler(rootPid, intervalMs, clockTicksPerSecond) {
  const samples = [];
  let stopped = false;
  let pending = Promise.resolve();
  let previousTicks = await processCpuTicks(rootPid);
  let previousTime = performance.now();
  const tick = async() => {
    if (!stopped) {
      const sample = await sampleProcessTree(rootPid);
      const ticks = await processCpuTicks(rootPid);
      const now = performance.now();
      const elapsedMs = now - previousTime;
      sample.cpuPercent = elapsedMs > 0 ?
        Math.max(0, ((ticks - previousTicks) / clockTicksPerSecond) / (elapsedMs / 1_000) * 100) : 0;
      previousTicks = ticks;
      previousTime = now;
      if (!stopped && sample.processCount > 0) {
        samples.push(sample);
      }
    }
  };
  pending = tick();
  const timer = setInterval(() => {
    pending = tick();
  }, intervalMs);
  return async() => {
    clearInterval(timer);
    await pending;
    // Capture the state at stream completion as part of the query interval.
    const finalSample = await sampleProcessTree(rootPid);
    const finalTicks = await processCpuTicks(rootPid);
    const now = performance.now();
    const elapsedMs = now - previousTime;
    finalSample.cpuPercent = elapsedMs > 0 ?
      Math.max(0, ((finalTicks - previousTicks) / clockTicksPerSecond) / (elapsedMs / 1_000) * 100) : 0;
    if (finalSample.processCount > 0) {
      samples.push(finalSample);
    }
    stopped = true;
    return summarizeSamples(samples);
  };
}

function readNetworkCounters() {
  const totals = { rxBytes: 0, rxPackets: 0, txBytes: 0, txPackets: 0 };
  const lines = fs.readFileSync('/proc/net/dev', 'utf8').trim().split('\n').slice(2);
  for (const line of lines) {
    const [ rawName, rawValues ] = line.split(':');
    if (!rawValues || rawName.trim() === 'lo') {
      continue;
    }
    const values = rawValues.trim().split(/\s+/u).map(Number);
    totals.rxBytes += values[0];
    totals.rxPackets += values[1];
    totals.txBytes += values[8];
    totals.txPackets += values[9];
  }
  return totals;
}

function subtractCounters(after, before) {
  return Object.fromEntries(Object.keys(after).map(key => [ key, Math.max(0, after[key] - before[key]) ]));
}

function stopProcessTree(child) {
  if (!child || child.exitCode !== null) {
    return;
  }
  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch {
    child.kill('SIGTERM');
  }
  const killTimer = setTimeout(() => {
    try {
      process.kill(-child.pid, 'SIGKILL');
    } catch {
      child.kill('SIGKILL');
    }
  }, 5_000);
  killTimer.unref();
}

async function main() {
  const [ inputFile, outputFile ] = process.argv.slice(2);
  if (!inputFile || !outputFile) {
    throw new Error('Usage: jbr-persistent-client.js <input.json> <output.json>');
  }
  const input = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
  const clockTicksPerSecond = Number((await execFileText('getconf', [ 'CLK_TCK' ])).trim()) || 100;
  fs.mkdirSync(path.dirname(input.endpointLog), { recursive: true });
  const endpointLog = fs.openSync(input.endpointLog, 'a');
  const endpoint = spawn('node', [
    input.engineBin,
    '--port', String(input.port),
    '--workers', '1',
    '--timeout', String(Math.ceil(input.timeoutMs / 1_000)),
    input.source,
  ], {
    cwd: input.cwd,
    env: process.env,
    detached: true,
    stdio: [ 'ignore', endpointLog, endpointLog ],
  });
  // A benchmark cancellation normally terminates this adapter first. Ensure
  // the detached Comunica master and worker do not survive that cancellation.
  const stopOnSignal = signal => {
    stopProcessTree(endpoint);
    process.exit(signal === 'SIGINT' ? 130 : 143);
  };
  process.once('SIGINT', () => stopOnSignal('SIGINT'));
  process.once('SIGTERM', () => stopOnSignal('SIGTERM'));
  if (input.cgroupDir) {
    for (let attempt = 0; attempt < 100 && !fs.existsSync(input.cgroupDir); attempt++) {
      await new Promise(resolve => setTimeout(resolve, 10));
    }
    try {
      fs.writeFileSync(path.join(input.cgroupDir, 'cgroup.procs'), `${endpoint.pid}\n`);
    } catch (error) {
      stopProcessTree(endpoint);
      throw error;
    }
  }
  let endpointError;
  endpoint.once('error', error => endpointError = error);

  const endpointUrl = `http://127.0.0.1:${input.port}/sparql`;
  const runner = new SparqlBenchmarkRunner({
    endpoint: endpointUrl,
    endpointUpCheck: endpointUrl,
    querySets: {},
    replication: 1,
    warmup: 0,
    timeout: input.timeoutMs,
    availabilityCheckTimeout: Math.min(120_000, input.timeoutMs),
    logger: message => fs.appendFileSync(input.endpointLog, `[jbr] ${message}\n`),
  });
  let retainedBindings;
  const fetchBindings = runner.endpointFetcher.fetchBindings.bind(runner.endpointFetcher);
  runner.endpointFetcher.fetchBindings = async(...args) => {
    const stream = await fetchBindings(...args);
    if (retainedBindings) {
      stream.on('data', binding => retainedBindings.push(runner.bindingsToString(binding)));
    }
    return stream;
  };
  const output = [];
  let failedPhase;
  try {
    await runner.waitForEndpoint();
    if (endpointError) {
      throw endpointError;
    }
    // Endpoint construction, worker creation, module loading, and the initial
    // V8 work above are deliberately outside every query measurement.
    for (const execution of input.executions) {
      if (execution.phase === failedPhase) {
        continue;
      }
      retainedBindings = input.retainQueryOutputs ? [] : undefined;
      const stopSampler = await startSampler(endpoint.pid, input.sampleIntervalMs, clockTicksPerSecond);
      const cpuBefore = await processCpuTicks(endpoint.pid);
      const networkBefore = input.measureNetwork ? readNetworkCounters() : undefined;
      const measurementStarted = performance.now();
      const result = await runner.executeQuery(execution.queryName, String(execution.queryIndex), execution.query);
      const wrapperTimeMs = performance.now() - measurementStarted;
      const cpuAfter = await processCpuTicks(endpoint.pid);
      const networkAfter = networkBefore ? readNetworkCounters() : undefined;
      const resourceSummary = await stopSampler();
      const network = networkBefore ? subtractCounters(networkAfter, networkBefore) : {};
      const errorMessage = result.error ? String(result.error.stack || result.error.message || result.error) : '';
      const clientCpuTimeMs = Math.max(0, cpuAfter - cpuBefore) / clockTicksPerSecond * 1_000;
      resourceSummary.avgCpuPercent = wrapperTimeMs > 0 ? clientCpuTimeMs / wrapperTimeMs * 100 : 0;
      output.push({
        ...execution,
        status: result.error ? 1 : 0,
        signal: '',
        timedOut: /timed out/iu.test(errorMessage),
        results: result.results,
        timeMs: result.time,
        wrapperTimeMs,
        firstResultTimeMs: result.timestamps.length > 0 ? result.timestamps[0] : '',
        fullResultTimeMs: result.time,
        resultHash: result.hash,
        resultTimestampsMs: result.timestamps,
        bindingsOutput: retainedBindings ? `${retainedBindings.join('\n')}\n` : undefined,
        resourceSummary,
        clientCpuTimeMs,
        ...network,
        error: errorMessage,
      });
      if (result.error) {
        failedPhase = execution.phase;
      }
    }
    fs.writeFileSync(outputFile, `${JSON.stringify(output, null, 2)}\n`);
  } finally {
    process.removeAllListeners('SIGINT');
    process.removeAllListeners('SIGTERM');
    stopProcessTree(endpoint);
    fs.closeSync(endpointLog);
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
