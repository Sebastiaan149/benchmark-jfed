#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { execFile, spawn } = require('child_process');
const { performance } = require('perf_hooks');

const benchRoot = path.resolve(__dirname, '..', '..');
const root = path.resolve(benchRoot, '..');
const configFile = process.env.CONFIG_FILE || path.join(benchRoot, 'config', 'frameworks.json');
const dataRoot = process.env.DATA_ROOT || path.join(benchRoot, 'data');
const resultsRoot = process.env.RESULTS_ROOT || path.join(benchRoot, 'watdiv-results');
const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));

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

function listQueryFiles(dir) {
  const files = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      files.push(...listQueryFiles(full));
    } else if (entry.isFile() && entry.name.endsWith('.txt')) {
      files.push(full);
    }
  }
  return files.sort();
}

// WatDiv stores several query instances in each template file, separated by
// one empty line. Expand them before benchmarking so each process receives one
// complete SPARQL query, matching the canonical WatDiv benchmark runner.
function loadQueries(dir, selection = []) {
  const queries = listQueryFiles(dir).flatMap((file) =>
    fs.readFileSync(file, 'utf8')
      .replaceAll('\r\n', '\n')
      .split('\n\n')
      .map(query => query.trim())
      .filter(Boolean)
      .map((query, index) => ({ file, instance: index + 1, query })));

  if (selection?.allTemplates) {
    const repetitions = Number(selection.repetitions || 1);
    if (!Number.isInteger(repetitions) || repetitions < 1) {
      throw new Error(`Invalid query selection repetition count: ${selection.repetitions}`);
    }
    return Array.from({ length: repetitions }, () => queries).flat();
  }

  if (selection.length === 0) {
    return queries;
  }

  return selection.map(({ template, instance }) => {
    const selected = queries.find(query =>
      path.basename(query.file, path.extname(query.file)).toLowerCase() === String(template).toLowerCase() &&
      query.instance === Number(instance));
    if (!selected) {
      throw new Error(`Selected WatDiv query ${template} instance ${instance} does not exist in ${dir}`);
    }
    return selected;
  });
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function removeDir(dir) {
  fs.rmSync(dir, { recursive: true, force: true });
}

function removeClientCaches(clientDir) {
  for (const cacheDir of [ 'home', 'tmp', '.smartkg-cache', '.wisekg-cache' ]) {
    removeDir(path.join(clientDir, cacheDir));
  }
}

function resetRunDir(dir) {
  ensureDir(dir);
  for (const entry of fs.readdirSync(dir)) {
    // The network monitor is already writing this file when the workload
    // starts, so removing it here would detach its open file descriptor.
    if (entry !== 'client-netns.csv') {
      removeDir(path.join(dir, entry));
    }
  }
}

function parseMemoryToBytes(value) {
  if (!value || value === 'max') {
    return value || 'max';
  }
  const match = /^(\d+(?:\.\d+)?)([kmgt]?b?)?$/iu.exec(String(value).trim());
  if (!match) {
    return value;
  }
  const amount = Number(match[1]);
  const suffix = (match[2] || '').toLowerCase().replace(/b$/u, '');
  const multipliers = { '': 1, k: 1024, m: 1024 ** 2, g: 1024 ** 3, t: 1024 ** 4 };
  return String(Math.floor(amount * (multipliers[suffix] || 1)));
}

function createResourceController({ cgroupRoot, groupName, cpuMax, memoryMax }) {
  if (!cgroupRoot || !groupName) {
    return undefined;
  }
  return (pid) => {
    const dir = path.join(cgroupRoot, groupName);
    fs.mkdirSync(dir, { recursive: true });
    if (cpuMax) {
      fs.writeFileSync(path.join(dir, 'cpu.max'), `${cpuMax}\n`);
    }
    if (memoryMax) {
      fs.writeFileSync(path.join(dir, 'memory.max'), `${parseMemoryToBytes(memoryMax)}\n`);
    }
    fs.writeFileSync(path.join(dir, 'cgroup.procs'), `${pid}\n`);
  };
}

function execFileText(command, args) {
  return new Promise(resolve => execFile(command, args, { encoding: 'utf8' }, (error, stdout) => {
    resolve(error ? '' : stdout);
  }));
}

async function listProcesses() {
  const stdout = await execFileText('ps', [ '-eo', 'pid=,ppid=,pcpu=,rss=,comm=' ]);
  return stdout
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => {
      const match = /^\s*(\d+)\s+(\d+)\s+([0-9.]+)\s+(\d+)\s+(.+)$/u.exec(line);
      if (!match) {
        return undefined;
      }
      return {
        pid: Number(match[1]),
        ppid: Number(match[2]),
        cpuPercent: Number(match[3]),
        rssKb: Number(match[4]),
      };
    })
    .filter(Boolean);
}

