#!/usr/bin/env node
const {
  parseCliArgs,
  loadParams,
  getCommitHash,
  httpRequest,
} = require('./ci-helper');

async function main() {
  const args = parseCliArgs();
  const domain = process.env.APPCENTER_DOMAIN;
  const secret = process.env.APPCENTER_SECRET;

  if (!domain || !secret) {
    console.error('[update-release] Missing APPCENTER_DOMAIN or APPCENTER_SECRET in environment.');
    process.exit(1);
  }

  const releaseId = args['release-id'] || args.r || args.id;
  if (!releaseId) {
    console.error('[update-release] Missing release ID (--release-id).');
    process.exit(1);
  }

  const params = loadParams();
  const projectId = args['project-id'] || params.projectid || params.project_id;
  if (!projectId) {
    console.error('[update-release] Missing project identifier.');
    process.exit(1);
  }

  const commitHash = args.commit || params.commit_hash || getCommitHash('input') || '';

  const searchParams = new URLSearchParams();
  searchParams.set('id', String(releaseId));
  if (commitHash) {
    searchParams.set('commit_hash', String(commitHash));
  }

  const endpoint = `https://${domain}/projects/${encodeURIComponent(projectId)}/release?${searchParams.toString()}`;

  try {
    const res = await httpRequest(endpoint, {
      method: 'POST',
      headers: {
        'X-AppCenter-Secret': secret,
      },
    });

    if (!res.ok) {
      console.error(`[update-release] Request failed with HTTP ${res.status}: ${res.statusText}`);
      process.exit(1);
    }

    console.log(`[update-release] AppCenter release record updated successfully (HTTP ${res.status}).`);
  } catch (err) {
    console.error('[update-release] Network error while updating release:', err.message);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('[update-release] Unexpected error:', err.message);
  process.exit(1);
});
