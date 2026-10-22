const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const { execFileSync } = require('child_process');

const PARAMS_FILE = path.join(process.cwd(), '.ci-params.json');

function parseCliArgs() {
  const args = process.argv.slice(2);
  const result = {};
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg.startsWith('--')) {
      const key = arg.slice(2);
      if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
        result[key] = args[i + 1];
        i++;
      } else {
        result[key] = true;
      }
    } else if (arg.startsWith('-')) {
      const key = arg.slice(1);
      if (i + 1 < args.length && !args[i + 1].startsWith('--') && !args[i + 1].startsWith('-')) {
        result[key] = args[i + 1];
        i++;
      } else {
        result[key] = true;
      }
    }
  }
  return result;
}

function loadParams() {
  if (fs.existsSync(PARAMS_FILE)) {
    try {
      return JSON.parse(fs.readFileSync(PARAMS_FILE, 'utf8'));
    } catch {
      // Ignore read error, fall through to event file
    }
  }

  const eventPath = process.env.GITHUB_EVENT_PATH;
  if (eventPath && fs.existsSync(eventPath)) {
    try {
      const event = JSON.parse(fs.readFileSync(eventPath, 'utf8'));
      if (event && event.inputs) {
        if (typeof event.inputs.params === 'string') {
          try {
            return JSON.parse(event.inputs.params);
          } catch {
            return event.inputs;
          }
        } else if (typeof event.inputs.params === 'object' && event.inputs.params !== null) {
          return event.inputs.params;
        }
        return event.inputs;
      }
    } catch {
      // Fall through to empty object
    }
  }

  return {};
}

function saveParams(params) {
  try {
    fs.writeFileSync(PARAMS_FILE, JSON.stringify(params, null, 2), {
      encoding: 'utf8',
      mode: 0o600,
    });
  } catch (err) {
    console.error('[ci-helper] Failed to save params cache:', err.message);
  }
}

function maskValue(val) {
  if (typeof val === 'string' && val.trim().length > 0) {
    const escaped = val.replace(/\r/g, '%0D').replace(/\n/g, '%0A');
    console.log(`::add-mask::${escaped}`);
  }
}

function maskSecrets(obj, visited = new Set()) {
  if (!obj || typeof obj !== 'object') return;
  if (visited.has(obj)) return;
  visited.add(obj);

  const sensitivePattern = /pass|secret|token|cred|auth|pat/i;
  const knownKeys = new Set([
    'p12pass',
    'p12_password',
    'keystorePassword',
    'keyPassword',
    'password',
    'pass',
    'token',
    'secret',
    'pat',
    'gh_pat',
    'git_password',
    'sentry_auth_token',
  ]);

  for (const [key, value] of Object.entries(obj)) {
    if (typeof value === 'string') {
      if (knownKeys.has(key.toLowerCase()) || sensitivePattern.test(key)) {
        maskValue(value);
      }
    } else if (typeof value === 'object' && value !== null) {
      maskSecrets(value, visited);
    }
  }
}

function getPackageVersion(subDir = 'input') {
  const pkgPath = path.join(process.cwd(), subDir, 'package.json');
  if (fs.existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
      if (pkg && pkg.version) return String(pkg.version).trim();
    } catch {
      // Ignore parse error
    }
  }
  return '';
}

function getCommitHash(subDir = 'input') {
  const targetDir = path.join(process.cwd(), subDir);
  if (fs.existsSync(path.join(targetDir, '.git')) || fs.existsSync(targetDir)) {
    try {
      return execFileSync('git', ['-C', targetDir, 'rev-parse', 'HEAD'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      }).trim();
    } catch {
      // Ignore git error
    }
  }
  return '';
}

function setOutput(name, value) {
  const outputFile = process.env.GITHUB_OUTPUT;
  if (outputFile && typeof value !== 'undefined') {
    try {
      fs.appendFileSync(outputFile, `${name}=${value}\n`, 'utf8');
    } catch (err) {
      console.error(`[ci-helper] Failed to write output ${name}:`, err.message);
    }
  }
}

async function httpRequest(urlStr, options = {}, body = null) {
  if (typeof globalThis.fetch === 'function') {
    const fetchOptions = {
      method: options.method || 'GET',
      headers: options.headers || {},
    };
    if (body !== null && body !== undefined && fetchOptions.method !== 'GET') {
      fetchOptions.body = body;
    }
    const res = await globalThis.fetch(urlStr, fetchOptions);
    const text = await res.text();
    return {
      status: res.status,
      statusText: res.statusText,
      ok: res.ok,
      body: text,
    };
  }

  // Fallback for older environments without native fetch
  return new Promise((resolve, reject) => {
    const url = new URL(urlStr);
    const client = url.protocol === 'https:' ? https : http;
    const reqOptions = {
      method: options.method || 'GET',
      headers: options.headers || {},
      hostname: url.hostname,
      port: url.port || (url.protocol === 'https:' ? 443 : 80),
      path: `${url.pathname}${url.search}`,
    };

    const req = client.request(reqOptions, (res) => {
      let data = '';
      res.setEncoding('utf8');
      res.on('data', (chunk) => {
        data += chunk;
      });
      res.on('end', () => {
        resolve({
          status: res.statusCode || 0,
          statusText: res.statusMessage || '',
          ok: (res.statusCode || 0) >= 200 && (res.statusCode || 0) < 300,
          body: data,
        });
      });
    });

    req.on('error', reject);

    if (body !== null && body !== undefined && reqOptions.method !== 'GET') {
      req.write(body);
    }
    req.end();
  });
}

module.exports = {
  PARAMS_FILE,
  parseCliArgs,
  loadParams,
  saveParams,
  maskValue,
  maskSecrets,
  getPackageVersion,
  getCommitHash,
  setOutput,
  httpRequest,
};