function getProcessTree(processes, rootPid) {
  const byParent = new Map();
  for (const process of processes) {
    const children = byParent.get(process.ppid) ?? [];
    children.push(process);
    byParent.set(process.ppid, children);
  }

  const tree = [];
  const queue = [ rootPid ];
  const seen = new Set();
  while (queue.length > 0) {
    const pid = queue.shift();
    if (seen.has(pid)) {
      continue;
    }
    seen.add(pid);
    const process = processes.find(candidate => candidate.pid === pid);
    if (process) {
      tree.push(process);
    }
    for (const child of byParent.get(pid) ?? []) {
      queue.push(child.pid);
    }
  }
  return tree;
}

async function sampleProcessTree(rootPid) {
  const tree = getProcessTree(await listProcesses(), rootPid);
  return {
    processCount: tree.length,
    cpuPercent: tree.reduce((sum, process) => sum + process.cpuPercent, 0),
    rssMb: tree.reduce((sum, process) => sum + process.rssKb, 0) / 1024,
  };
}

function summarizeResourceSamples(samples) {
  if (samples.length === 0) {
    return {
      sampleCount: 0,
      avgCpuPercent: 0,
      maxCpuPercent: 0,
      avgRssMb: 0,
      maxRssMb: 0,
    };
  }
  return {
    sampleCount: samples.length,
    avgCpuPercent: samples.reduce((sum, sample) => sum + sample.cpuPercent, 0) / samples.length,
    maxCpuPercent: Math.max(...samples.map(sample => sample.cpuPercent)),
    avgRssMb: samples.reduce((sum, sample) => sum + sample.rssMb, 0) / samples.length,
    maxRssMb: Math.max(...samples.map(sample => sample.rssMb)),
  };
}

function startResourceSampler(pid, intervalMs) {
  const samples = [];
  let stopped = false;
  const tick = async() => {
    if (stopped) {
      return;
    }
    const sample = await sampleProcessTree(pid);
    if (!stopped && sample.processCount > 0) {
      samples.push({ timestampMs: Date.now(), ...sample });
    }
  };
  const timer = setInterval(() => {
    void tick();
  }, intervalMs);
  void tick();
  return {
    samples,
    async stop() {
      stopped = true;
      clearInterval(timer);
      await tick();
      return summarizeResourceSamples(samples);
    },
  };
}

function runCommand(command, args, options, timeoutMs, sampleIntervalMs, applyResourceControl, retainStdout) {
  return new Promise((resolve) => {
    const started = performance.now();
    const child = spawn(command, args, options);
    if (applyResourceControl) {
      applyResourceControl(child.pid);
    }
    const sampler = startResourceSampler(child.pid, sampleIntervalMs);
    let stdout = '';
    let stderr = '';
    let timedOut = false;
    let firstResultTimeMs;
    let stdoutNewlines = 0;
    let stdoutHasData = false;
    let stdoutEndsWithNewline = false;
    const timer = setTimeout(() => {
      timedOut = true;
      child.kill('SIGTERM');
      setTimeout(() => child.kill('SIGKILL'), 5_000).unref();
    }, timeoutMs);
    child.stdout.on('data', (chunk) => {
      const text = String(chunk);
      if (firstResultTimeMs === undefined && text.length > 0) {
        firstResultTimeMs = Math.round(performance.now() - started);
      }
      if (text.length > 0) {
        stdoutHasData = true;
        stdoutNewlines += (text.match(/\n/gu) || []).length;
        stdoutEndsWithNewline = text.endsWith('\n');
      }
      if (retainStdout) {
        stdout += text;
      }
    });
    child.stderr.on('data', chunk => stderr += chunk);
    child.on('close', async(status, signal) => {
      clearTimeout(timer);
      const resourceSummary = await sampler.stop();
      const timeMs = Math.round(performance.now() - started);
      const resultCount = stdoutNewlines + (stdoutHasData && !stdoutEndsWithNewline ? 1 : 0);
      resolve({ status, signal, timedOut, stdout, stderr, timeMs, firstResultTimeMs, resultCount, resourceSummary });
    });
    child.on('error', async(error) => {
      clearTimeout(timer);
      const resourceSummary = await sampler.stop();
      resolve({
        status: -1,
        signal: undefined,
        timedOut,
        stdout,
        stderr: `${stderr}${error.stack || error.message}\n`,
        timeMs: Math.round(performance.now() - started),
        firstResultTimeMs,
        resultCount: stdoutNewlines + (stdoutHasData && !stdoutEndsWithNewline ? 1 : 0),
        resourceSummary,
      });
    });
  });
}

