#!/usr/bin/env node
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { parseCliArgs, loadParams } = require('./ci-helper');

function normalizeCustomScripts(raw) {
  if (!raw) return [];
  let parsed = raw;
  if (typeof raw === 'string') {
    try {
      parsed = JSON.parse(raw);
    } catch {
      return [];
    }
  }
  if (Array.isArray(parsed)) {
    return parsed.filter(
      (item) =>
        item &&
        typeof item === 'object' &&
        typeof item.script === 'string' &&
        item.script.trim().length > 0
    );
  }
  if (typeof parsed === 'object' && parsed !== null) {
    const scripts = [];
    const hookKeys = ['after_clone', 'after_install', 'after_build'];
    for (const hook of hookKeys) {
      const val = parsed[hook];
      if (typeof val === 'string' && val.trim().length > 0) {
        scripts.push({
          id: `${hook}-default`,
          name: `${hook} script`,
          hook,
          script: val,
        });
      } else if (Array.isArray(val)) {
        val.forEach((item, idx) => {
          if (typeof item === 'string' && item.trim().length > 0) {
            scripts.push({
              id: `${hook}-${idx}`,
              name: `${hook} script ${idx + 1}`,
              hook,
              script: item,
            });
          } else if (
            item &&
            typeof item === 'object' &&
            typeof item.script === 'string' &&
            item.script.trim().length > 0
          ) {
            scripts.push({
              id: item.id || `${hook}-${idx}`,
              name: item.name || `${hook} script ${idx + 1}`,
              hook,
              script: item.script,
            });
          }
        });
      }
    }
    return scripts;
  }
  return [];
}

function main() {
  const args = parseCliArgs();
  const params = loadParams();

  const hook = args.hook || args.h;
  if (!hook) {
    console.error(
      '[run-custom-script] Missing required --hook argument (e.g. --hook after_clone, after_install, after_build)'
    );
    process.exit(1);
  }

  const allScripts = normalizeCustomScripts(params.custom_scripts);

  const fallbackKey = `custom_script_${hook}`;
  if (
    params[fallbackKey] &&
    typeof params[fallbackKey] === 'string' &&
    params[fallbackKey].trim().length > 0
  ) {
    allScripts.push({
      id: fallbackKey,
      name: `${hook} script`,
      hook,
      script: params[fallbackKey],
    });
  }

  const targetScripts = allScripts.filter(
    (s) => s.hook === hook && s.script && s.script.trim().length > 0
  );

  if (targetScripts.length === 0) {
    console.log(`[custom-script] No custom script configured for hook "${hook}". Skipping.`);
    return;
  }

  const workspaceRoot = process.cwd();
  const inputDir = path.join(workspaceRoot, 'input');
  const targetCwd = fs.existsSync(inputDir) ? inputDir : workspaceRoot;

  console.log(
    `[custom-script] Found ${targetScripts.length} script(s) for hook "${hook}". Working directory: ${targetCwd}`
  );

  for (let i = 0; i < targetScripts.length; i++) {
    const entry = targetScripts[i];
    const scriptName = entry.name || `Script #${i + 1}`;
    console.log(`\n======================================================`);
    console.log(
      `[custom-script] Executing "${scriptName}" for hook: ${hook} (${i + 1}/${targetScripts.length})`
    );
    console.log(`======================================================`);

    const tempFile = path.join(os.tmpdir(), `custom-script-${hook}-${Date.now()}-${i}.sh`);

    let scriptContent = entry.script.replace(/\r\n/g, '\n');
    if (!scriptContent.startsWith('#!')) {
      scriptContent = `#!/usr/bin/env bash\nset -e\n${scriptContent}`;
    }

    fs.writeFileSync(tempFile, scriptContent, { encoding: 'utf8', mode: 0o755 });

    const env = {
      ...process.env,
      HOOK_NAME: hook,
      SCRIPT_NAME: scriptName,
      PROJECT_ID: params.projectid || params.project_id || '',
      PLATFORM: params.platform || '',
      BRANCH: params.branch || '',
      CONFIGURATION: params.configuration || '',
      APP_DIR: targetCwd,
      WORKSPACE_DIR: workspaceRoot,
    };

    const result = spawnSync('bash', [tempFile], {
      cwd: targetCwd,
      stdio: 'inherit',
      env,
    });

    try {
      fs.unlinkSync(tempFile);
    } catch {
      // ignore
    }

    if (result.error) {
      console.error(`[custom-script] Failed to execute script "${scriptName}":`, result.error);
      process.exit(1);
    }

    if (result.status !== 0) {
      console.error(
        `[custom-script] Script "${scriptName}" failed with exit code ${result.status}`
      );
      process.exit(result.status || 1);
    }

    console.log(`[custom-script] Script "${scriptName}" completed successfully.`);
  }

  console.log(`\n[custom-script] All custom scripts for hook "${hook}" completed successfully.\n`);
}

main();

