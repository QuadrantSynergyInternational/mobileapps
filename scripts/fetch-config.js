#!/usr/bin/env node
const {
  parseCliArgs,
  loadParams,
  saveParams,
  maskSecrets,
  setOutput,
  httpRequest,
} = require('./ci-helper');

async function main() {
  const args = parseCliArgs();
  const domain = process.env.APPCENTER_DOMAIN;
  const secret = process.env.APPCENTER_SECRET;

  if (!domain || !secret) {
    console.error('[fetch-config] Missing APPCENTER_DOMAIN or APPCENTER_SECRET in environment.');
    process.exit(1);
  }

  const initialParams = loadParams();
  const projectId = args['project-id'] || args.projectid || initialParams.projectid || initialParams.project_id;
  const branch = args.branch || initialParams.branch || '';
  const platform = args.platform || initialParams.platform || 'all';

  if (!projectId) {
    console.error('[fetch-config] Missing project identifier.');
    process.exit(1);
  }

  console.log(`[fetch-config] Fetching build configuration for project "${projectId}" (branch: "${branch}", platform: "${platform}")...`);

  const searchParams = new URLSearchParams();
  if (platform) searchParams.set('platform', platform);
  if (branch) searchParams.set('branch', branch);

  const endpoint = `https://${domain}/projects/${encodeURIComponent(projectId)}/buildparams?${searchParams.toString()}`;

  const res = await httpRequest(endpoint, {
    method: 'GET',
    headers: {
      'X-AppCenter-Secret': secret,
    },
  });

  if (!res.ok) {
    console.error(`[fetch-config] Failed to fetch buildparams: HTTP ${res.status} ${res.statusText}`);
    process.exit(1);
  }

  let config;
  try {
    config = JSON.parse(res.body);
  } catch {
    console.error('[fetch-config] AppCenter returned non-JSON buildparams response.');
    process.exit(1);
  }

  // Preserve any dispatch inputs (like uniqueId, buildMachine, etc.)
  const mergedParams = {
    ...initialParams,
    ...config,
    projectid: projectId,
    project_id: projectId,
  };

  let provisionFile = '';
  if (platform === 'ios' || mergedParams.platform === 'ios' || mergedParams.platform === 'all') {
    provisionFile =
      mergedParams.provisionfile && mergedParams.provisionfile !== ''
        ? mergedParams.provisionfile
        : mergedParams.branch || branch;

    if (provisionFile) {
      try {
        const provRes = await httpRequest(
          `https://${domain}/projects/${encodeURIComponent(projectId)}/provision?name=${encodeURIComponent(provisionFile)}.p12&details=true`,
          {
            method: 'GET',
            headers: {
              'X-AppCenter-Secret': secret,
            },
          }
        );
        if (provRes.ok) {
          const prov = JSON.parse(provRes.body);
          mergedParams._provision = prov;
          if (prov && prov.password) {
            mergedParams.p12pass = prov.password;
          }
        }
      } catch {
        // Non-fatal if provision details endpoint fails; fallback to git branch provision
      }
    }
  }

  // Mask all sensitive fields immediately
  maskSecrets(mergedParams);
  saveParams(mergedParams);

  // Set safe outputs for workflow conditionals
  setOutput('branch', mergedParams.branch || branch);
  setOutput('provision_file', provisionFile);
  setOutput('node', mergedParams.node || '');
  setOutput('java', mergedParams.java || '');
  setOutput('ndk', mergedParams.ndk || '');
  setOutput('flavor', mergedParams.flavor || '');
  setOutput('configuration', mergedParams.configuration || '');
  setOutput('unique_id', mergedParams.uniqueId || '');
  setOutput('project_id', projectId);
  setOutput('p12_password', mergedParams.p12pass || '');

  // Provide a sanitized JSON for workflow expression lookups without sensitive credentials
  const sanitized = { ...mergedParams };
  delete sanitized.p12pass;
  delete sanitized.p12_password;
  delete sanitized.keystorePassword;
  delete sanitized.keyPassword;
  delete sanitized.password;
  delete sanitized._provision;
  setOutput('params', JSON.stringify(sanitized));

  console.log('[fetch-config] Build configuration loaded, masked, and saved successfully.');
}

main().catch((err) => {
  console.error('[fetch-config] Unexpected error:', err.message);
  process.exit(1);
});
