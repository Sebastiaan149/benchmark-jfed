#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');
const { pipeline } = require('stream');

const dataDir = process.env.WATDIV_DATA_DIR || process.argv[2];
const port = Number(process.env.PORT || process.argv[3] || 18089);
const activeTransferFile = process.env.WATDIV_ACTIVE_TRANSFER_FILE;
let activeTransfers = 0;

if (!dataDir) {
  console.error('Usage: static-dataset-server.js <data-dir> [port]');
  process.exit(1);
}

const routes = new Map([
  [ '/hdt/dataset.hdt', { file: path.join(dataDir, 'dataset.hdt'), type: 'application/x-hdt' }],
  [ '/hdt/dataset.hdt.index.v1-1', { file: path.join(dataDir, 'dataset.hdt.index.v1-1'), type: 'application/octet-stream' }],
]);

function updateActiveTransfers(delta) {
  activeTransfers = Math.max(0, activeTransfers + delta);
  if (activeTransferFile) {
    fs.mkdirSync(path.dirname(activeTransferFile), { recursive: true });
    fs.writeFileSync(activeTransferFile, `${activeTransfers}\n`);
  }
}

updateActiveTransfers(0);

function send(response, status, text) {
  response.writeHead(status, {
    'content-type': 'text/plain; charset=utf-8',
    'access-control-allow-origin': '*',
  });
  response.end(text);
}

http.createServer((request, response) => {
  const requestUrl = new URL(request.url, `http://${request.headers.host || 'localhost'}`);
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return send(response, 405, 'Only GET and HEAD are supported.\n');
  }
  if (requestUrl.pathname === '/') {
    return send(response, 200, 'WatDiv HDT dataset download\nGET /hdt/dataset.hdt\nGET /hdt/dataset.hdt.index.v1-1\n');
  }
  const route = routes.get(requestUrl.pathname);
  if (!route) {
    return send(response, 404, `No route for ${requestUrl.pathname}\n`);
  }
  fs.stat(route.file, (error, stat) => {
    if (error || !stat.isFile()) {
      return send(response, 404, `Missing file: ${route.file}\n`);
    }
    response.writeHead(200, {
      'content-type': route.type,
      'content-length': stat.size,
      'access-control-allow-origin': '*',
      'content-disposition': `attachment; filename="${path.basename(route.file)}"`,
    });
    if (request.method === 'HEAD') {
      response.end();
      return;
    }
    updateActiveTransfers(1);
    let finished = false;
    const finishTransfer = () => {
      if (!finished) {
        finished = true;
        updateActiveTransfers(-1);
      }
    };
    response.once('close', finishTransfer);
    response.once('finish', finishTransfer);
    pipeline(fs.createReadStream(route.file), response, (streamError) => {
      finishTransfer();
      if (streamError && !response.destroyed) {
        response.destroy(streamError);
      }
    });
  });
}).listen(port, '0.0.0.0', () => {
  console.log(`Static dataset server running at http://localhost:${port}/ from ${dataDir}`);
});