async function runClient({
  clientId,
  queries,
  framework,
  frameworkConfig,
  source,
  cacheMode,
  iterationDir,
  timeoutMs,
  queryLimit,
  sampleIntervalMs,
  clientIdOffset,
  netnsPrefix,
  cgroupRoot,
  clientCpuMax,
  clientMemoryMax,
  retainQueryOutputs,
  keepClientCaches,
  workloadPhase,
  resume,
  existingRows,
}) {
  const globalClientId = clientId + clientIdOffset;
  const clientDir = path.join(iterationDir, 'clients', `client-${globalClientId}`);
  if (cacheMode === 'cold' && !resume) {
    removeDir(clientDir);
  }
  ensureDir(clientDir);
  ensureDir(path.join(clientDir, 'home'));
  ensureDir(path.join(clientDir, 'tmp'));
  ensureDir(path.join(clientDir, 'outputs'));

  const engineBin = frameworkConfig.clientMode === 'hdt-download' ?
    path.join(benchRoot, 'scripts', 'benchmark', 'query-hdt-dump.js') :
    path.join(root, 'comunicaMT', 'engines', frameworkConfig.engine, 'bin', 'query.js');
  const querySlice = queryLimit > 0 ? queries.slice(0, queryLimit) : queries;
  const env = {
    ...process.env,
    HOME: path.join(clientDir, 'home'),
    TMPDIR: path.join(clientDir, 'tmp'),
    NODE_OPTIONS: process.env.NODE_OPTIONS || `--max-old-space-size=${config.resources.clientNodeMaxOldSpaceSizeMb}`,
  };

  async function runPass(phase) {
    const rows = [];
    const completedQueryIndices = new Set(existingRows
      .filter(row => row.phase === phase && Number(row.client) === globalClientId)
      .map(row => Number(row.queryIndex)));
    const failedQueries = new Set(existingRows
      .filter(row => row.phase === phase && Number(row.client) === globalClientId &&
        (String(row.status) !== '0' || row.timedOut))
      .map(row => `${row.query};${row.queryInstance}`));
    for (let queryIndex = 0; queryIndex < querySlice.length; queryIndex++) {
      if (completedQueryIndices.has(queryIndex)) {
        continue;
      }
      const queryEntry = querySlice[queryIndex];
      const queryName = path.relative(dataRoot, queryEntry.file).replaceAll(path.sep, '/');
      if (failedQueries.has(`${queryName};${queryEntry.instance}`)) {
        continue;
      }
      const command = netnsPrefix ? 'ip' : 'node';
      const commandArgs = netnsPrefix ?
        [ 'netns', 'exec', `${netnsPrefix}${globalClientId}`, 'node', engineBin, source, queryEntry.query ] :
        [ engineBin, source, queryEntry.query ];
      const result = await runCommand(command, commandArgs, {
        cwd: clientDir,
        env,
      }, timeoutMs, sampleIntervalMs, createResourceController({
        cgroupRoot,
        groupName: `client-${globalClientId}`,
        cpuMax: clientCpuMax,
        memoryMax: clientMemoryMax,
      }), retainQueryOutputs);
      const safeName = `${queryName}-instance-${queryEntry.instance}`.replace(/[^a-zA-Z0-9_.-]+/gu, '_');
      const outFile = path.join(clientDir, 'outputs', `${phase}-${queryIndex}-${safeName}.out`);
      const errFile = path.join(clientDir, 'outputs', `${phase}-${queryIndex}-${safeName}.err`);
      if (retainQueryOutputs) {
        fs.writeFileSync(outFile, result.stdout);
      }
      if (result.stderr || result.status !== 0 || result.timedOut) {
        fs.writeFileSync(errFile, result.stderr);
      }
      const results = result.resultCount;
      const throughput = result.timeMs > 0 ? results / (result.timeMs / 1_000) : 0;
      const row = {
        phase,
        client: globalClientId,
        queryIndex,
        query: queryName,
        queryInstance: queryEntry.instance,
        status: result.status,
        signal: result.signal || '',
        timedOut: result.timedOut,
        results,
        timeMs: result.timeMs,
        firstResultTimeMs: result.firstResultTimeMs ?? '',
        fullResultTimeMs: result.timeMs,
        resultThroughputPerSec: throughput,
        clientResourceSampleCount: result.resourceSummary.sampleCount,
        clientAvgCpuPercent: result.resourceSummary.avgCpuPercent,
        clientMaxCpuPercent: result.resourceSummary.maxCpuPercent,
        clientAvgRssMb: result.resourceSummary.avgRssMb,
        clientMaxRssMb: result.resourceSummary.maxRssMb,
        stdoutFile: retainQueryOutputs ? path.relative(iterationDir, outFile).replaceAll(path.sep, '/') : '',
        stderrFile: fs.existsSync(errFile) ? path.relative(iterationDir, errFile).replaceAll(path.sep, '/') : '',
      };
      rows.push(row);
      if (result.status !== 0 || result.timedOut) {
        break;
      }
    }
    return rows;
  }

  if (workloadPhase === 'warmup') {
    return runPass('warmup');
  }
  try {
    if (cacheMode === 'warm' && workloadPhase === 'both') {
      await runPass('warmup');
    }
    return await runPass('measured');
  } finally {
    if (!keepClientCaches) {
      removeClientCaches(clientDir);
    }
  }
}

