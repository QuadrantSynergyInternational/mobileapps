#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { parseCliArgs } = require('./ci-helper');

const SUPPORTED_MANAGERS = new Set(['pnpm', 'bun', 'yarn', 'npm']);
const MARKER_RULES = [
  { manager: 'pnpm', files: ['pnpm-workspace.yaml', 'pnpm-lock.yaml', '.pnpmfile.cjs'] },
  { manager: 'bun', files: ['bun.lock', 'bun.lockb', 'bunfig.toml'] },
];

/**
 * Parse a package.json `packageManager` field (e.g. "pnpm@9.15.0" or "yarn@4.5.1+sha512...").
 */
function parsePackageManagerField(rawValue) {
  if (typeof rawValue !== 'string') return null;
  const trimmed = rawValue.trim();
  if (!trimmed) return null;

  const match = trimmed.match(/^([a-zA-Z0-9_-]+)(?:@(.+))?$/);
  if (!match) return null;

  const manager = match[1].toLowerCase();
  if (!SUPPORTED_MANAGERS.has(manager)) return null;

  const rawVersion = match[2] ? match[2].trim() : null;
  const versionWithoutHash = rawVersion ? rawVersion.split('+')[0].trim() : null;
  const version = versionWithoutHash ? versionWithoutHash.replace(/^v/i, '') || null : null;

  return { manager, version, rawSpec: trimmed };
}

/**
 * Detect primary package manager for targetDir:
 * 1. `packageManager` in package.json
 * 2. pnpm-specific files (`pnpm-workspace.yaml`, `pnpm-lock.yaml`, `.pnpmfile.cjs`) -> pnpm
 * 3. bun-specific files (`bun.lock`, `bun.lockb`, `bunfig.toml`) -> bun
 * 4. fallback -> yarn
 */
function detectPackageManager(targetDir) {
  const pkgPath = path.join(targetDir, 'package.json');
  if (fs.existsSync(pkgPath)) {
    try {
      const pkg = JSON.parse(fs.readFileSync(pkgPath, 'utf8'));
      if (pkg && typeof pkg.packageManager === 'string' && pkg.packageManager.trim()) {
        const parsed = parsePackageManagerField(pkg.packageManager);
        if (parsed) {
          return { ...parsed, source: 'package.json#packageManager' };
        }
        console.warn(
          `[install-dependencies] Unsupported packageManager "${pkg.packageManager}" in package.json; falling back to repository file detection.`
        );
      }
    } catch (err) {
      console.warn(`[install-dependencies] Failed to parse package.json: ${err.message}`);
    }
  }

  for (const { manager, files } of MARKER_RULES) {
    const matched = files.find((file) => fs.existsSync(path.join(targetDir, file)));
    if (matched) {
      return { manager, version: null, rawSpec: null, source: matched };
    }
  }

  return { manager: 'yarn', version: null, rawSpec: null, source: 'default' };
}

function prependPath(env, dir) {
  if (!dir) return env;
  const current = env.PATH || '';
  const parts = current.split(path.delimiter).filter(Boolean);
  if (!parts.includes(dir)) {
    return {
      ...env,
      PATH: [dir, ...parts].join(path.delimiter),
    };
  }
  return env;
}

function appendGithubPath(dir) {
  const githubPath = process.env.GITHUB_PATH;
  if (!githubPath || !dir || !fs.existsSync(dir)) return;
  try {
    fs.appendFileSync(githubPath, `${dir}\n`, 'utf8');
  } catch (err) {
    console.warn(`[install-dependencies] Failed to update GITHUB_PATH: ${err.message}`);
  }
}

function isCommandAvailable(cmd, env) {
  const res = spawnSync(cmd, ['--version'], {
    stdio: 'ignore',
    env,
  });
  return res.status === 0;
}

