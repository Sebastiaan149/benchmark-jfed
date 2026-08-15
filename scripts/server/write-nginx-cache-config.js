#!/usr/bin/env node
'use strict';

const fs = require('fs');

const [ output, cacheDir, tempDir, accessLog, errorLog, publicPort, originPort ] = process.argv.slice(2);
if (![ output, cacheDir, tempDir, accessLog, errorLog, publicPort, originPort ].every(Boolean)) {
  throw new Error('Usage: write-nginx-cache-config.js <output> <cache-dir> <temp-dir> <access-log> <error-log> <public-port> <origin-port>');
}

fs.writeFileSync(output, `
worker_processes 6;
pid ${JSON.stringify(`${tempDir}/nginx.pid`)};
error_log ${JSON.stringify(errorLog)};

events {
  worker_connections 4096;
}

http {
  map $request_method $skip_fragment_cache {
    default 1;
    GET 0;
    HEAD 0;
    POST 0;
  }
  log_format fragments '$remote_addr [$time_iso8601] "$request" $status $body_bytes_sent "$http_accept" $upstream_cache_status';
  access_log ${JSON.stringify(accessLog)} fragments;
  proxy_cache_path ${JSON.stringify(cacheDir)} levels=1:2 keys_zone=fragments_cache:100m max_size=50000m inactive=600m use_temp_path=off;
  proxy_temp_path ${JSON.stringify(tempDir)};

  server {
    listen ${Number(publicPort)};
    server_name _;

    location / {
      proxy_pass http://127.0.0.1:${Number(originPort)}$request_uri;
      proxy_set_header Host $http_host;
      proxy_pass_header Server;
      proxy_buffering on;
      proxy_cache fragments_cache;
      proxy_cache_methods GET HEAD POST;
      proxy_cache_key "$request_method $request_uri $request_body $http_accept $content_type";
      proxy_cache_valid 200 302 404 60m;
      proxy_cache_bypass $skip_fragment_cache $arg_nocache $http_pragma;
      proxy_no_cache $skip_fragment_cache;
      proxy_cache_lock on;
      proxy_cache_lock_timeout 60s;
      proxy_cache_use_stale error timeout invalid_header updating http_500 http_502 http_503 http_504;
      add_header X-Cache-Status $upstream_cache_status always;
      expires 7d;
    }
  }
}
`);
