#!/usr/bin/env node
const { execFileSync } = require('child_process');
const { parseCliArgs, loadParams } = require('./ci-helper');

function main() {
  const args = parseCliArgs();
  const params = loadParams();

  const branch = args.branch || params.branch;
  const repo = args.repo || params.repo;
  const targetDir = args.target || 'input';

  if (!branch || !repo) {
    console.error('[clone-repo] Missing branch or repo in parameters.');
    process.exit(1);
  }

  const username = process.env.GIT_USERNAME;
  const password = process.env.GIT_PASSWORD;

  const cleanRepo = repo.replace(/^https?:\/\//i, '').replace(/^[^@]+@/, '');
  const cloneUrl = `https://${cleanRepo}`;

  const authArgs = [];
  if (username && password) {
    const auth = Buffer.from(`${username}:${password}`).toString('base64');
    authArgs.push('-c', `http.extraheader=Authorization: Basic ${auth}`);
  }

  const gitArgs = [
    ...authArgs,
    'clone',
    '--depth=1',
    '--single-branch',
    '--branch',
    branch,
    cloneUrl,
    targetDir,
  ];

  console.log(`[clone-repo] Cloning branch "${branch}" into "${targetDir}"...`);
  try {
    execFileSync('git', gitArgs, {
      stdio: ['ignore', 'inherit', 'inherit'],
      env: {
        ...process.env,
        GIT_TERMINAL_PROMPT: '0',
      },
    });
    console.log(`[clone-repo] Successfully cloned repository into "${targetDir}".`);
  } catch {
    console.error(`[clone-repo] Failed to clone repository branch "${branch}".`);
    process.exit(1);
  }

  const targetCommit = args.commit || params.commit_hash;
  if (targetCommit) {
    console.log(`[clone-repo] Checking out target commit "${targetCommit}"...`);
    let currentHead = '';
    try {
      currentHead = execFileSync('git', ['-C', targetDir, 'rev-parse', 'HEAD'], {
        encoding: 'utf8',
        stdio: ['ignore', 'pipe', 'ignore'],
      }).trim();
    } catch {
      // ignore
    }

    if (currentHead && (currentHead === targetCommit || currentHead.startsWith(targetCommit))) {
      console.log(`[clone-repo] Target commit "${targetCommit}" is already checked out at HEAD.`);
      return;
    }

    try {
      execFileSync(
        'git',
        [...authArgs, '-C', targetDir, 'fetch', '--depth=1', 'origin', targetCommit],
        {
          stdio: ['ignore', 'inherit', 'inherit'],
          env: {
            ...process.env,
            GIT_TERMINAL_PROMPT: '0',
          },
        }
      );
      execFileSync('git', ['-C', targetDir, 'checkout', targetCommit], {
        stdio: ['ignore', 'inherit', 'inherit'],
      });
      console.log(`[clone-repo] Successfully checked out commit "${targetCommit}".`);
    } catch {
      try {
        execFileSync('git', ['-C', targetDir, 'checkout', targetCommit], {
          stdio: ['ignore', 'inherit', 'inherit'],
        });
        console.log(`[clone-repo] Successfully checked out local commit "${targetCommit}".`);
      } catch (err) {
        console.warn(`[clone-repo] Warning: Could not checkout commit "${targetCommit}": ${err.message}`);
      }
    }
  }
}

try {
  main();
} catch (err) {
  console.error('[clone-repo] Unexpected error:', err.message);
  process.exit(1);
}