function ensureCorepackManager(manager, version, env) {
  const nextEnv = {
    ...env,
    COREPACK_ENABLE_DOWNLOAD_PROMPT: '0',
  };

  if (isCommandAvailable('corepack', nextEnv)) {
    const enableRes = spawnSync('corepack', ['enable'], {
      stdio: 'inherit',
      env: nextEnv,
    });
    if (enableRes.status === 0) {
      return nextEnv;
    }

    // Fallback when global Node bin directory is not writable.
    const localBin = path.join(os.tmpdir(), 'ci-corepack-bin');
    fs.mkdirSync(localBin, { recursive: true });
    const localEnableRes = spawnSync(
      'corepack',
      ['enable', '--install-directory', localBin],
      { stdio: 'inherit', env: nextEnv }
    );
    if (localEnableRes.status === 0) {
      appendGithubPath(localBin);
      return prependPath(nextEnv, localBin);
    }
  }

  if (isCommandAvailable(manager, nextEnv)) {
    return nextEnv;
  }

  const pkgSpec = version ? `${manager}@${version}` : manager;
  console.log(`[install-dependencies] Corepack unavailable; installing ${pkgSpec} globally via npm...`);
  const npmInstallRes = spawnSync('npm', ['install', '-g', pkgSpec], {
    stdio: 'inherit',
    env: nextEnv,
  });
  if (npmInstallRes.status !== 0) {
    console.error(`[install-dependencies] Failed to install ${pkgSpec}.`);
    process.exit(npmInstallRes.status || 1);
  }
  return nextEnv;
}

function ensureBun(version, env) {
  const bunBinDir = path.join(os.homedir(), '.bun', 'bin');
  let nextEnv = fs.existsSync(bunBinDir) ? prependPath(env, bunBinDir) : { ...env };

  const verCheck = spawnSync('bun', ['--version'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    env: nextEnv,
  });
  const currentVersion = verCheck.status === 0 ? verCheck.stdout.trim() : null;

  if (!currentVersion || (version && currentVersion !== version)) {
    const label = version ? `bun@${version}` : 'bun';
    console.log(`[install-dependencies] Installing ${label}...`);

    const installCmd = version
      ? `curl -fsSL https://bun.sh/install | bash -s "bun-v${version}"`
      : 'curl -fsSL https://bun.sh/install | bash';
    const curlRes = spawnSync('bash', ['-c', installCmd], {
      stdio: 'inherit',
      env: nextEnv,
    });

    if (curlRes.status === 0 && fs.existsSync(bunBinDir)) {
      nextEnv = prependPath(nextEnv, bunBinDir);
      appendGithubPath(bunBinDir);
    } else {
      const npmSpec = version ? `bun@${version}` : 'bun';
      console.warn(`[install-dependencies] Official bun installer failed; falling back to npm install -g ${npmSpec}...`);
      const npmRes = spawnSync('npm', ['install', '-g', npmSpec], {
        stdio: 'inherit',
        env: nextEnv,
      });
      if (npmRes.status !== 0) {
        console.error(`[install-dependencies] Failed to install ${npmSpec}.`);
        process.exit(npmRes.status || 1);
      }
    }
  }

  return nextEnv;
}

function installDependencies(targetDir) {
  const detected = detectPackageManager(targetDir);
  const specLabel = detected.rawSpec || detected.manager;
  console.log(
    `[install-dependencies] Using "${specLabel}" (detected from ${detected.source}) in ${targetDir}`
  );

  let env = { ...process.env };
  if (detected.manager === 'bun') {
    env = ensureBun(detected.version, env);
  } else if (detected.manager === 'yarn' || detected.manager === 'pnpm') {
    env = ensureCorepackManager(detected.manager, detected.version, env);
  }

  const installRes = spawnSync(detected.manager, ['install'], {
    cwd: targetDir,
    stdio: 'inherit',
    env,
  });

  if (installRes.error) {
    console.error(`[install-dependencies] Failed to run "${detected.manager} install": ${installRes.error.message}`);
    process.exit(1);
  }
  if (installRes.status !== 0) {
    process.exit(installRes.status || 1);
  }
}

function main() {
  const args = parseCliArgs();
  const explicitDir = args.dir || args.target;
  const cwd = process.cwd();
  const inputDir = path.join(cwd, 'input');
  const targetDir = explicitDir
    ? path.resolve(cwd, explicitDir)
    : fs.existsSync(inputDir)
      ? inputDir
      : cwd;

  installDependencies(targetDir);
}

if (require.main === module) {
  main();
}

module.exports = {
  parsePackageManagerField,
  detectPackageManager,
};

