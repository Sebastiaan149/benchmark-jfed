#!/usr/bin/env node
'use strict';

const fs = require('fs');
const fsPromises = require('fs/promises');
const path = require('path');
const { once } = require('events');
const { Readable } = require('stream');
const { pipeline } = require('stream/promises');
const { QueryEngine } = require('@comunica/query-sparql-hdt');

async function download(url, destination) {
  const response = await fetch(url);
  if (!response.ok || !response.body) {
    throw new Error(`Could not download ${url}: HTTP ${response.status} ${response.statusText}`);
  }
  await pipeline(Readable.fromWeb(response.body), fs.createWriteStream(destination));
}

async function writeBinding(binding) {
  const value = {};
  for (const [ variable, term ] of binding) {
    value[variable.value] = {
      termType: term.termType,
      value: term.value,
      language: term.language,
      datatype: term.datatype?.value,
    };
  }
  if (!process.stdout.write(`${JSON.stringify(value)}\n`)) {
    await once(process.stdout, 'drain');
  }
}

async function main() {
  const [ source, query ] = process.argv.slice(2);
  if (!source || !query) {
    throw new Error('Usage: query-hdt-dump.js <dataset-hdt-url> <SPARQL-query>');
  }
  const sourceUrl = new URL(source);
  if (sourceUrl.protocol !== 'http:' && sourceUrl.protocol !== 'https:') {
    throw new Error(`The HDT dump source must be an HTTP(S) URL: ${source}`);
  }
  if (!process.env.TMPDIR) {
    throw new Error('TMPDIR must identify the logical client\'s private temporary directory.');
  }

  const workDir = path.join(process.env.TMPDIR, 'hdt-dump');
  const hdtFile = path.join(workDir, 'dataset.hdt');
  const indexFile = `${hdtFile}.index.v1-1`;
  await fsPromises.rm(workDir, { recursive: true, force: true });
  await fsPromises.mkdir(workDir, { recursive: true });

  try {
    await download(sourceUrl.href, hdtFile);
    await download(`${sourceUrl.href}.index.v1-1`, indexFile);

    const engine = new QueryEngine();
    const bindings = await engine.queryBindings(query, {
      sources: [{ type: 'hdt', value: hdtFile }],
    });
    for await (const binding of bindings) {
      await writeBinding(binding);
    }
  } finally {
    await fsPromises.rm(workDir, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exit(1);
});
