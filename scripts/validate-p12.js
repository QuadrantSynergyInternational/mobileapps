#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { parseCliArgs, loadParams } = require('./ci-helper');

function main() {
  const args = parseCliArgs();
  const params = loadParams();

  const projectId = args['project-id'] || params.projectid || params.project_id;
  const provisionFile =
    args['provision-file'] ||
    (params.provisionfile && params.provisionfile !== '' ? params.provisionfile : params.branch);
  const p12Pass =
    args['p12-pass'] ||
    params.p12pass ||
    (params._provision && params._provision.password) ||
    '';

  if (!projectId || !provisionFile) {
    console.error('[validate-p12] Missing project ID or provision file name.');
    process.exit(1);
  }

  const p12Path = path.join(process.cwd(), 'provision', projectId, `${provisionFile}.p12`);
  if (!fs.existsSync(p12Path)) {
    console.error(`[validate-p12] P12 file not found at: provision/${projectId}/${provisionFile}.p12`);
    process.exit(1);
  }

  const keychainName = 'temp.keychain';
  console.log('[validate-p12] Validating P12 certificate...');

  try {
    // Clean up any stale keychain first
    try {
      execFileSync('security', ['delete-keychain', keychainName], { stdio: 'ignore' });
    } catch {
      // Ignore if doesn't exist
    }

    execFileSync('security', ['create-keychain', '-p', '', keychainName], { stdio: 'ignore' });
    execFileSync('security', ['unlock-keychain', '-p', '', keychainName], { stdio: 'ignore' });

    execFileSync(
      'security',
      [
        'import',
        p12Path,
        '-k',
        keychainName,
        '-P',
        p12Pass,
        '-T',
        '/usr/bin/codesign',
        '-T',
        '/usr/bin/security',
        '-T',
        '/usr/bin/productbuild',
        '-T',
        '/usr/bin/productsign',
      ],
      {
        stdio: 'ignore',
      }
    );

    console.log('[validate-p12] P12 certificate imported and validated successfully.');
  } catch {
    console.error('[validate-p12] Failed to import/validate P12 certificate.');
    process.exit(1);
  } finally {
    try {
      execFileSync('security', ['delete-keychain', keychainName], { stdio: 'ignore' });
    } catch {
      // Ignore cleanup error
    }
  }
}

try {
  main();
} catch (err) {
  console.error('[validate-p12] Unexpected error:', err.message);
  process.exit(1);
}