function writeCsv(file, rows) {
  const header = [
    'phase',
    'client',
    'queryIndex',
    'query',
    'queryInstance',
    'status',
    'signal',
    'timedOut',
    'results',
    'timeMs',
    'firstResultTimeMs',
    'fullResultTimeMs',
    'resultThroughputPerSec',
    'clientResourceSampleCount',
    'clientAvgCpuPercent',
    'clientMaxCpuPercent',
    'clientAvgRssMb',
    'clientMaxRssMb',
    'stdoutFile',
    'stderrFile',
  ];
  const lines = [ header.join(';') ];
  for (const row of rows) {
    lines.push(header.map(key => String(row[key] ?? '').replaceAll(';', ',')).join(';'));
  }
  fs.writeFileSync(file, `${lines.join('\n')}\n`);
}

function readCsv(file) {
  if (!fs.existsSync(file)) {
    return [];
  }
  const lines = fs.readFileSync(file, 'utf8').trim().split(/\r?\n/u);
  if (lines.length < 2) {
    return [];
  }
  const headers = lines.shift().split(';');
  return lines.filter(Boolean).map((line) => {
    const values = line.split(';');
    const row = Object.fromEntries(headers.map((header, index) => [ header, values[index] ?? '' ]));
    for (const field of [
      'client', 'queryIndex', 'queryInstance', 'status', 'results', 'timeMs', 'firstResultTimeMs',
      'fullResultTimeMs', 'resultThroughputPerSec', 'clientResourceSampleCount', 'clientAvgCpuPercent',
      'clientMaxCpuPercent', 'clientAvgRssMb', 'clientMaxRssMb',
    ]) {
      if (row[field] !== '' && /^-?\d+(?:\.\d+)?$/u.test(row[field])) {
        row[field] = Number(row[field]);
      }
    }
    row.timedOut = row.timedOut === 'true';
    return row;
  });
}

