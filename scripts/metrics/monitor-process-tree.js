#!/usr/bin/env node
'use strict';

const fs = require('fs');
const { execFile } = require('child_process');

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
        command: match[5].trim(),
      };
    })
    .filter(Boolean);
}

function processTree(processes, rootPid) {
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

async function sample(pid) {
  const processes = await listProcesses();
  const tree = processTree(processes, pid);
  return {
    timestamp: new Date().toISOString(),
    pid,
    processCount: tree.length,
    cpuPercent: tree.reduce((sum, process) => sum + process.cpuPercent, 0),
    rssMb: tree.reduce((sum, process) => sum + process.rssKb, 0) / 1024,
    commands: tree.map(process => `${process.pid}:${process.command}`).join('|'),
  };
}

function csvLine(sample) {
  return [
    sample.timestamp,
    sample.pid,
    sample.processCount,
    sample.cpuPercent.toFixed(2),
    sample.rssMb.toFixed(2),
    sample.commands.replaceAll(';', ','),
  ].join(';');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const pid = Number(args.pid);
  const output = args.out;
  const intervalMs = Number(args.interval || 1_000);
  const activeFile = args['active-file'];

  if (!pid || !output) {
    throw new Error('Usage: monitor-process-tree.js --pid <pid> --out <file> [--interval 1000]');
  }

  fs.mkdirSync(require('path').dirname(output), { recursive: true });
  fs.writeFileSync(output, 'timestamp;pid;processCount;cpuPercent;rssMb;commands\n');

  let stop = false;
  process.on('SIGTERM', () => {
    stop = true;
  });
  process.on('SIGINT', () => {
    stop = true;
  });

  while (!stop) {
    const current = await sample(pid);
    let active = !activeFile;
    if (activeFile) {
      try {
        active = Number(fs.readFileSync(activeFile, 'utf8').trim() || 0) > 0;
      } catch {
        active = false;
      }
    }
    if (active) {
      fs.appendFileSync(output, `${csvLine(current)}\n`);
    }
    if (current.processCount === 0) {
      break;
    }
    await new Promise(resolve => setTimeout(resolve, intervalMs));
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
