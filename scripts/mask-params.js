#!/usr/bin/env node
const { loadParams, saveParams, maskSecrets } = require('./ci-helper');

try {
  const params = loadParams();
  maskSecrets(params);
  saveParams(params);
  console.log('[mask-params] Sensitive parameters masked successfully.');
} catch (err) {
  console.error('[mask-params] Error processing parameters:', err.message);
  process.exit(1);
}