function summarize(rows, phase = 'measured') {
  const measured = rows.filter(row => row.phase === phase);
  const totalTimeMs = measured.reduce((sum, row) => sum + row.timeMs, 0);
  const totalResults = measured.reduce((sum, row) => sum + row.results, 0);
  const failures = measured.filter(row => row.status !== 0 || row.timedOut).length;
  const withFirstResult = measured.filter(row => row.firstResultTimeMs !== '');
  const byQuery = new Map();
  for (const row of measured) {
    const bucket = byQuery.get(row.query) || [];
    bucket.push(row);
    byQuery.set(row.query, bucket);
  }
  return {
    queryInvocations: measured.length,
    failures,
    totalResults,
    averageTimeMs: measured.length ? totalTimeMs / measured.length : 0,
    averageFirstResultTimeMs: withFirstResult.length ?
      withFirstResult.reduce((sum, row) => sum + Number(row.firstResultTimeMs), 0) / withFirstResult.length :
      0,
    resultThroughputPerSec: totalTimeMs > 0 ? totalResults / (totalTimeMs / 1_000) : 0,
    clientAvgCpuPercent: measured.length ?
      measured.reduce((sum, row) => sum + Number(row.clientAvgCpuPercent || 0), 0) / measured.length :
      0,
    clientMaxCpuPercent: measured.length ? Math.max(...measured.map(row => Number(row.clientMaxCpuPercent || 0))) : 0,
    clientAvgRssMb: measured.length ?
      measured.reduce((sum, row) => sum + Number(row.clientAvgRssMb || 0), 0) / measured.length :
      0,
    clientMaxRssMb: measured.length ? Math.max(...measured.map(row => Number(row.clientMaxRssMb || 0))) : 0,
    queries: [ ...byQuery ].map(([ query, values ]) => ({
      query,
      invocations: values.length,
      averageTimeMs: values.reduce((sum, row) => sum + row.timeMs, 0) / values.length,
      averageFirstResultTimeMs: values
        .filter(row => row.firstResultTimeMs !== '')
        .reduce((sum, row, _index, filtered) => sum + Number(row.firstResultTimeMs) / filtered.length, 0),
      averageResults: values.reduce((sum, row) => sum + row.results, 0) / values.length,
      resultThroughputPerSec: values.reduce((sum, row) => sum + row.timeMs, 0) > 0 ?
        values.reduce((sum, row) => sum + row.results, 0) /
        (values.reduce((sum, row) => sum + row.timeMs, 0) / 1_000) :
        0,
      failures: values.filter(row => row.status !== 0 || row.timedOut).length,
    })),
  };
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

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const framework = args.framework;
  const size = args.size;
  const concurrency = Number(args.concurrency || 1);
  const totalConcurrency = Number(args['total-concurrency'] || concurrency);
  const runLabel = args['run-label'] || '';
  const iterations = Number(args.iterations || config.defaultIterations || 1);
  const cacheMode = args.cache || 'cold';
  const queryLimit = Number(args['query-limit'] || 0);
  const sampleIntervalMs = Number(args['sample-interval-ms'] || config.resources.sampleIntervalMs || 1_000);
  const serverResourceFile = args['server-resource-file'];
  const clientIdOffset = Number(args['client-id-offset'] || 0);
  const netnsPrefix = args['netns-prefix'] || '';
  const cgroupRoot = args['client-cgroup-root'];
  const clientCpuMax = args['client-cpu-max'];
  const clientMemoryMax = args['client-memory-max'];
  const retainQueryOutputs = String(args['retain-query-outputs'] ?? config.resources.retainQueryOutputs ?? false) === '1' ||
    String(args['retain-query-outputs'] ?? config.resources.retainQueryOutputs ?? false).toLowerCase() === 'true';
  const keepClientCaches = String(args['keep-client-caches'] ?? config.resources.keepClientCaches ?? false) === '1' ||
    String(args['keep-client-caches'] ?? config.resources.keepClientCaches ?? false).toLowerCase() === 'true';
  const workloadPhase = args['workload-phase'] || 'both';
  const resume = String(args.resume || false) === '1' || String(args.resume || false).toLowerCase() === 'true';
  const querySelectionName = args['query-selection'] || config.defaultQuerySelection;

  if (!framework || !size) {
    throw new Error('Usage: 03-run-benchmark.js --framework <name> --size <size> [--concurrency N] [--total-concurrency N] [--run-label label]');
  }
  const frameworkConfig = config.frameworks[framework];
  if (!frameworkConfig) {
    throw new Error(`Unknown framework: ${framework}`);
  }
  if (frameworkConfig.unsupportedReason) {
    throw new Error(`${framework} is unsupported: ${frameworkConfig.unsupportedReason}`);
  }
  if (![ 'both', 'warmup', 'measured' ].includes(workloadPhase)) {
    throw new Error(`Unsupported workload phase: ${workloadPhase}`);
  }
  const querySelection = config.querySelections?.[querySelectionName];
  if ((!Array.isArray(querySelection) || querySelection.length === 0) && !querySelection?.allTemplates) {
    throw new Error(`Unknown or empty query selection: ${querySelectionName}`);
  }
  const timeoutMs = Number(args.timeout || frameworkConfig.queryTimeoutSeconds ||
    config.resources.queryTimeoutSeconds) * 1_000;
  const dataDir = path.join(dataRoot, size);
  const queriesDir = path.join(dataDir, 'queries');
  const queries = loadQueries(queriesDir, querySelection);
  if (queries.length === 0) {
    throw new Error(`No .txt queries found in ${queriesDir}`);
  }

  const port = Number(args.port || frameworkConfig.port);
  const source = (args.source || frameworkConfig.source).replaceAll('{port}', String(port));
  const runRootBase = path.join(resultsRoot, size, framework, cacheMode, `c${totalConcurrency}`);
  const runRoot = runLabel ? path.join(runRootBase, runLabel) : runRootBase;
  if (workloadPhase !== 'measured' && !resume) {
    resetRunDir(runRoot);
  }

  const allSummaries = [];
  let attemptFailureCount = 0;
  for (let iteration = 1; iteration <= iterations; iteration++) {
    const iterationDir = path.join(runRoot, `iteration-${String(iteration).padStart(3, '0')}`);
    const queryTimesFile = path.join(iterationDir, 'query-times.csv');
    const existingRows = resume ? readCsv(queryTimesFile) : [];
    if (cacheMode === 'cold' && !resume) {
      removeDir(iterationDir);
    }
    ensureDir(iterationDir);
    const started = Date.now();
    const clientPromises = [];
    for (let clientId = 1; clientId <= concurrency; clientId++) {
      clientPromises.push(runClient({
        clientId,
        queries,
        framework,
        frameworkConfig,
        source,
        cacheMode,
        iterationDir,
        timeoutMs,
        queryLimit,
        sampleIntervalMs,
        clientIdOffset,
        netnsPrefix,
        cgroupRoot,
        clientCpuMax,
        clientMemoryMax,
        retainQueryOutputs,
        keepClientCaches,
        workloadPhase,
        resume,
        existingRows,
      }));
    }
    const attemptRows = (await Promise.all(clientPromises)).flat();
    attemptFailureCount += attemptRows.filter(row => row.status !== 0 || row.timedOut).length;
    const rows = [ ...existingRows, ...attemptRows ].sort((left, right) =>
      Number(left.client) - Number(right.client) || Number(left.queryIndex) - Number(right.queryIndex));
    writeCsv(queryTimesFile, rows);
    const summary = {
      framework,
      size,
      cacheMode,
      concurrency: totalConcurrency,
      localConcurrency: concurrency,
      clientIdOffset,
      runLabel,
      iteration,
      wallTimeMs: Date.now() - started,
      source,
      querySelection: querySelectionName,
      queryCount: queries.length,
      clientCpuMax: clientCpuMax || '',
      clientMemoryMax: clientMemoryMax || '',
      ...summarize(rows, workloadPhase === 'warmup' ? 'warmup' : 'measured'),
      ...readServerResourceSummary(serverResourceFile),
    };
    fs.writeFileSync(path.join(iterationDir, 'summary.json'), `${JSON.stringify(summary, null, 2)}\n`);
    allSummaries.push(summary);
    console.log(`${framework} ${size} ${cacheMode} c${concurrency} iteration ${iteration}: avg=${Math.round(summary.averageTimeMs)}ms failures=${summary.failures}`);
  }

  fs.writeFileSync(path.join(runRoot, 'summary.json'), `${JSON.stringify(allSummaries, null, 2)}\n`);
  if (attemptFailureCount > 0) {
    throw new Error(
      `${attemptFailureCount} query executions failed for ${framework} ${size} ${cacheMode} ` +
      `c${totalConcurrency}; inspect the .err files under ${runRoot}.`,
    );
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(error.stack || error.message);
    process.exit(1);
  });
}

module.exports = { loadQueries, resetRunDir };
