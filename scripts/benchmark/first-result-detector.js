'use strict';

// Comunica's default JSON serializer writes an opening `[` before it has a
// binding. Detect the first non-whitespace byte inside that array instead.
// Non-array streaming formats (such as the HDT dump client's NDJSON) count
// their first non-whitespace byte as the first result.
class FirstResultDetector {
  constructor(onFirstResult) {
    this.onFirstResult = onFirstResult;
    this.state = 'prefix';
  }

  push(chunk) {
    if (this.state === 'found' || this.state === 'empty') {
      return;
    }
    for (const character of String(chunk)) {
      if (/\s/u.test(character) || (this.state === 'prefix' && character === '\uFEFF')) {
        continue;
      }
      if (this.state === 'prefix' && character === '[') {
        this.state = 'array';
        continue;
      }
      if (this.state === 'array' && character === ']') {
        this.state = 'empty';
        return;
      }
      this.state = 'found';
      this.onFirstResult();
      return;
    }
  }
}

class ResultLineCounter {
  constructor() {
    this.pending = '';
    this.count = 0;
  }

  push(chunk) {
    this.pending += String(chunk);
    let newline;
    while ((newline = this.pending.indexOf('\n')) >= 0) {
      this.countLine(this.pending.slice(0, newline));
      this.pending = this.pending.slice(newline + 1);
    }
  }

  finish() {
    this.countLine(this.pending);
    this.pending = '';
    return this.count;
  }

  countLine(line) {
    const value = line.trim();
    if (value && value !== '[' && value !== ']') {
      this.count++;
    }
  }
}

module.exports = { FirstResultDetector, ResultLineCounter };
