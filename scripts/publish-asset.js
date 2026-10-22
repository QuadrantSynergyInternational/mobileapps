#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const https = require('https');
const http = require('http');
const crypto = require('crypto');
const { execFileSync } = require('child_process');
const { parseCliArgs, httpRequest, maskValue } = require('./ci-helper');

async function sendCallback(domain, secret, jobId, payload) {
  const url = `https://${domain}/api/artifact-jobs/${encodeURIComponent(jobId)}/callback`;
  try {
    const res = await httpRequest(
      url,
      {
        method: 'POST',
        headers: {
          'X-AppCenter-Secret': secret,
          'Content-Type': 'application/json',
        },
      },
      JSON.stringify(payload)
    );

    if (!res.ok) {
      console.warn(`[publish-asset] Callback returned HTTP ${res.status}: ${res.statusText}`);
    } else {
      console.log(`[publish-asset] Successfully reported callback to AppCenter (HTTP ${res.status}).`);
    }
  } catch (err) {
    console.error(`[publish-asset] Network error while sending callback: ${err.message}`);
  }
}

function streamDownload(urlStr, destPath, maxRedirects = 5) {
  return new Promise((resolve, reject) => {
    if (maxRedirects < 0) {
      return reject(new Error('Too many redirects while downloading artifact'));
    }

    let parsedUrl;
    try {
      parsedUrl = new URL(urlStr);
    } catch (err) {
      return reject(new Error(`Invalid download URL: ${err.message}`));
    }

    const client = parsedUrl.protocol === 'https:' ? https : http;

    const req = client.get(urlStr, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        let redirectUrl = res.headers.location;
        if (!redirectUrl.startsWith('http://') && !redirectUrl.startsWith('https://')) {
          redirectUrl = new URL(redirectUrl, urlStr).toString();
        }
        res.resume();
        return streamDownload(redirectUrl, destPath, maxRedirects - 1).then(resolve, reject);
      }

      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error(`Failed to download artifact, HTTP status ${res.statusCode} ${res.statusMessage || ''}`));
      }

      const dir = path.dirname(destPath);
      if (!fs.existsSync(dir)) {
        fs.mkdirSync(dir, { recursive: true });
      }

      const fileStream = fs.createWriteStream(destPath);
      const hash = crypto.createHash('sha256');
      let bytesWritten = 0;

      res.on('data', (chunk) => {
        bytesWritten += chunk.length;
        hash.update(chunk);
      });

      res.pipe(fileStream);

      fileStream.on('finish', () => {
        fileStream.close(() => {
          resolve({
            bytesWritten,
            sha256: hash.digest('hex'),
          });
        });
      });

      fileStream.on('error', (err) => {
        fs.unlink(destPath, () => {});
        reject(err);
      });

      res.on('error', (err) => {
        fs.unlink(destPath, () => {});
        reject(err);
      });
    });

    req.on('error', reject);
  });
}

async function downloadWithRetry(urlStr, destPath, maxAttempts = 3) {
  let lastErr;
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      return await streamDownload(urlStr, destPath);
    } catch (err) {
      lastErr = err;
      if (attempt < maxAttempts) {
        console.warn(`[publish-asset] Download attempt ${attempt} failed: ${err.message}. Retrying in ${attempt}s...`);
        await new Promise((r) => setTimeout(r, attempt * 1000));
      }
    }
  }
  throw lastErr;
}

async function uploadToReleaseWithRetry(repository, releaseTag, filePath, filename, ghToken) {
  // Ensure release exists
  try {
    execFileSync('gh', ['release', 'view', releaseTag, '--repo', repository], {
      stdio: 'ignore',
      env: { ...process.env, GH_TOKEN: ghToken },
    });
  } catch {
    console.log(`[publish-asset] Creating release ${releaseTag} in ${repository}...`);
    execFileSync('gh', ['release', 'create', releaseTag, '--repo', repository, '--title', releaseTag], {
      stdio: 'ignore',
      env: { ...process.env, GH_TOKEN: ghToken },
    });
  }

  // Upload with retry
  for (let attempt = 1; attempt <= 3; attempt++) {
    try {
      console.log(`[publish-asset] Uploading ${filename} to ${repository}@${releaseTag} (attempt ${attempt})...`);
      execFileSync('gh', ['release', 'upload', releaseTag, filePath, '--repo', repository, '--clobber'], {
        stdio: 'ignore',
        env: { ...process.env, GH_TOKEN: ghToken },
      });
      break;
    } catch (err) {
      if (attempt === 3) {
        throw new Error(`Failed to upload ${filename} to release after 3 attempts: ${err.message}`);
      }
      console.warn(`[publish-asset] Upload attempt ${attempt} failed, pruning incomplete starter assets...`);
      try {
        const raw = execFileSync('gh', [
          'api',
          `/repos/${repository}/releases/tags/${releaseTag}`,
          '--jq',
          `.assets[] | select(.name == "${filename}" and (.state == "starter" or .size == 0)) | .id`,
        ], {
          encoding: 'utf8',
          stdio: ['ignore', 'pipe', 'ignore'],
          env: { ...process.env, GH_TOKEN: ghToken },
        }).trim();
        const ids = raw.split('\n').map((s) => s.trim()).filter(Boolean);
        for (const assetId of ids) {
          execFileSync('gh', ['api', '--method', 'DELETE', `/repos/${repository}/releases/assets/${assetId}`], {
            stdio: 'ignore',
            env: { ...process.env, GH_TOKEN: ghToken },
          });
        }
      } catch {
        // ignore cleanup error
      }
      await new Promise((r) => setTimeout(r, attempt * 1000));
    }
  }

  // Retrieve asset metadata
  const assetJson = execFileSync('gh', [
    'api',
    `/repos/${repository}/releases/tags/${releaseTag}`,
    '--jq',
    `.assets[] | select(.name == "${filename}") | {id, name, size, digest}`,
  ], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
    env: { ...process.env, GH_TOKEN: ghToken },
  }).trim();

  const lines = assetJson.split('\n').map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0) {
    throw new Error(`Asset ${filename} not found in release ${releaseTag} after upload`);
  }
  return JSON.parse(lines[lines.length - 1]);
}

