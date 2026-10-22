#!/usr/bin/env node
const fs = require('fs');
const { parseCliArgs, loadParams, httpRequest } = require('./ci-helper');

async function main() {
  const args = parseCliArgs();
  const params = loadParams();

  const domain = process.env.APPCENTER_DOMAIN || 'appcenterq.vercel.app';
  const projectId = args['project-id'] || params.projectid || params.project_id;
  const branch = args.branch || params.branch || '';
  const outputFile = args.output || 'export.plist';

  if (!projectId) {
    console.error('[download-export-plist] Missing project identifier.');
    process.exit(1);
  }

  const endpoint = `https://${domain}/ios-export?projectid=${encodeURIComponent(projectId)}&branch=${encodeURIComponent(branch)}`;
  console.log(`[download-export-plist] Downloading export options plist...`);

  try {
    const res = await httpRequest(endpoint, { method: 'GET' });
    if (!res.ok) {
      console.error(`[download-export-plist] Failed to download export plist: HTTP ${res.status}`);
      process.exit(1);
    }

    fs.writeFileSync(outputFile, res.body, 'utf8');
    console.log(`[download-export-plist] Successfully saved export options to ${outputFile}.`);
  } catch (err) {
    console.error('[download-export-plist] Failed to download export plist:', err.message);
    process.exit(1);
  }
}

main().catch((err) => {
  console.error('[download-export-plist] Unexpected error:', err.message);
  process.exit(1);
});
