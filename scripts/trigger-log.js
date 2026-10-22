#!/usr/bin/env node
const {
  parseCliArgs,
  loadParams,
  getPackageVersion,
  getCommitHash,
  httpRequest,
} = require('./ci-helper');

async function main() {
  const args = parseCliArgs();
  const domain = process.env.APPCENTER_DOMAIN;
  const secret = process.env.APPCENTER_SECRET;

  if (!domain || !secret) {
    console.error('[trigger-log] Missing APPCENTER_DOMAIN or APPCENTER_SECRET in environment.');
    process.exit(1);
  }

  const params = loadParams();
  const projectId = args['project-id'] || params.projectid || params.project_id;
  if (!projectId) {
    console.error('[trigger-log] Missing project identifier.');
    process.exit(1);
  }

  const runId = args['run-id'] || process.env.GITHUB_RUN_ID || process.env.RUN_ID || '';
  const uniqueId = args['unique-id'] || params.uniqueId || '';
  const version = args.version || params.version || getPackageVersion('input') || '';
  const commitHash = args.commit || params.commit_hash || getCommitHash('input') || '';
  const platform = args.platform || params.platform || 'all';

  const formData = new URLSearchParams();
  formData.set('wf_id', String(runId));
  formData.set('params', typeof params === 'string' ? params : JSON.stringify(params));
  formData.set('uniqueId', String(uniqueId));
  formData.set('version', String(version));
  formData.set('commit_hash', String(commitHash));
  formData.set('platform', String(platform));

  const endpoint = `https://${domain}/projects/${encodeURIComponent(projectId)}/trigger-log`;
  try {
    const res = await httpRequest(
      endpoint,
      {
        method: 'POST',
        headers: {
          'X-AppCenter-Secret': secret,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
      },
      formData.toString()
    );

    if (!res.ok) {
      console.error(`[trigger-log] Request failed with HTTP ${res.status}: ${res.statusText}`);
      process.exit(1);
    }

    console.log(`[trigger-log] Logged workflow run to AppCenter (HTTP ${res.status}).`);
  } catch (err) {
    console.error('[trigger-log] Network error while logging workflow run:', err.message);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('[trigger-log] Unexpected error:', err.message);
  process.exit(1);
});