async function main() {
  const args = parseCliArgs();
  const domain = process.env.APPCENTER_DOMAIN;
  const secret = process.env.APPCENTER_SECRET;
  const ghToken = process.env.GH_TOKEN || process.env.GH_PAT;
  const jobId = args['job-id'] || process.env.JOB_ID || '';

  if (!domain || !secret) {
    console.error('[publish-asset] Missing APPCENTER_DOMAIN or APPCENTER_SECRET in environment.');
    process.exit(1);
  }

  if (!jobId) {
    console.error('[publish-asset] Missing job-id.');
    process.exit(1);
  }

  // Handle failure/cancellation reporting mode
  if (args['report-failure'] || args['report-error']) {
    const jobStatus = String(args.status || process.env.JOB_STATUS || '').toLowerCase();
    const isCancelled =
      jobStatus === 'cancelled' ||
      String(args.cancelled).toLowerCase() === 'true';
    const errMsg = isCancelled
      ? 'GitHub Action publication cancelled'
      : (args.error || 'GitHub Action publication failed');
    console.log(`[publish-asset] Reporting failure to AppCenter: ${errMsg}`);
    await sendCallback(domain, secret, jobId, {
      success: false,
      error: errMsg,
    });
    return;
  }

  if (!ghToken) {
    console.error('[publish-asset] Missing GH_TOKEN or GH_PAT in environment.');
    process.exit(1);
  }

  console.log(`[publish-asset] Fetching metadata for job ${jobId}...`);
  const metaRes = await httpRequest(
    `https://${domain}/api/artifact-jobs/${encodeURIComponent(jobId)}`,
    {
      method: 'GET',
      headers: {
        'X-AppCenter-Secret': secret,
      },
    }
  );

  if (!metaRes.ok) {
    throw new Error(`Failed to fetch artifact job: HTTP ${metaRes.status} ${metaRes.statusText}`);
  }

  let parsed;
  try {
    parsed = JSON.parse(metaRes.body);
  } catch {
    throw new Error('AppCenter returned invalid JSON for artifact job');
  }

  const job = parsed.data;
  const required = ['id', 'repository', 'release_tag', 'filename', 'expected_size'];
  if (!job || required.some((k) => typeof job[k] !== 'string' && k !== 'expected_size')) {
    throw new Error('AppCenter returned invalid artifact job metadata');
  }
  if (typeof parsed.downloadUrl !== 'string' || !parsed.downloadUrl.startsWith('https://')) {
    throw new Error('AppCenter returned invalid artifact download URL');
  }

  // Mask downloadUrl in logs
  maskValue(parsed.downloadUrl);

  const destPath = path.join(process.cwd(), 'artifact', job.filename);
  console.log(`[publish-asset] Downloading ${job.filename} (${job.expected_size} bytes)...`);
  const downloadResult = await downloadWithRetry(parsed.downloadUrl, destPath);

  if (downloadResult.bytesWritten !== Number(job.expected_size)) {
    throw new Error(`Downloaded size ${downloadResult.bytesWritten} bytes did not match expected ${job.expected_size} bytes`);
  }

  if (job.sha256 && job.sha256.trim()) {
    if (downloadResult.sha256.toLowerCase() !== job.sha256.trim().toLowerCase()) {
      throw new Error(`Calculated SHA256 ${downloadResult.sha256} does not match expected ${job.sha256}`);
    }
  }

  console.log(`[publish-asset] Artifact verified: SHA256 ${downloadResult.sha256}`);
  const asset = await uploadToReleaseWithRetry(job.repository, job.release_tag, destPath, job.filename, ghToken);

  console.log(`[publish-asset] Upload verified: Asset ID ${asset.id}`);
  await sendCallback(domain, secret, jobId, {
    success: true,
    githubAssetId: String(asset.id),
    filename: asset.name,
    size: asset.size,
    sha256: downloadResult.sha256,
  });

  console.log('[publish-asset] Publication finished successfully.');
}

main().catch(async (err) => {
  console.error('[publish-asset] Error:', err.message);
  const args = parseCliArgs();
  const domain = process.env.APPCENTER_DOMAIN;
  const secret = process.env.APPCENTER_SECRET;
  const jobId = args['job-id'] || process.env.JOB_ID || '';

  if (domain && secret && jobId && !args['report-failure']) {
    try {
      await sendCallback(domain, secret, jobId, {
        success: false,
        error: `GitHub Action publication failed: ${err.message}`,
      });
    } catch (cbErr) {
      console.error('[publish-asset] Failed to send error callback:', cbErr.message);
    }
  }
  process.exit(1);
});
