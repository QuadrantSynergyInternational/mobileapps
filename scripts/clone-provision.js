#!/usr/bin/env node
const { execFileSync } = require('child_process');
const { parseCliArgs } = require('./ci-helper');

function main() {
  const args = parseCliArgs();
  const targetDir = args.target || 'provision';
  const branch = args.branch || 'main';
  const ghPat = process.env.GH_PAT;

  if (!ghPat) {
    console.error('[clone-provision] Missing GH_PAT secret in environment.');
    process.exit(1);
  }

  const auth = Buffer.from(`admindevopsqsi:${ghPat}`).toString('base64');
  const cloneUrl = 'https://github.com/admindevopsqsi/ios-provision.git';

  console.log(`[clone-provision] Cloning provision repository into "${targetDir}"...`);
  try {
    execFileSync(
      'git',
      [
        '-c',
        `http.extraheader=Authorization: Basic ${auth}`,
        'clone',
        '--depth=1',
        '--single-branch',
        '--branch',
        branch,
        cloneUrl,
        targetDir,
      ],
      {
        stdio: ['ignore', 'inherit', 'inherit'],
        env: {
          ...process.env,
          GIT_TERMINAL_PROMPT: '0',
        },
      }
    );
    console.log(`[clone-provision] Successfully cloned provision repository into "${targetDir}".`);
  } catch {
    console.error('[clone-provision] Failed to clone provision repository.');
    process.exit(1);
  }
}

try {
  main();
} catch (err) {
  console.error('[clone-provision] Unexpected error:', err.message);
  process.exit(1);
}
