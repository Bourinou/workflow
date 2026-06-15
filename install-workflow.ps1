# Install-Workflow.ps1
# Script d'installation automatique pour le Workflow Multi-Agent 3D
#
# Ce script installe l'intégralité du visualiseur 3D, du script d'orchestration,
# des règles d'automatisation et configure les dépendances Node.js.

$ErrorActionPreference = "Stop"

function Write-Utf8NoBOM($path, $content) {
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))
}

# Définir le chemin cible par défaut (dossier scratch de l'utilisateur)
$userPath = [System.Environment]::GetFolderPath('UserProfile')
$targetDir = Join-Path $userPath "custom-workflow"
$installDir = Join-Path $targetDir "agent-workflow-visualizer"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  INSTALLATEUR WORKFLOW MULTI-AGENT ANTIGRAVITY & CLAUDE  " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Chemin d'installation : $installDir" -ForegroundColor Yellow

# 1. Créer la structure des dossiers
Write-Host "[1/6] Création des dossiers..." -ForegroundColor White
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $installDir "backend") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $installDir "frontend") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $installDir "frontend\src") | Out-Null

# 2. Créer le Script d'Orchestration
Write-Host "[2/6] Écriture de orchestrate.js..." -ForegroundColor White
$orchestrateContent = @'
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const http = require('http');
const crypto = require('crypto');

const args = {};
process.argv.slice(2).forEach(val => {
  const idx = val.indexOf('=');
  if (idx > -1) {
    const key = val.slice(0, idx).replace(/^--/, '');
    args[key] = val.slice(idx + 1);
  }
});

const projectPath = args.project ? path.resolve(args.project) : null;
const agent = args.agent || 'claude';
const node = args.node || '';
const task = args.task || null;
const status = args.status || 'coding';
const query = args.query || null;
const note = (args.note !== undefined) ? args.note : null;

if (!projectPath) {
  console.error("Error: --project parameter is required.");
  process.exit(1);
}

const mapPath = path.join(projectPath, '.agent-map.json');

function readMapSafe() {
  try { return JSON.parse(fs.readFileSync(mapPath, 'utf8')); }
  catch (e) { return null; }
}

// ---- QUERY MODE: read the map instead of re-reading project files (saves tokens) ----
if (query) {
  const map = readMapSafe();
  if (!map) {
    console.log("No agent map found yet. Launch the visualizer (init-workflow.bat) first.");
    process.exit(0);
  }
  if (query === 'summary') {
    console.log("=== Agent Map Summary ===");
    Object.entries(map.agents || {}).forEach(([agentName, data]) => {
      console.log(`${agentName}: ${data.currentNode || 'none'} [${data.status}]`);
    });
    const inProgress = (map.nodes || []).filter(n => n.status === 'in_progress').map(n => n.id);
    if (inProgress.length > 0) {
      console.log("In progress:");
      inProgress.forEach(f => console.log(` - ${f}`));
    }
    const done = (map.nodes || []).filter(n => n.status === 'done').map(n => n.id);
    if (done.length > 0) {
      console.log("Done:");
      done.forEach(f => console.log(` - ${f}`));
    }
    console.log("=========================");
  } else if (query === 'files') {
    console.log("=== Project Files ===");
    (map.nodes || []).filter(n => n.type !== 'folder').forEach(n => {
      console.log(`${n.id} (${n.status || 'idle'})`);
    });
    console.log("=====================");
  } else if (query === 'node') {
    const target = (map.nodes || []).find(n => n.id === node);
    if (!target) {
      console.log(`Node not found: ${node}`);
      process.exit(0);
    }
    const out = (map.links || []).filter(l => (l.source.id || l.source) === node && l.type === 'import').map(l => l.target.id || l.target);
    const inc = (map.links || []).filter(l => (l.target.id || l.target) === node && l.type === 'import').map(l => l.source.id || l.source);
    console.log(`=== Node: ${target.id} ===`);
    console.log(`Status: ${target.status || 'idle'}`);
    if (target.classes && target.classes.length) console.log(`Classes: ${target.classes.join(', ')}`);
    if (target.functions && target.functions.length) console.log(`Functions: ${target.functions.join(', ')}`);
    if (out.length) console.log(`Imports: ${out.join(', ')}`);
    if (inc.length) console.log(`Imported by: ${inc.join(', ')}`);
    if (target.info) console.log(`Notes: ${target.info}`);
    console.log("=====================");
  } else {
    console.log(`Unknown query option: ${query}`);
  }
  process.exit(0);
}

// ---- NOTE MODE: leave a short summary on a node so future agents skip re-reading the file ----
if (note !== null && node) {
  const map = readMapSafe();
  if (map) {
    const target = (map.nodes || []).find(n => n.id === node);
    if (target) {
      target.info = note;
      try { fs.writeFileSync(mapPath, JSON.stringify(map, null, 2), 'utf8'); } catch (e) {}
      console.log(`Note saved on ${node}.`);
    } else {
      console.log(`Node not found: ${node}`);
    }
  }

  // Save note globally
  try {
    const globalNotesDir = path.join(os.homedir(), 'custom-workflow');
    const globalNotesPath = path.join(globalNotesDir, 'global-notes.json');
    let globalNotes = {};
    if (fs.existsSync(globalNotesPath)) {
      try { globalNotes = JSON.parse(fs.readFileSync(globalNotesPath, 'utf8')); } catch (e) {}
    }
    const projKey = projectPath.replace(/\\/g, '/');
    if (!globalNotes[projKey]) globalNotes[projKey] = {};
    globalNotes[projKey][node] = note;
    if (!fs.existsSync(globalNotesDir)) {
      fs.mkdirSync(globalNotesDir, { recursive: true });
    }
    fs.writeFileSync(globalNotesPath, JSON.stringify(globalNotes, null, 2), 'utf8');
  } catch (e) {
    console.error("Failed to save global note:", e.message);
  }

  const postData = JSON.stringify({ node, info: note });
  const options = { hostname: 'localhost', port: 3001, path: '/api/note', method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) } };
  const req = http.request(options, () => process.exit(0));
  req.on('error', () => process.exit(0));
  req.write(postData);
  req.end();
  setTimeout(() => process.exit(0), 1500);
  return;
}

async function updateAgentState(agentName, currentNode, statusName) {
  const mapPath = path.join(projectPath, '.agent-map.json');
  if (fs.existsSync(mapPath)) {
    try {
      const map = JSON.parse(fs.readFileSync(mapPath, 'utf8'));
      if (!map.agents) map.agents = {};
      map.agents[agentName] = { currentNode, status: statusName, timestamp: Date.now() };
      
      const activeStatuses = ['coding', 'analyzing', 'thinking', 'planning'];
      if (activeStatuses.includes(statusName) && currentNode) {
        const targetNode = map.nodes.find(n => n.id === currentNode);
        if (targetNode) targetNode.status = 'in_progress';
      } else if (statusName === 'success' && currentNode) {
        const targetNode = map.nodes.find(n => n.id === currentNode);
        if (targetNode) targetNode.status = 'done';
      }
      fs.writeFileSync(mapPath, JSON.stringify(map, null, 2), 'utf8');
    } catch (e) {
      console.error("Failed to update local map:", e.message);
    }
  }

  const postData = JSON.stringify({ agent: agentName, currentNode, status: statusName });
  const options = {
    hostname: 'localhost',
    port: 3001,
    path: '/api/agent',
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) }
  };

  return new Promise((resolve) => {
    const req = http.request(options, () => resolve());
    req.on('error', () => resolve());
    req.write(postData);
    req.end();
  });
}

// Pre-accept Claude Code's workspace-trust dialog for this project (the real
// mechanism lives in ~/.claude.json, not settings.json), so the visible
// interactive window never stops to ask you to validate the folder.
function ensureTrusted(projPath) {
  try {
    const cfgPath = path.join(os.homedir(), '.claude.json');
    if (!fs.existsSync(cfgPath)) return;
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
    if (!cfg.projects) cfg.projects = {};

    // Normalize slashes and casing to register trust for all possible path formats
    const backslashPath = path.resolve(projPath).replace(/\//g, '\\');
    const forwardslashPath = backslashPath.replace(/\\/g, '/');
    
    const pathsToTrust = new Set();
    [backslashPath, forwardslashPath].forEach(p => {
      const drive = p.slice(0, 2);
      const rest = p.slice(2);
      pathsToTrust.add(drive.toUpperCase() + rest);
      pathsToTrust.add(drive.toLowerCase() + rest);
    });

    pathsToTrust.forEach(p => {
      const existing = cfg.projects[p] || {};
      cfg.projects[p] = Object.assign(
        {
          allowedTools: [],
          mcpContextUris: [],
          enabledMcpjsonServers: [],
          disabledMcpjsonServers: [],
          projectOnboardingSeenCount: 0,
          hasClaudeMdExternalIncludesApproved: false,
          hasClaudeMdExternalIncludesWarningShown: false
        },
        existing,
        { hasTrustDialogAccepted: true }
      );
    });

    fs.writeFileSync(cfgPath, JSON.stringify(cfg, null, 2), 'utf8');
  } catch (e) {
    console.error("[Orchestrator] Could not pre-trust project:", e.message);
  }
}

async function run() {
  if (agent !== 'claude') {
    await updateAgentState(agent, node, status);
  }
  if (!task) process.exit(0);

  ensureTrusted(projectPath);

  // orchestrate.js lives in the install dir; reference itself so Claude can self-report.
  const orchestratorPath = __filename.replace(/\\/g, '/');
  const safeProjectPath = projectPath.replace(/\\/g, '/');

  const prompt = `You are Claude Code, an expert software engineer acting as a delegated sub-agent in a multi-agent workflow orchestrated by Antigravity (Gemini).

=== TASK ===
${task}
=== END TASK ===

TARGET FILE: ${node || '(choose the right file from the task)'}

This project has a live 3D "agent map" that already knows every file, its functions/classes, its import connections and notes left by previous agents. Use the map to work efficiently instead of re-reading the whole codebase.

A human is watching a polished real-time dashboard (http://localhost:3000) that renders directly from the data you emit: your agent card shows your live status and the file you are on (purple = Claude). Keep that position accurate so the human can follow which file you are editing.

## Show your position on the map (you run these yourself — keep it MINIMAL)
You manage your own map presence; Antigravity will NOT do it for you. Do ONLY these three things, nothing else:
  1. When you START working, mark yourself coding on your first file:
     node "${orchestratorPath}" --project="${safeProjectPath}" --agent=claude --node="${node}" --status=coding
  2. Each time you move on to MODIFY A DIFFERENT file, rerun the same command with the new file path so the map follows you:
     node "${orchestratorPath}" --project="${safeProjectPath}" --agent=claude --node="<new/file/path>" --status=coding
  3. As your VERY LAST action before finishing, disconnect:
     node "${orchestratorPath}" --project="${safeProjectPath}" --agent=claude --node="" --status=disconnected
Do NOT emit any other status (no thinking / analyzing / planning) and do NOT run map commands for anything else — every extra call costs tokens.

## Optional: save tokens by querying the map instead of re-reading
Never open ".agent-map.json" directly (it is huge). If you would otherwise re-read a large file, you MAY query its functions/classes/imports/notes first (this does NOT move you on the map):
    node "${orchestratorPath}" --project="${safeProjectPath}" --query=node --node="<relative/path>"
Leaving a note is OPTIONAL — only do it if it will genuinely save a future agent from re-reading this file:
    node "${orchestratorPath}" --project="${safeProjectPath}" --agent=claude --node="${node}" --note="<one-line summary>"

## Rules
1. Focus on the TARGET FILE. Read other files only when the map shows you must (imports or callers). Do not create new files unless the task requires it.
2. Make complete, correct edits: no placeholders, no "// ... existing code", no omitted sections.
3. Permissions are pre-approved (this session runs with --dangerously-skip-permissions), so never pause to ask for confirmation.
4. Do not modify orchestrate.js, .agent-map.json or other workflow/metadata files unless the task explicitly says so.`;
  
  // Temp files live outside the project so they never pollute the map or git.
  const tmpBase = path.join(os.tmpdir(), 'agent-workflow');
  try { fs.mkdirSync(tmpBase, { recursive: true }); } catch (e) {}
  const tag = crypto.createHash('md5').update(projectPath).digest('hex').slice(0, 10);
  const promptFile = path.join(tmpBase, `prompt-${tag}.txt`);
  const exitFile = path.join(tmpBase, `exit-${tag}.txt`);
  const launchFile = path.join(tmpBase, `launch-${tag}.ps1`);

  try {
    fs.writeFileSync(promptFile, prompt, 'utf8');
  } catch (e) {
    console.error("Failed to write prompt file:", e.message);
  }
  if (fs.existsSync(exitFile)) {
    try { fs.unlinkSync(exitFile); } catch (e) {}
  }

  const model = args.model || 'sonnet';
  const q = s => String(s).replace(/'/g, "''");
  
  // Format the prompt as a single-line string and replace all double quotes with single quotes to prevent PowerShell command-line splitting bugs.
  const promptNoDoubleQuotes = prompt.replace(/"/g, "'");
  const escapedPrompt = promptNoDoubleQuotes.replace(/\r?\n/g, ' ').replace(/'/g, "''");
  const claudeExePath = path.join(os.homedir(), 'AppData', 'Roaming', 'npm', 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude.exe').replace(/\\/g, '/');

  // A small launcher script avoids fragile multi-level command-line quoting.
  const launchScript = [
    "$ErrorActionPreference = 'Continue'",
    `Set-Location -LiteralPath '${q(projectPath)}'`,
    `& '${claudeExePath}' --model ${model} --dangerously-skip-permissions '${escapedPrompt}'`,
    "$code = $LASTEXITCODE",
    "if ($null -eq $code) { $code = 0 }",
    `Set-Content -LiteralPath '${q(exitFile)}' -Value $code -Encoding ascii`,
    "Write-Host '---'",
    `Write-Host 'Tache Claude Code (${model}) terminee.' -ForegroundColor Green`,
    "Write-Host 'Cette fenetre se fermera dans 5 secondes...' -ForegroundColor Gray",
    "Start-Sleep 5"
  ].join("\r\n");

  try {
    fs.writeFileSync(launchFile, launchScript, 'utf8');
  } catch (e) {
    console.error("Failed to write launch script:", e.message);
  }

  // Show Claude on the map immediately at its target node.
  await updateAgentState('claude', node || null, 'thinking');

  console.log("[Orchestrator] Launching Claude Code in the background...");
  // Spawn powershell directly in the background (windowsHide: true) for full autonomy without prompts.
  const child = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', launchFile], {
    windowsHide: true,
    stdio: 'inherit'
  });

  child.on('close', async () => {
    let code = 1;
    if (fs.existsSync(exitFile)) {
      try {
        code = parseInt(fs.readFileSync(exitFile, 'utf8').trim(), 10);
        fs.unlinkSync(exitFile);
      } catch (e) {}
    }
    // Whatever happened, Claude ends up disconnected on the map.
    await updateAgentState('claude', null, 'disconnected');
  });
}
run();
'@
Write-Utf8NoBOM (Join-Path $installDir "orchestrate.js") $orchestrateContent

# 3. Écriture du Backend (parser.js, server.js, package.json)
Write-Host "[3/6] Configuration du Backend..." -ForegroundColor White

$parserContent = @'
const fs = require('fs');
const path = require('path');

function getRelativePath(absolutePath, rootPath) {
  return path.relative(rootPath, absolutePath).replace(/\\/g, '/');
}

function resolveImportPath(sourceFile, importPath, rootPath, existingFiles) {
  const sourceDir = path.dirname(path.resolve(rootPath, sourceFile));
  let resolvedAbs = path.resolve(sourceDir, importPath);
  const extensions = ['', '.js', '.jsx', '.ts', '.tsx', '.json'];
  for (const ext of extensions) {
    const testPath = resolvedAbs + ext;
    const rel = getRelativePath(testPath, rootPath);
    if (existingFiles.has(rel)) return rel;
    const indexRel = getRelativePath(path.join(resolvedAbs, 'index' + ext), rootPath);
    if (existingFiles.has(indexRel)) return indexRel;
  }
  return null;
}

function parseFile(filePath, rootPath) {
  const content = fs.readFileSync(filePath, 'utf8');
  const classes = [];
  const functions = [];

  const classRegex = /class\s+([a-zA-Z0-9_$]+)/g;
  let match;
  while ((match = classRegex.exec(content)) !== null) classes.push(match[1]);

  const funcRegex = /(?:function\s+([a-zA-Z0-9_$]+)|const\s+([a-zA-Z0-9_$]+)\s*=\s*(?:\([^)]*\)|[a-zA-Z0-9_$]+)\s*=>)/g;
  while ((match = funcRegex.exec(content)) !== null) {
    const name = match[1] || match[2];
    if (name && !['require', 'import', 'export'].includes(name)) functions.push(name);
  }

  return { classes, functions };
}

function loadGitignore(projectPath) {
  const gitignorePath = path.join(projectPath, '.gitignore');
  if (!fs.existsSync(gitignorePath)) {
    return () => false;
  }

  try {
    const content = fs.readFileSync(gitignorePath, 'utf8');
    const rules = content.split(/\r?\n/)
      .map(line => line.trim())
      .filter(line => line && !line.startsWith('#'));

    return (relPath, isDir) => {
      const cleanPath = relPath.replace(/\\/g, '/').replace(/^\//, '');
      const pathWithSlash = isDir ? cleanPath + '/' : cleanPath;

      for (const rule of rules) {
        let cleanRule = rule.replace(/\\/g, '/');
        if (!cleanRule) continue;
        
        const isRuleDir = cleanRule.endsWith('/');
        if (isRuleDir) {
          const ruleDir = cleanRule;
          if (pathWithSlash.startsWith(ruleDir) || pathWithSlash.includes('/' + ruleDir)) {
            return true;
          }
        } else {
          if (cleanRule.includes('*')) {
            const regexStr = '^' + cleanRule
              .replace(/\./g, '\\.')
              .replace(/\*/g, '.*')
              .replace(/\?/g, '.') + '$';
            try {
              const regex = new RegExp(regexStr, 'i');
              const filename = path.basename(cleanPath);
              if (regex.test(filename) || regex.test(cleanPath)) {
                return true;
              }
            } catch (e) {}
          } else {
            const parts = cleanPath.split('/');
            if (parts.some(p => p.toLowerCase() === cleanRule.toLowerCase())) {
              return true;
            }
          }
        }
      }
      return false;
    };
  } catch (e) {
    return () => false;
  }
}

function generateGraph(projectPath) {
  const absoluteRoot = path.resolve(projectPath);
  const nodes = [];
  const links = [];
  const existingFiles = new Set();
  const folderPaths = new Set();
  const isIgnored = loadGitignore(absoluteRoot);

  function walk(dir) {
    let files;
    try {
      files = fs.readdirSync(dir);
    } catch (e) {
      return;
    }
    const relDir = getRelativePath(dir, absoluteRoot);
    const folderId = `folder:${relDir}`;

    if (relDir && isIgnored(relDir, true)) {
      return;
    }

    if (!folderPaths.has(folderId)) {
      folderPaths.add(folderId);
      nodes.push({
        id: folderId,
        label: relDir ? path.basename(dir) : path.basename(absoluteRoot),
        type: 'folder'
      });

      if (relDir) {
        const parentDir = path.dirname(dir);
        const relParent = getRelativePath(parentDir, absoluteRoot);
        const parentFolderId = `folder:${relParent}`;
        links.push({
          source: parentFolderId,
          target: folderId,
          type: 'containment'
        });
      }
    }

    for (const file of files) {
      const fullPath = path.join(dir, file);
      let stat;
      try {
        stat = fs.statSync(fullPath);
      } catch (e) {
        continue;
      }
      if (stat.isDirectory()) {
        if (!['node_modules', '.git', 'dist', 'build', '.claude', '.gemini'].includes(file)) {
          const relSubDir = getRelativePath(fullPath, absoluteRoot);
          if (!isIgnored(relSubDir, true)) {
            walk(fullPath);
          }
        }
      } else {
        const relPath = getRelativePath(fullPath, absoluteRoot);
        if (isIgnored(relPath, false)) {
          continue;
        }

        const ext = path.extname(file);
        if (['.js', '.jsx', '.mjs', '.cjs', '.ts', '.tsx', '.mts', '.cts', '.vue', '.svelte', '.astro', '.coffee', '.py', '.rb', '.php', '.java', '.kt', '.kts', '.cs', '.go', '.rs', '.swift', '.c', '.cc', '.cpp', '.h', '.hpp', '.m', '.mm', '.scala', '.dart', '.lua', '.pl', '.pm', '.r', '.jl', '.groovy', '.gradle', '.clj', '.cljs', '.ex', '.exs', '.erl', '.hs', '.elm', '.nim', '.zig', '.html', '.htm', '.css', '.scss', '.sass', '.less', '.styl', '.twig', '.ejs', '.hbs', '.handlebars', '.mustache', '.pug', '.jade', '.liquid', '.json', '.json5', '.yaml', '.yml', '.toml', '.ini', '.env', '.cfg', '.conf', '.xml', '.sql', '.prisma', '.graphql', '.gql', '.proto', '.sh', '.bash', '.zsh', '.bat', '.cmd', '.ps1', '.dockerfile', '.tf', '.sol', '.vb', '.fs', '.md', '.mdx', '.rst', '.txt'].includes(ext.toLowerCase())) {
          existingFiles.add(relPath);

          let classes = [];
          let functions = [];
          try {
            const parsed = parseFile(fullPath, absoluteRoot);
            classes = parsed.classes;
            functions = parsed.functions;
          } catch (e) {}

          nodes.push({
            id: relPath,
            label: file,
            type: ext.substring(1),
            classes,
            functions,
            size: stat.size,
            lastModified: stat.mtimeMs
          });

          links.push({
            source: folderId,
            target: relPath,
            type: 'containment'
          });
        }
      }
    }
  }

  walk(absoluteRoot);

  // Extract import links
  for (const node of nodes) {
    if (node.type && ['js', 'jsx', 'ts', 'tsx'].includes(node.type.toLowerCase())) {
      try {
        const filePath = path.resolve(absoluteRoot, node.id);
        const content = fs.readFileSync(filePath, 'utf8');
        const importRegex = /from\s+['"]([^'"]+)['"]/g;
        let match;
        while ((match = importRegex.exec(content)) !== null) {
          const target = resolveImportPath(node.id, match[1], absoluteRoot, existingFiles);
          if (target) {
            links.push({ source: node.id, target, type: 'import' });
          }
        }
      } catch (e) {}
    }
  }

  // Restore statuses and info from existing .agent-map.json
  const mapPath = path.join(absoluteRoot, '.agent-map.json');
  let existingMap = { nodes: [], links: [], agents: {} };
  const mapExists = fs.existsSync(mapPath);
  if (mapExists) {
    try {
      existingMap = JSON.parse(fs.readFileSync(mapPath, 'utf8'));
    } catch (e) {}
  }

  // Load global notes
  let globalNotesForProj = {};
  try {
    const os = require('os');
    const globalNotesPath = path.join(os.homedir(), 'custom-workflow', 'global-notes.json');
    if (fs.existsSync(globalNotesPath)) {
      const globalNotes = JSON.parse(fs.readFileSync(globalNotesPath, 'utf8'));
      const projKey = absoluteRoot.replace(/\\/g, '/');
      globalNotesForProj = globalNotes[projKey] || {};
    }
  } catch (e) {
    console.error("Failed to read global notes in parser.js:", e.message);
  }

  const nodeStatusMap = new Map();
  const nodeInfoMap = new Map();
  if (existingMap.nodes) {
    existingMap.nodes.forEach(n => {
      if (n.status) nodeStatusMap.set(n.id, n.status);
      if (n.info !== undefined && n.info !== null) nodeInfoMap.set(n.id, n.info);
    });
  }

  nodes.forEach(node => {
    if (node.type !== 'folder') {
      node.status = nodeStatusMap.get(node.id) || 'idle';
      
      let noteVal = '';
      if (mapExists && nodeInfoMap.has(node.id)) {
        noteVal = nodeInfoMap.get(node.id);
      } else {
        noteVal = globalNotesForProj[node.id] || '';
      }
      node.info = noteVal;
    } else {
      node.status = 'idle';
    }
  });

  const agents = existingMap.agents || {
    antigravity: { currentNode: null, status: 'disconnected' },
    claude: { currentNode: null, status: 'disconnected' }
  };

  const finalMap = { nodes, links, agents };
  fs.writeFileSync(mapPath, JSON.stringify(finalMap, null, 2), 'utf8');
  return finalMap;
}

module.exports = { generateGraph };
'@
$serverContent = @'
const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const path = require('path');
const fs = require('fs');
const cors = require('cors');
const { generateGraph } = require('./parser');

const projectPathArg = process.argv[2];
if (!projectPathArg) process.exit(1);

const projectPath = path.resolve(projectPathArg);
const app = express();
app.use(cors());
app.use(express.json());

const server = http.createServer(app);
const wss = new WebSocket.Server({ server });
const mapPath = path.join(projectPath, '.agent-map.json');

try {
  if (fs.existsSync(mapPath)) {
    const map = JSON.parse(fs.readFileSync(mapPath, 'utf8'));
    if (map.agents) {
      Object.keys(map.agents).forEach(k => {
        map.agents[k].status = 'disconnected';
        map.agents[k].currentNode = null;
      });
      fs.writeFileSync(mapPath, JSON.stringify(map, null, 2), 'utf8');
    }
  }
} catch (e) {}

try { generateGraph(projectPath); } catch (e) {}

let watcher;
try {
  const chokidar = require('chokidar');
  watcher = chokidar.watch(projectPath, {
    ignored: [/node_modules/, /\.git/, /\.agent-map\.json/],
    persistent: true,
    ignoreInitial: true
  });
  let debounceTimer;
  watcher.on('all', () => {
    clearTimeout(debounceTimer);
    debounceTimer = setTimeout(() => {
      try {
        const graph = generateGraph(projectPath);
        broadcast({ type: 'GRAPH_UPDATE', data: graph });
      } catch (err) {}
    }, 500);
  });
  watcher.on('error', (error) => {
    if (error.code !== 'EPERM') console.error('Watcher error:', error.message);
  });
} catch (e) {
  fs.watch(projectPath, { recursive: true }, () => {
    try {
      const graph = generateGraph(projectPath);
      broadcast({ type: 'GRAPH_UPDATE', data: graph });
    } catch(err){}
  });
}

function readMap() { return JSON.parse(fs.readFileSync(mapPath, 'utf8')); }
function writeMap(mapData) { fs.writeFileSync(mapPath, JSON.stringify(mapData, null, 2), 'utf8'); }
function broadcast(message) {
  const msgStr = JSON.stringify(message);
  wss.clients.forEach(client => {
    if (client.readyState === WebSocket.OPEN) client.send(msgStr);
  });
}

app.get('/api/graph', (req, res) => {
  try {
    res.json(readMap());
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.post('/api/agent', (req, res) => {
  try {
    const { agent, currentNode, status } = req.body;
    const map = readMap();
    if (!map.agents) map.agents = {};
    map.agents[agent] = { currentNode, status, timestamp: Date.now() };
    const active = ['coding', 'analyzing', 'thinking', 'planning'];
    if (currentNode) {
      const target = (map.nodes || []).find(n => n.id === currentNode);
      if (target) {
        if (active.includes(status)) target.status = 'in_progress';
        else if (status === 'success') target.status = 'done';
      }
    }
    writeMap(map);
    // Broadcast the full graph so node colours AND agent positions update live.
    broadcast({ type: 'GRAPH_UPDATE', data: map });
    res.json(map.agents);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.post('/api/note', (req, res) => {
  try {
    const { node, info } = req.body;
    const map = readMap();
    const target = (map.nodes || []).find(n => n.id === node);
    if (target) {
      target.info = info;
      writeMap(map);
      broadcast({ type: 'GRAPH_UPDATE', data: map });
    }

    // Save note globally
    try {
      const os = require('os');
      const globalNotesDir = path.join(os.homedir(), 'custom-workflow');
      const globalNotesPath = path.join(globalNotesDir, 'global-notes.json');
      let globalNotes = {};
      if (fs.existsSync(globalNotesPath)) {
        try { globalNotes = JSON.parse(fs.readFileSync(globalNotesPath, 'utf8')); } catch (e) {}
      }
      const projKey = projectPath.replace(/\\/g, '/');
      if (!globalNotes[projKey]) globalNotes[projKey] = {};
      globalNotes[projKey][node] = info;
      if (!fs.existsSync(globalNotesDir)) {
        fs.mkdirSync(globalNotesDir, { recursive: true });
      }
      fs.writeFileSync(globalNotesPath, JSON.stringify(globalNotes, null, 2), 'utf8');
    } catch (e) {
      console.error("Failed to save global note in server.js:", e.message);
    }

    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/file-content', (req, res) => {
  try {
    const abs = path.resolve(projectPath, req.query.path);
    if (!fs.existsSync(abs)) {
      return res.json({ content: 'Le fichier n\'existe pas.' });
    }
    const stat = fs.statSync(abs);
    if (stat.isDirectory()) {
      return res.json({ content: '[Dossier]' });
    }
    res.json({ content: fs.readFileSync(abs, 'utf8') });
  } catch (e) {
    res.json({ content: `Erreur de lecture : ${e.message}` });
  }
});

wss.on('connection', ws => {
  try {
    ws.send(JSON.stringify({ type: 'GRAPH_UPDATE', data: readMap() }));
  } catch (e) {}
});

server.listen(3001, () => console.log('Server running on port 3001'));
'@

$pkgBackend = @'
{
  "name": "agent-workflow-visualizer-backend",
  "version": "1.0.0",
  "dependencies": {
    "cors": "^2.8.5",
    "express": "^4.19.2",
    "ws": "^8.17.0",
    "chokidar": "^3.6.0"
  }
}
'@

Write-Utf8NoBOM (Join-Path $installDir "backend\parser.js") $parserContent
Write-Utf8NoBOM (Join-Path $installDir "backend\server.js") $serverContent
Write-Utf8NoBOM (Join-Path $installDir "backend\package.json") $pkgBackend

# 4. Écriture du Frontend (Vite config, HTML, CSS, App.jsx, package.json)
Write-Host "[4/6] Configuration du Frontend..." -ForegroundColor White

$pkgFrontend = @'
{
  "name": "agent-workflow-visualizer-frontend",
  "scripts": {
    "dev": "vite"
  },
  "dependencies": {
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "react-force-graph-3d": "^1.24.3",
    "three": "^0.165.0",
    "lucide-react": "^0.395.0"
  },
  "devDependencies": {
    "@vitejs/plugin-react": "^4.3.0",
    "vite": "^5.2.11"
  }
}
'@

$viteConfig = @'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'
import { fileURLToPath } from 'url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

export default defineConfig({
  plugins: [react()],
  server: { port: 3000 },
  resolve: {
    alias: {
      'three$': path.resolve(__dirname, 'node_modules/three/build/three.module.js')
    }
  }
})
'@

$indexHtml = @'
<!doctype html>
<html lang="fr">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Agent Map 3D — Workflow Multi-Agent</title>
    <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><defs><radialGradient id='g' cx='30%25' cy='30%25'><stop offset='0%25' stop-color='%23c084fc'/><stop offset='100%25' stop-color='%237c3aed'/></radialGradient></defs><circle cx='16' cy='16' r='13' fill='url(%23g)'/></svg>" />
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Outfit:wght@600;700&family=Fira+Code:wght@400;500&display=swap" rel="stylesheet">
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
'@

$mainJsx = @'
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App.jsx'
import './index.css'
ReactDOM.createRoot(document.getElementById('root')).render(<App />)
'@

Write-Utf8NoBOM (Join-Path $installDir "frontend\package.json") $pkgFrontend
Write-Utf8NoBOM (Join-Path $installDir "frontend\vite.config.js") $viteConfig
Write-Utf8NoBOM (Join-Path $installDir "frontend\index.html") $indexHtml
Write-Utf8NoBOM (Join-Path $installDir "frontend\src\main.jsx") $mainJsx

$indexCss = @'
:root {
  --bg-primary: #000000;
  --bg-panel: rgba(12, 10, 18, 0.78);
  --bg-panel-soft: rgba(255, 255, 255, 0.03);
  --border-glass: rgba(255, 255, 255, 0.09);
  --border-strong: rgba(255, 255, 255, 0.18);
  --text-primary: #f4f4f5;
  --text-secondary: #a1a1aa;
  --text-faint: #71717a;
  --accent-claude: #a855f7;
  --accent-claude-soft: rgba(168, 85, 247, 0.13);
  --accent-claude-border: rgba(168, 85, 247, 0.4);
  --accent-antigravity: #10b981;
  --accent-antigravity-soft: rgba(16, 185, 129, 0.12);
  --accent-antigravity-border: rgba(16, 185, 129, 0.4);
  --warn: #fbbf24;
  --success: #34d399;
  --danger: #f87171;
  --font-sans: 'Inter', system-ui, sans-serif;
  --font-display: 'Outfit', 'Inter', sans-serif;
  --font-mono: 'Fira Code', 'Consolas', monospace;
}

* { box-sizing: border-box; }

body, html, #root {
  width: 100%;
  height: 100%;
  margin: 0;
  background: var(--bg-primary);
  color: var(--text-primary);
  font-family: var(--font-sans);
  overflow: hidden;
}

/* ---------- Scrollbars ---------- */
*::-webkit-scrollbar { width: 8px; height: 8px; }
*::-webkit-scrollbar-track { background: transparent; }
*::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.12); border-radius: 4px; }
*::-webkit-scrollbar-thumb:hover { background: rgba(168, 85, 247, 0.45); }

.app-container { display: flex; width: 100vw; height: 100vh; position: relative; }

.glass-panel {
  background: var(--bg-panel);
  backdrop-filter: blur(18px) saturate(1.3);
  -webkit-backdrop-filter: blur(18px) saturate(1.3);
  border: 1px solid var(--border-glass);
  border-radius: 14px;
  box-shadow: 0 16px 40px rgba(0, 0, 0, 0.55), inset 0 1px 0 rgba(255, 255, 255, 0.04);
}

/* ---------- Barre superieure ---------- */
.top-bar {
  position: absolute;
  top: 12px;
  left: 12px;
  right: 12px;
  z-index: 20;
  height: 54px;
  display: flex;
  align-items: center;
  gap: 14px;
  padding: 0 16px;
}
.brand { display: flex; align-items: center; gap: 10px; min-width: 0; }
.brand-logo {
  width: 28px;
  height: 28px;
  border-radius: 9px;
  background: radial-gradient(circle at 30% 30%, #c084fc, #7c3aed);
  box-shadow: 0 0 16px rgba(168, 85, 247, 0.55);
  display: grid;
  place-items: center;
  flex: none;
}
.brand-logo svg { display: block; }
.brand-text { display: flex; flex-direction: column; line-height: 1.1; }
.brand-title {
  font-family: var(--font-display);
  font-weight: 700;
  font-size: 0.92rem;
  letter-spacing: 0.02em;
  color: #ffffff;
  white-space: nowrap;
}
.brand-sub {
  font-size: 0.58rem;
  color: var(--text-faint);
  letter-spacing: 0.1em;
  text-transform: uppercase;
  white-space: nowrap;
}
.top-divider { width: 1px; height: 26px; background: var(--border-glass); flex: none; }
.project-chip {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 5px 11px;
  border-radius: 8px;
  background: var(--bg-panel-soft);
  border: 1px solid var(--border-glass);
  font-family: var(--font-mono);
  font-size: 0.7rem;
  color: var(--text-secondary);
  white-space: nowrap;
  max-width: 220px;
  overflow: hidden;
  text-overflow: ellipsis;
}
.project-chip .folder-glyph { color: var(--warn); font-size: 0.72rem; }

/* ---------- Recherche ---------- */
.search-box { position: relative; flex: 1; max-width: 400px; margin: 0 auto; min-width: 140px; }
.search-input {
  width: 100%;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid var(--border-glass);
  border-radius: 9px;
  padding: 8px 12px 8px 32px;
  color: var(--text-primary);
  font-family: var(--font-sans);
  font-size: 0.76rem;
  font-weight: 500;
  outline: none;
  transition: border-color 0.2s ease, box-shadow 0.2s ease, background 0.2s ease;
}
.search-input::placeholder { color: var(--text-faint); }
.search-input:focus {
  border-color: var(--accent-claude-border);
  box-shadow: 0 0 0 3px rgba(168, 85, 247, 0.14);
  background: rgba(168, 85, 247, 0.05);
}
.search-icon {
  position: absolute;
  left: 10px;
  top: 50%;
  transform: translateY(-50%);
  color: var(--text-faint);
  pointer-events: none;
  display: flex;
}
.search-results {
  position: absolute;
  top: calc(100% + 8px);
  left: 0;
  right: 0;
  max-height: 300px;
  overflow-y: auto;
  padding: 6px;
  z-index: 30;
}
.search-result {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 7px 9px;
  border-radius: 8px;
  cursor: pointer;
  transition: background 0.12s ease;
}
.search-result:hover { background: var(--accent-claude-soft); }
.search-result-text { min-width: 0; display: flex; flex-direction: column; }
.search-result-name { font-size: 0.74rem; font-weight: 600; color: var(--text-primary); }
.search-result-path {
  font-size: 0.62rem;
  color: var(--text-faint);
  font-family: var(--font-mono);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.search-empty { padding: 10px; font-size: 0.7rem; color: var(--text-faint); text-align: center; }
.type-dot { width: 9px; height: 9px; border-radius: 3px; flex: none; }

/* ---------- Stats et connexion ---------- */
.top-right { display: flex; align-items: center; gap: 16px; margin-left: auto; }
.top-stats { display: flex; gap: 16px; align-items: center; }
.stat { display: flex; flex-direction: column; align-items: center; line-height: 1.2; }
.stat-value { font-family: var(--font-display); font-size: 0.86rem; font-weight: 700; color: #ffffff; }
.stat-label { font-size: 0.55rem; text-transform: uppercase; letter-spacing: 0.09em; color: var(--text-faint); }
.conn-pill {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 5px 11px;
  border-radius: 99px;
  font-size: 0.66rem;
  font-weight: 600;
  border: 1px solid;
  white-space: nowrap;
}
.conn-pill.on { color: var(--success); border-color: rgba(16, 185, 129, 0.35); background: rgba(16, 185, 129, 0.08); }
.conn-pill.off { color: var(--danger); border-color: rgba(239, 68, 68, 0.35); background: rgba(239, 68, 68, 0.08); }
.conn-dot { width: 7px; height: 7px; border-radius: 50%; background: currentColor; flex: none; }
.conn-pill.on .conn-dot { animation: pulse-green 2s ease-in-out infinite; }

/* ---------- Colonne gauche (agents + masques) ---------- */
.left-column {
  position: absolute;
  top: 78px;
  left: 12px;
  z-index: 10;
  width: 252px;
  display: flex;
  flex-direction: column;
  gap: 10px;
  max-height: calc(100vh - 140px);
}
.agents-panel { padding: 12px; }
.panel-title {
  margin: 0 0 10px;
  font-size: 0.6rem;
  letter-spacing: 0.13em;
  text-transform: uppercase;
  color: var(--text-faint);
  font-weight: 700;
}
.agent-card {
  display: flex;
  gap: 10px;
  padding: 9px 10px;
  border-radius: 10px;
  border: 1px solid transparent;
  background: var(--bg-panel-soft);
  transition: border-color 0.3s ease, background 0.3s ease, box-shadow 0.3s ease;
}
.agent-card + .agent-card { margin-top: 8px; }
.agent-card.active.claude {
  border-color: var(--accent-claude-border);
  background: var(--accent-claude-soft);
  box-shadow: 0 0 22px rgba(168, 85, 247, 0.15);
}
.agent-card.active.antigravity {
  border-color: var(--accent-antigravity-border);
  background: var(--accent-antigravity-soft);
  box-shadow: 0 0 22px rgba(16, 185, 129, 0.13);
}
.agent-dot { width: 9px; height: 9px; border-radius: 50%; margin-top: 4px; flex: none; transition: background 0.3s ease; }
.agent-dot.claude { background: var(--accent-claude); }
.agent-dot.antigravity { background: var(--accent-antigravity); }
.agent-card.active .agent-dot.claude { animation: pulse-purple 1.6s ease-in-out infinite; }
.agent-card.active .agent-dot.antigravity { animation: pulse-green 1.6s ease-in-out infinite; }
.agent-card.offline .agent-dot { background: #52525b; }
.agent-info { display: flex; flex-direction: column; min-width: 0; flex: 1; }
.agent-name { color: var(--text-primary); font-size: 0.74rem; font-weight: 600; }
.agent-role { font-size: 0.58rem; color: var(--text-faint); margin-top: 1px; letter-spacing: 0.03em; }
.agent-status-label { font-size: 0.66rem; font-weight: 600; margin-top: 4px; color: var(--text-secondary); }
.agent-card.active.claude .agent-status-label { color: #c4b5fd; }
.agent-card.active.antigravity .agent-status-label { color: var(--success); }
.agent-file {
  font-family: var(--font-mono);
  font-size: 0.6rem;
  color: var(--text-secondary);
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  margin-top: 2px;
}

/* ---------- Panneau des noeuds masques ---------- */
.hidden-panel { padding: 10px 12px; animation: slide-down 0.2s ease-out; }
.hidden-panel-head {
  display: flex;
  justify-content: space-between;
  align-items: center;
  cursor: pointer;
  user-select: none;
}
.hidden-panel-head .panel-title { margin: 0; transition: color 0.15s ease; }
.hidden-panel-head:hover .panel-title { color: var(--text-secondary); }
.hidden-count {
  font-size: 0.6rem;
  font-weight: 700;
  color: var(--warn);
  background: rgba(251, 191, 36, 0.12);
  border: 1px solid rgba(251, 191, 36, 0.3);
  padding: 1px 7px;
  border-radius: 99px;
}
.hidden-body { margin-top: 10px; display: flex; flex-direction: column; gap: 6px; }
.show-all-btn {
  background: var(--accent-claude-soft);
  border: 1px solid var(--accent-claude-border);
  color: #c4b5fd;
  padding: 5px 8px;
  border-radius: 7px;
  cursor: pointer;
  font-family: var(--font-sans);
  font-size: 0.64rem;
  font-weight: 600;
  transition: background 0.15s ease, color 0.15s ease;
}
.show-all-btn:hover { background: rgba(168, 85, 247, 0.28); color: #ffffff; }
.hidden-list { max-height: 170px; overflow-y: auto; display: flex; flex-direction: column; gap: 4px; }
.hidden-item {
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: 6px;
  font-size: 0.66rem;
  background: var(--bg-panel-soft);
  padding: 4px 7px;
  border-radius: 6px;
  border: 1px solid rgba(255, 255, 255, 0.03);
}
.hidden-item-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  font-family: var(--font-mono);
  font-size: 0.62rem;
  color: var(--text-secondary);
}
.restore-btn {
  background: none;
  border: none;
  color: #c4b5fd;
  cursor: pointer;
  font-family: var(--font-sans);
  font-size: 0.62rem;
  font-weight: 600;
  padding: 1px 4px;
  flex: none;
  transition: color 0.15s ease;
}
.restore-btn:hover { color: #ffffff; text-decoration: underline; }

/* ---------- Sidebar de detail ---------- */
.sidebar {
  position: absolute;
  top: 78px;
  right: 12px;
  bottom: 12px;
  width: 430px;
  z-index: 15;
  padding: 16px;
  display: flex;
  flex-direction: column;
  gap: 12px;
  animation: slide-in-right 0.25s ease-out;
}
.sidebar-head { display: flex; justify-content: space-between; align-items: flex-start; gap: 10px; }
.sidebar-titles { min-width: 0; flex: 1; }
.sidebar-title {
  font-family: var(--font-display);
  font-size: 1.02rem;
  font-weight: 700;
  color: #ffffff;
  margin: 0;
  word-break: break-all;
  line-height: 1.25;
}
.sidebar-path {
  font-family: var(--font-mono);
  font-size: 0.64rem;
  color: var(--text-faint);
  margin-top: 3px;
  word-break: break-all;
}
.icon-btn {
  background: rgba(255, 255, 255, 0.06);
  border: 1px solid var(--border-glass);
  color: var(--text-secondary);
  width: 28px;
  height: 28px;
  border-radius: 8px;
  cursor: pointer;
  display: grid;
  place-items: center;
  font-size: 0.85rem;
  line-height: 1;
  flex: none;
  transition: color 0.15s ease, background 0.15s ease, border-color 0.15s ease;
}
.icon-btn:hover { color: #ffffff; border-color: var(--border-strong); background: rgba(255, 255, 255, 0.1); }
.meta-row { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.badge {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 3px 9px;
  border-radius: 99px;
  font-size: 0.64rem;
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.05em;
  border: 1px solid;
}
.badge.in_progress { background: rgba(245, 158, 11, 0.1); color: var(--warn); border-color: rgba(245, 158, 11, 0.3); }
.badge.done { background: rgba(16, 185, 129, 0.1); color: var(--success); border-color: rgba(16, 185, 129, 0.3); }
.badge.idle { background: rgba(148, 163, 184, 0.08); color: var(--text-secondary); border-color: rgba(148, 163, 184, 0.2); }
.chip {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  padding: 3px 9px;
  border-radius: 7px;
  font-size: 0.64rem;
  background: rgba(255, 255, 255, 0.05);
  border: 1px solid var(--border-glass);
  color: var(--text-secondary);
  font-family: var(--font-mono);
}
.chip-row { display: flex; flex-wrap: wrap; gap: 5px; }
.section-label {
  font-size: 0.58rem;
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--text-faint);
  font-weight: 700;
  margin: 2px 0 6px;
}
.btn {
  padding: 7px 13px;
  border-radius: 8px;
  font-family: var(--font-sans);
  font-size: 0.72rem;
  font-weight: 600;
  cursor: pointer;
  border: 1px solid;
  transition: background 0.15s ease, color 0.15s ease;
}
.btn-claude { background: var(--accent-claude-soft); border-color: var(--accent-claude-border); color: #c4b5fd; }
.btn-claude:hover { background: rgba(168, 85, 247, 0.3); color: #ffffff; }
.btn-danger { background: rgba(239, 68, 68, 0.1); border-color: rgba(239, 68, 68, 0.32); color: var(--danger); }
.btn-danger:hover { background: rgba(239, 68, 68, 0.24); color: #ffffff; }
.note-box {
  padding: 10px 12px;
  background: var(--accent-claude-soft);
  border: 1px solid var(--accent-claude-border);
  border-radius: 10px;
  font-size: 0.76rem;
  color: #ddd0f7;
  line-height: 1.5;
}
.note-box strong {
  color: var(--accent-claude);
  display: block;
  font-size: 0.58rem;
  text-transform: uppercase;
  letter-spacing: 0.1em;
  margin-bottom: 4px;
}
.code-block {
  flex: 1;
  min-height: 120px;
  font-family: var(--font-mono);
  font-size: 0.72rem;
  line-height: 1.6;
  background: rgba(0, 0, 0, 0.5);
  padding: 12px 14px;
  border-radius: 10px;
  border: 1px solid var(--border-glass);
  overflow: auto;
  white-space: pre;
  color: #e4e4e7;
}

/* ---------- Controles de vue ---------- */
.view-controls { position: absolute; left: 12px; bottom: 12px; z-index: 10; display: flex; gap: 8px; }
.view-btn {
  display: flex;
  align-items: center;
  gap: 7px;
  padding: 7px 12px;
  background: var(--bg-panel);
  backdrop-filter: blur(18px);
  border: 1px solid var(--border-glass);
  border-radius: 9px;
  color: var(--text-secondary);
  font-family: var(--font-sans);
  font-size: 0.68rem;
  font-weight: 600;
  cursor: pointer;
  transition: color 0.15s ease, border-color 0.15s ease, background 0.15s ease;
}
.view-btn:hover { color: #ffffff; border-color: var(--accent-claude-border); background: var(--accent-claude-soft); }

/* ---------- Aide navigation ---------- */
.help-hint {
  position: absolute;
  bottom: 16px;
  left: 50%;
  transform: translateX(-50%);
  z-index: 5;
  font-size: 0.62rem;
  color: var(--text-faint);
  letter-spacing: 0.02em;
  pointer-events: none;
  white-space: nowrap;
}
.help-hint b { color: var(--text-secondary); font-weight: 600; }

/* ---------- Etat vide ---------- */
.empty-state {
  position: absolute;
  inset: 0;
  display: grid;
  place-items: center;
  z-index: 5;
  pointer-events: none;
}
.empty-card { padding: 26px 34px; text-align: center; }
.spinner {
  width: 30px;
  height: 30px;
  margin: 0 auto 14px;
  border: 3px solid rgba(168, 85, 247, 0.18);
  border-top-color: var(--accent-claude);
  border-radius: 50%;
  animation: spin 0.9s linear infinite;
}
.empty-title { font-family: var(--font-display); font-size: 0.9rem; font-weight: 700; color: var(--text-primary); margin: 0 0 4px; }
.empty-sub { font-size: 0.7rem; color: var(--text-faint); margin: 0; }

/* ---------- Tooltip du graphe ---------- */
.graph-tooltip {
  transform: translate(-50%, -100%) translateY(-28px) !important;
  background: var(--bg-panel) !important;
  border: 1px solid var(--border-strong);
  border-radius: 9px;
  padding: 7px 11px !important;
  font-family: var(--font-sans) !important;
  font-size: 0.72rem !important;
  color: var(--text-primary) !important;
  backdrop-filter: blur(12px);
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.55);
}
.tip-name { font-weight: 600; color: #ffffff; }
.tip-sub { font-family: var(--font-mono); font-size: 0.62rem; color: var(--text-secondary); margin-top: 2px; }

/* ---------- Animations ---------- */
@keyframes spin { to { transform: rotate(360deg); } }
@keyframes slide-down {
  from { transform: translateY(-6px); opacity: 0; }
  to { transform: translateY(0); opacity: 1; }
}
@keyframes slide-in-right {
  from { transform: translateX(16px); opacity: 0; }
  to { transform: translateX(0); opacity: 1; }
}
@keyframes pulse-purple {
  0%, 100% { box-shadow: 0 0 0 0 rgba(168, 85, 247, 0.5); }
  50% { box-shadow: 0 0 0 6px rgba(168, 85, 247, 0); }
}
@keyframes pulse-green {
  0%, 100% { box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.5); }
  50% { box-shadow: 0 0 0 6px rgba(16, 185, 129, 0); }
}
'@

$appJsx = @'
import React, { useState, useEffect, useRef, useCallback } from 'react';
import ForceGraph3D from 'react-force-graph-3d';
import * as THREE from 'three';

const CLAUDE_COLOR = '#a855f7';
const ANTIGRAVITY_COLOR = '#10b981';

const TYPE_COLORS = {
  folder: '#fbbf24',
  js: '#eab308', jsx: '#eab308',
  ts: '#3b82f6', tsx: '#3b82f6',
  py: '#22c55e',
  cpp: '#0ea5e9', hpp: '#0ea5e9', h: '#0ea5e9', cc: '#0ea5e9', c: '#0ea5e9',
  java: '#ef4444',
  cs: '#a855f7',
  rs: '#ea580c',
  go: '#06b6d4',
  php: '#6366f1',
  swift: '#f05138',
  kt: '#7f52ff', kts: '#7f52ff',
  rb: '#cc342d',
  sh: '#4ade80', bat: '#4ade80', ps1: '#4ade80',
  sql: '#00758f',
  html: '#f97316', htm: '#f97316', xml: '#f97316',
  css: '#ec4899', scss: '#ec4899', sass: '#ec4899', less: '#ec4899', styl: '#ec4899',
  vue: '#42b883',
  svelte: '#ff3e00',
  astro: '#ff5d01',
  twig: '#8bbf2f',
  ejs: '#a91e50', hbs: '#f0772b', handlebars: '#f0772b', mustache: '#f0772b', pug: '#a86454', jade: '#a86454', liquid: '#67b8e3',
  dart: '#0095d5',
  lua: '#000080',
  scala: '#dc322f',
  ex: '#6e4a7e', exs: '#6e4a7e',
  graphql: '#e10098', gql: '#e10098',
  prisma: '#0c344b',
  toml: '#9c6b3c', ini: '#6b7280', env: '#d4b106', cfg: '#6b7280', conf: '#6b7280',
  json: '#64748b', json5: '#64748b', yaml: '#64748b', yml: '#64748b',
  md: '#94a3b8', mdx: '#94a3b8', rst: '#94a3b8', txt: '#94a3b8'
};

function typeColor(type) {
  return TYPE_COLORS[(type || '').toLowerCase()] || '#6366f1';
}

const AGENT_META = {
  antigravity: { name: 'Antigravity', role: 'Orchestrateur — Gemini', css: 'antigravity' },
  claude: { name: 'Claude Code', role: 'Développeur — Claude', css: 'claude' }
};

const AGENT_STATUS_LABELS = {
  coding: 'Écrit du code',
  thinking: 'Réfléchit',
  planning: 'Planifie',
  analyzing: 'Analyse',
  idle: 'En attente',
  success: 'Terminé',
  disconnected: 'Hors ligne'
};

const NODE_STATUS_LABELS = {
  in_progress: 'En cours',
  done: 'Terminé',
  idle: 'Inactif'
};

const ACTIVE_STATUSES = ['planning', 'thinking', 'analyzing', 'coding'];

function formatSize(bytes) {
  if (bytes === undefined || bytes === null) return null;
  if (bytes < 1024) return `${bytes} o`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} Ko`;
  return `${(bytes / (1024 * 1024)).toFixed(2)} Mo`;
}

function formatDate(ms) {
  if (!ms) return null;
  try {
    return new Date(ms).toLocaleString('fr-FR', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
  } catch (e) {
    return null;
  }
}

export default function App() {
  const [graphData, setGraphData] = useState({ nodes: [], links: [] });
  const [agents, setAgents] = useState({ antigravity: { currentNode: null, status: 'disconnected' }, claude: { currentNode: null, status: 'disconnected' } });
  const [selectedNode, setSelectedNode] = useState(null);
  const [fileContent, setFileContent] = useState('');
  const [transitionLinks, setTransitionLinks] = useState([]);
  const [glowingPaths, setGlowingPaths] = useState({ nodes: new Set(), links: new Set(), agent: null });
  const [isHiddenListOpen, setIsHiddenListOpen] = useState(false);
  const [wsConnected, setWsConnected] = useState(false);
  const [searchQuery, setSearchQuery] = useState('');
  const [hiddenNodes, setHiddenNodes] = useState(() => {
    try {
      const saved = localStorage.getItem('hiddenNodes');
      return saved ? new Set(JSON.parse(saved)) : new Set();
    } catch (e) {
      return new Set();
    }
  });

  const prevPositions = useRef({ antigravity: null, claude: null });
  const selectedNodeIdRef = useRef(null);
  const graphDataRef = useRef(graphData);
  const fgRef = useRef();
  const containerRef = useRef(null);
  const [dimensions, setDimensions] = useState({ width: window.innerWidth, height: window.innerHeight });

  useEffect(() => {
    const handleResize = () => {
      if (containerRef.current) {
        setDimensions({
          width: containerRef.current.clientWidth,
          height: containerRef.current.clientHeight
        });
      }
    };
    handleResize();
    window.addEventListener('resize', handleResize);
    window.addEventListener('fullscreenchange', handleResize);
    return () => {
      window.removeEventListener('resize', handleResize);
      window.removeEventListener('fullscreenchange', handleResize);
    };
  }, []);

  useEffect(() => {
    const onKeyDown = (e) => {
      if (e.key === 'Escape') {
        setSearchQuery('');
        setSelectedNode(null);
      }
    };
    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, []);

  const handleGraphMount = useCallback((instance) => {
    fgRef.current = instance;
    if (instance) {
      // Modify force parameters for a more stable layout
      instance.d3Force('charge').strength(-30);
      instance.d3Force('link').distance(40);
    }
  }, []);

  useEffect(() => {
    graphDataRef.current = graphData;
  }, [graphData]);

  useEffect(() => {
    try {
      localStorage.setItem('hiddenNodes', JSON.stringify(Array.from(hiddenNodes)));
    } catch (e) {}
  }, [hiddenNodes]);

  useEffect(() => {
    let ws;
    let reconnectTimer;

    function connect() {
      console.log('Connecting to WebSocket server...');
      ws = new WebSocket('ws://localhost:3001');

      ws.onopen = () => setWsConnected(true);

      ws.onmessage = (event) => {
        try {
          const msg = JSON.parse(event.data);
          if (msg.type === 'GRAPH_UPDATE') {
            setGraphData(prevData => {
              const existingNodeMap = new Map(prevData.nodes.map(n => [n.id, n]));
              const updatedNodes = msg.data.nodes.map(incomingNode => {
                const oldNode = existingNodeMap.get(incomingNode.id);
                if (oldNode) {
                  Object.assign(oldNode, incomingNode);
                  return oldNode;
                }
                return incomingNode;
              });

              const existingLinkMap = new Map(prevData.links.map(l => {
                const sId = l.source.id || l.source;
                const tId = l.target.id || l.target;
                return [`${sId}-${tId}`, l];
              }));

              const updatedLinks = msg.data.links.map(incomingLink => {
                const sId = incomingLink.source;
                const tId = incomingLink.target;
                const key = `${sId}-${tId}`;
                const oldLink = existingLinkMap.get(key);
                if (oldLink) {
                  const { source, target, ...rest } = incomingLink;
                  Object.assign(oldLink, rest);
                  return oldLink;
                }
                return incomingLink;
              });

              const result = {
                nodes: updatedNodes,
                links: updatedLinks,
                agents: msg.data.agents || prevData.agents
              };
              graphDataRef.current = result;
              return result;
            });

            if (msg.data.agents) {
              updateAgentsAndTransitions(msg.data.agents);
            }
          } else if (msg.type === 'AGENT_UPDATE') {
            updateAgentsAndTransitions(msg.data);
          }
        } catch (err) {
          console.error('Error parsing WebSocket message:', err);
        }
      };

      ws.onclose = () => {
        console.log('WebSocket connection closed. Reconnecting in 2s...');
        setWsConnected(false);
        reconnectTimer = setTimeout(connect, 2000);
      };

      ws.onerror = (err) => {
        console.error('WebSocket error:', err);
        ws.close();
      };
    }

    connect();

    return () => {
      if (ws) ws.close();
      clearTimeout(reconnectTimer);
    };
  }, []);

  const getContainmentPath = useCallback((targetId) => {
    const nodesOnPath = [targetId];
    const linksOnPath = [];

    let currentId = targetId;
    let limit = 20;
    while (currentId && currentId !== 'folder:' && limit > 0) {
      limit--;
      const parentLink = graphDataRef.current?.links?.find(link => {
        const sourceId = link.source.id || link.source;
        const targetId = link.target.id || link.target;
        return link.type === 'containment' && targetId === currentId;
      });

      if (parentLink) {
        linksOnPath.push(parentLink);
        const nextId = parentLink.source.id || parentLink.source;
        nodesOnPath.push(nextId);
        currentId = nextId;
      } else {
        break;
      }
    }
    return { nodes: nodesOnPath, links: linksOnPath };
  }, []);

  const updateAgentsAndTransitions = (newAgents) => {
    setAgents(newAgents);

    Object.entries(newAgents).forEach(([name, data]) => {
      const prev = prevPositions.current[name];
      const curr = data.currentNode;

      if (curr !== prev) {
        if (curr) {
          const pathInfo = getContainmentPath(curr);
          setGlowingPaths({
            nodes: new Set(pathInfo.nodes),
            links: new Set(pathInfo.links.map(l => l.id || `${l.source.id || l.source}-${l.target.id || l.target}`)),
            agent: name
          });

          setTimeout(() => {
            setGlowingPaths(prevGlow => {
              if (prevGlow.agent === name) {
                return { nodes: new Set(), links: new Set(), agent: null };
              }
              return prevGlow;
            });
          }, 1500);
        }

        if (prev && curr) {
          const nodesList = graphDataRef.current?.nodes || [];
          const fromExists = nodesList.some(n => n.id === prev);
          const toExists = nodesList.some(n => n.id === curr);

          if (fromExists && toExists) {
            const transitionId = `${name}-${prev}-${curr}-${Date.now()}`;
            const newLink = {
              id: transitionId,
              source: prev,
              target: curr,
              type: 'transition',
              agent: name
            };
            setTransitionLinks(prevLinks => [...prevLinks, newLink]);

            setTimeout(() => {
              setTransitionLinks(prevLinks => prevLinks.filter(l => l.id !== transitionId));
            }, 1000);
          }
        }
        prevPositions.current[name] = curr;
      }
    });
  };

  useEffect(() => {
    selectedNodeIdRef.current = selectedNode ? selectedNode.id : null;
    if (selectedNode) {
      if (selectedNode.type === 'folder') {
        const cleanPath = selectedNode.id.replace(/^folder:/, '');
        const folderDisplayName = cleanPath || selectedNode.label || 'Racine';
        setFileContent(`[Dossier] ${folderDisplayName}\n\nCe nœud représente un répertoire de votre projet. Les fichiers et sous-répertoires qu'il contient y sont reliés visuellement.`);
      } else {
        setFileContent('Chargement du contenu...');
        const targetId = selectedNode.id;
        fetch(`http://localhost:3001/api/file-content?path=${encodeURIComponent(targetId)}`)
          // Lire en texte d'abord : si le backend (port 3001) est injoignable, la
          // requête peut retomber sur la page Vite (HTML) et casser un res.json() direct.
          .then(res => res.text().then(text => ({ ok: res.ok, ct: res.headers.get('content-type') || '', text })))
          .then(({ ok, ct, text }) => {
            if (selectedNodeIdRef.current !== targetId) return; // l'utilisateur a déjà cliqué ailleurs
            if (!ok) {
              setFileContent("Le serveur n'a pas pu lire ce fichier (réponse " + (ct.includes('json') ? 'invalide' : 'inattendue') + ').');
              return;
            }
            if (!ct.includes('application/json')) {
              setFileContent("Backend injoignable sur le port 3001.\nVérifiez que init-workflow.bat est bien lancé, puis recliquez sur le fichier.");
              return;
            }
            try {
              const data = JSON.parse(text);
              setFileContent(data.content || '');
            } catch (e) {
              setFileContent('Réponse illisible du serveur : ' + e.message);
            }
          })
          .catch(() => {
            if (selectedNodeIdRef.current !== targetId) return;
            setFileContent("Impossible de joindre le serveur sur http://localhost:3001.\nLe visualiseur (init-workflow.bat) est-il toujours actif ?");
          });
      }
    }
  }, [selectedNode]);

  const focusNode = useCallback((node) => {
    const fg = fgRef.current;
    if (!fg || node.x === undefined) return;
    const dist = 120;
    const len = Math.hypot(node.x, node.y, node.z) || 1;
    const ratio = 1 + dist / len;
    fg.cameraPosition(
      { x: node.x * ratio, y: node.y * ratio, z: node.z * ratio },
      node,
      1000
    );
  }, []);

  const resetView = useCallback(() => {
    const fg = fgRef.current;
    if (fg) fg.zoomToFit(800, 60);
  }, []);

  const hideNodeAndChildren = (nodeId) => {
    const toHide = new Set(hiddenNodes);

    const collectChildren = (id) => {
      toHide.add(id);
      graphData.links.forEach(link => {
        const sourceId = link.source.id || link.source;
        const targetId = link.target.id || link.target;
        if (link.type === 'containment' && sourceId === id) {
          if (!toHide.has(targetId)) {
            collectChildren(targetId);
          }
        }
      });
    };

    collectChildren(nodeId);
    setHiddenNodes(toHide);
    setSelectedNode(null);
  };

  const showAllNodes = () => {
    setHiddenNodes(new Set());
  };

  const restoreNode = (nodeId) => {
    const nextHidden = new Set(hiddenNodes);
    nextHidden.delete(nodeId);
    setHiddenNodes(nextHidden);
  };

  const customNodeObject = useCallback((node) => {
    const group = new THREE.Group();

    let activeAgent = null;
    Object.entries(agents).forEach(([name, data]) => {
      if (data.currentNode === node.id) {
        activeAgent = name;
      }
    });

    const isFolder = node.type === 'folder';
    const isRoot = node.id === 'folder:';
    const size = isFolder ? (isRoot ? 14 : 10) : Math.max(3, Math.min(10, Math.log2((node.size || 1000) / 100) * 1.5));

    const isGlowingNode = glowingPaths.nodes.has(node.id);
    const glowingColor = glowingPaths.agent === 'antigravity' ? ANTIGRAVITY_COLOR : CLAUDE_COLOR;

    if (isFolder) {
      const outerGeo = new THREE.BoxGeometry(size, size, size);
      const outerMat = new THREE.MeshBasicMaterial({
        color: isGlowingNode ? glowingColor : (isRoot ? '#3b82f6' : '#fbbf24'),
        wireframe: true,
        transparent: true,
        opacity: isGlowingNode ? 0.8 : (isRoot ? 0.65 : 0.35)
      });
      const box = new THREE.Mesh(outerGeo, outerMat);
      group.add(box);

      const innerGeo = new THREE.SphereGeometry(isRoot ? 3.5 : 2.5, 8, 8);
      const innerMat = new THREE.MeshBasicMaterial({
        color: isGlowingNode ? glowingColor : (isRoot ? '#1d4ed8' : '#d97706'),
        transparent: true,
        opacity: 0.8
      });
      const innerCore = new THREE.Mesh(innerGeo, innerMat);
      group.add(innerCore);

      if (isGlowingNode) {
        const haloGeo = new THREE.SphereGeometry(size + 3, 16, 16);
        const haloMat = new THREE.MeshBasicMaterial({
          color: glowingColor,
          transparent: true,
          opacity: 0.25,
          blending: THREE.AdditiveBlending
        });
        const halo = new THREE.Mesh(haloGeo, haloMat);
        group.add(halo);

        const pointLight = new THREE.PointLight(glowingColor, 3, 25, 0.6);
        pointLight.position.set(0, 0, 0);
        group.add(pointLight);
      }
    } else {
      const geometry = new THREE.SphereGeometry(size, 16, 16);
      let nodeColor = '#64748b';

      if (node.status === 'in_progress') {
        nodeColor = '#fbbf24';
      } else if (node.status === 'done') {
        nodeColor = '#10b981';
      } else {
        nodeColor = typeColor(node.type);
      }

      const material = new THREE.MeshPhongMaterial({
        color: isGlowingNode ? glowingColor : nodeColor,
        transparent: true,
        opacity: 0.85,
        shininess: 100
      });
      const sphere = new THREE.Mesh(geometry, material);
      group.add(sphere);

      if (isGlowingNode) {
        const haloGeo = new THREE.SphereGeometry(size + 3, 16, 16);
        const haloMat = new THREE.MeshBasicMaterial({
          color: glowingColor,
          transparent: true,
          opacity: 0.25,
          blending: THREE.AdditiveBlending
        });
        const halo = new THREE.Mesh(haloGeo, haloMat);
        group.add(halo);

        const pointLight = new THREE.PointLight(glowingColor, 3, 25, 0.6);
        pointLight.position.set(0, 0, 0);
        group.add(pointLight);
      }

    }

    if (activeAgent) {
      const haloGeo = new THREE.SphereGeometry(isFolder ? 12 : size + 4, 16, 16);
      const haloColor = activeAgent === 'antigravity' ? ANTIGRAVITY_COLOR : CLAUDE_COLOR;
      const haloMat = new THREE.MeshBasicMaterial({
        color: haloColor,
        transparent: true,
        opacity: 0.25,
        blending: THREE.AdditiveBlending
      });
      const halo = new THREE.Mesh(haloGeo, haloMat);
      group.add(halo);

      const pointLight = new THREE.PointLight(haloColor, 4, 35, 0.6);
      pointLight.position.set(0, 0, 0);
      group.add(pointLight);
    }

    return group;
  }, [agents, glowingPaths]);

  const visibleNodes = React.useMemo(() => {
    return graphData.nodes.filter(n => !hiddenNodes.has(n.id));
  }, [graphData.nodes, hiddenNodes]);

  const visibleLinks = React.useMemo(() => {
    const combinedLinks = [...graphData.links, ...transitionLinks];
    return combinedLinks.filter(link => {
      const sourceId = link.source.id || link.source;
      const targetId = link.target.id || link.target;
      return !hiddenNodes.has(sourceId) && !hiddenNodes.has(targetId);
    });
  }, [graphData.links, transitionLinks, hiddenNodes]);

  const memoizedGraphData = React.useMemo(() => ({
    nodes: visibleNodes,
    links: visibleLinks
  }), [visibleNodes, visibleLinks]);

  const stats = React.useMemo(() => {
    const files = graphData.nodes.filter(n => n.type !== 'folder').length;
    const folders = graphData.nodes.filter(n => n.type === 'folder').length;
    return { files, folders };
  }, [graphData.nodes]);

  const projectName = React.useMemo(() => {
    const root = graphData.nodes.find(n => n.id === 'folder:');
    return root ? root.label : null;
  }, [graphData.nodes]);

  const searchResults = React.useMemo(() => {
    const q = searchQuery.trim().toLowerCase();
    if (!q) return null;
    return graphData.nodes
      .filter(n => !hiddenNodes.has(n.id))
      .filter(n => (n.id || '').toLowerCase().includes(q) || (n.label || '').toLowerCase().includes(q))
      .slice(0, 8);
  }, [searchQuery, graphData.nodes, hiddenNodes]);

  const selectSearchResult = (node) => {
    setSelectedNode(node);
    focusNode(node);
    setSearchQuery('');
  };

  const renderAgentCard = (key) => {
    const meta = AGENT_META[key];
    const data = agents[key] || { status: 'disconnected', currentNode: null };
    const isActive = ACTIVE_STATUSES.includes(data.status);
    const isOffline = !data.status || data.status === 'disconnected';
    return (
      <div key={key} className={`agent-card ${meta.css} ${isActive ? 'active' : ''} ${isOffline ? 'offline' : ''}`}>
        <div className={`agent-dot ${meta.css}`} />
        <div className="agent-info">
          <span className="agent-name">{meta.name}</span>
          <span className="agent-role">{meta.role}</span>
          <span className="agent-status-label">{AGENT_STATUS_LABELS[data.status] || data.status}</span>
          {data.currentNode && (
            <span className="agent-file" title={data.currentNode}>
              {data.currentNode.replace(/^folder:/, '') || 'racine'}
            </span>
          )}
        </div>
      </div>
    );
  };

  const selectedFunctions = React.useMemo(() => {
    if (!selectedNode || !selectedNode.functions) return [];
    return Array.from(new Set(selectedNode.functions));
  }, [selectedNode]);

  const selectedClasses = React.useMemo(() => {
    if (!selectedNode || !selectedNode.classes) return [];
    return Array.from(new Set(selectedNode.classes));
  }, [selectedNode]);

  return (
    <div className="app-container">
      {/* Barre superieure : marque, projet, recherche, stats, connexion */}
      <header className="top-bar glass-panel">
        <div className="brand">
          <div className="brand-logo">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="#ffffff" strokeWidth="2.2" strokeLinecap="round">
              <circle cx="5" cy="12" r="2.4" />
              <circle cx="19" cy="6" r="2.4" />
              <circle cx="19" cy="18" r="2.4" />
              <path d="M7.2 11l9.4-4M7.2 13l9.4 4" />
            </svg>
          </div>
          <div className="brand-text">
            <span className="brand-title">Agent Map 3D</span>
            <span className="brand-sub">Workflow multi-agent</span>
          </div>
        </div>
        {projectName && (
          <>
            <div className="top-divider" />
            <div className="project-chip" title={projectName}>
              <span className="folder-glyph">▣</span>
              {projectName}
            </div>
          </>
        )}

        <div className="search-box">
          <span className="search-icon">
            <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round">
              <circle cx="11" cy="11" r="7" />
              <path d="M21 21l-4.3-4.3" />
            </svg>
          </span>
          <input
            className="search-input"
            type="text"
            placeholder="Rechercher un fichier ou un dossier…"
            value={searchQuery}
            onChange={e => setSearchQuery(e.target.value)}
          />
          {searchResults && (
            <div className="search-results glass-panel">
              {searchResults.length === 0 && (
                <div className="search-empty">Aucun résultat pour « {searchQuery} »</div>
              )}
              {searchResults.map(node => {
                const isFolder = node.type === 'folder';
                const name = isFolder
                  ? (node.id.replace(/^folder:/, '').split('/').pop() || node.label)
                  : node.id.split('/').pop();
                return (
                  <div key={node.id} className="search-result" onClick={() => selectSearchResult(node)}>
                    <span className="type-dot" style={{ background: typeColor(node.type) }} />
                    <div className="search-result-text">
                      <span className="search-result-name">{name}</span>
                      <span className="search-result-path">{isFolder ? `Dossier — ${node.id.replace(/^folder:/, '') || 'racine'}` : node.id}</span>
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>

        <div className="top-right">
          <div className="top-stats">
            <div className="stat">
              <span className="stat-value">{stats.files}</span>
              <span className="stat-label">Fichiers</span>
            </div>
            <div className="stat">
              <span className="stat-value">{stats.folders}</span>
              <span className="stat-label">Dossiers</span>
            </div>
          </div>
          <div className={`conn-pill ${wsConnected ? 'on' : 'off'}`}>
            <span className="conn-dot" />
            {wsConnected ? 'Temps réel' : 'Reconnexion…'}
          </div>
        </div>
      </header>

      {/* Colonne gauche : agents + noeuds masques */}
      <div className="left-column">
        <div className="agents-panel glass-panel">
          <h3 className="panel-title">Statut des agents</h3>
          {renderAgentCard('antigravity')}
          {renderAgentCard('claude')}
        </div>

        {hiddenNodes.size > 0 && (
          <div className="hidden-panel glass-panel">
            <div className="hidden-panel-head" onClick={() => setIsHiddenListOpen(!isHiddenListOpen)}>
              <h3 className="panel-title">{isHiddenListOpen ? '▾' : '▸'} Nœuds masqués</h3>
              <span className="hidden-count">{hiddenNodes.size}</span>
            </div>
            {isHiddenListOpen && (
              <div className="hidden-body">
                <button onClick={showAllNodes} className="show-all-btn">Tout réafficher</button>
                <div className="hidden-list">
                  {Array.from(hiddenNodes).map(id => {
                    const node = graphData.nodes.find(n => n.id === id);
                    if (!node) return null;
                    const name = node.type === 'folder'
                      ? (node.id.replace(/^folder:/, '') || node.label)
                      : node.id.split('/').pop();
                    return (
                      <div key={id} className="hidden-item">
                        <span className="hidden-item-name" style={{ color: node.type === 'folder' ? '#fbbf24' : undefined }} title={node.id}>
                          {name}
                        </span>
                        <button onClick={() => restoreNode(id)} className="restore-btn">Restaurer</button>
                      </div>
                    );
                  })}
                </div>
              </div>
            )}
          </div>
        )}
      </div>

      <div ref={containerRef} style={{ flex: 1, width: '100%', height: '100%' }}>
        <ForceGraph3D
          ref={handleGraphMount}
          showNavInfo={false}
          graphData={memoizedGraphData}
          width={dimensions.width}
          height={dimensions.height}
          d3AlphaDecay={0.08}
          d3VelocityDecay={0.6}
          nodeThreeObject={customNodeObject}
          nodeLabel={n => {
            if (n.type === 'folder') {
              const cleanPath = n.id.replace(/^folder:/, '');
              return `<div><div class="tip-name">${cleanPath || n.label}</div><div class="tip-sub">Dossier</div></div>`;
            }
            return `<div><div class="tip-name">${n.label}</div><div class="tip-sub">${n.id}</div></div>`;
          }}
          onNodeClick={n => setSelectedNode(n)}
          backgroundColor="#000000"
          linkColor={link => {
            const linkId = link.id || `${link.source.id || link.source}-${link.target.id || link.target}`;
            if (glowingPaths.links.has(linkId)) {
              return glowingPaths.agent === 'antigravity' ? ANTIGRAVITY_COLOR : CLAUDE_COLOR;
            }
            if (link.type === 'transition') {
              return link.agent === 'antigravity' ? ANTIGRAVITY_COLOR : CLAUDE_COLOR;
            }
            if (link.type === 'import') return '#7dd3fc';
            return '#94a3b8';
          }}
          linkWidth={link => {
            const linkId = link.id || `${link.source.id || link.source}-${link.target.id || link.target}`;
            if (glowingPaths.links.has(linkId)) return 3.5;
            if (link.type === 'transition') return 3.0;
            return link.type === 'containment' ? 0.6 : 1.8;
          }}
          linkDirectionalParticles={link => {
            const linkId = link.id || `${link.source.id || link.source}-${link.target.id || link.target}`;
            if (glowingPaths.links.has(linkId)) return 6;
            if (link.type === 'transition') return 8;
            return link.type === 'containment' ? 0 : 3;
          }}
          linkDirectionalParticleWidth={link => {
            const linkId = link.id || `${link.source.id || link.source}-${link.target.id || link.target}`;
            if (glowingPaths.links.has(linkId)) return 3.5;
            if (link.type === 'transition') return 4.0;
            return 1.8;
          }}
          linkDirectionalParticleSpeed={link => {
            const linkId = link.id || `${link.source.id || link.source}-${link.target.id || link.target}`;
            if (glowingPaths.links.has(linkId)) return 0.025;
            if (link.type === 'transition') return 0.02;
            return 0.005;
          }}
        />
      </div>

      {/* Etat vide pendant l'attente du serveur */}
      {visibleNodes.length === 0 && (
        <div className="empty-state">
          <div className="empty-card glass-panel">
            <div className="spinner" />
            <p className="empty-title">{wsConnected ? 'Analyse du projet…' : 'Connexion au serveur…'}</p>
            <p className="empty-sub">{wsConnected ? 'Construction de la carte des fichiers.' : 'Vérifiez que init-workflow.bat est lancé.'}</p>
          </div>
        </div>
      )}

      {/* Controles de vue */}
      <div className="view-controls">
        <button className="view-btn" onClick={resetView} title="Recadrer la vue sur l'ensemble du graphe">
          <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round">
            <path d="M3 9V5a2 2 0 0 1 2-2h4M15 3h4a2 2 0 0 1 2 2v4M21 15v4a2 2 0 0 1-2 2h-4M9 21H5a2 2 0 0 1-2-2v-4" />
          </svg>
          Recentrer la vue
        </button>
      </div>

      {!selectedNode && (
        <div className="help-hint">
          <b>Glisser</b> : pivoter &nbsp;·&nbsp; <b>Molette</b> : zoom &nbsp;·&nbsp; <b>Clic sur un nœud</b> : détails
        </div>
      )}

      {/* Sidebar de detail du noeud selectionne */}
      {selectedNode && (
        <aside className="sidebar glass-panel">
          <div className="sidebar-head">
            <div className="sidebar-titles">
              <h3 className="sidebar-title">
                {selectedNode.type === 'folder'
                  ? (selectedNode.id.replace(/^folder:/, '').split('/').pop() || selectedNode.label)
                  : selectedNode.id.split('/').pop()}
              </h3>
              <div className="sidebar-path">
                {selectedNode.type === 'folder' ? (selectedNode.id.replace(/^folder:/, '') || '(racine du projet)') : selectedNode.id}
              </div>
            </div>
            <button className="icon-btn" onClick={() => setSelectedNode(null)} title="Fermer (Échap)">✕</button>
          </div>

          <div className="meta-row">
            <span className={`badge ${selectedNode.status || 'idle'}`}>
              {NODE_STATUS_LABELS[selectedNode.status] || selectedNode.status || 'Inactif'}
            </span>
            <span className="chip">
              <span className="type-dot" style={{ background: typeColor(selectedNode.type) }} />
              {selectedNode.type === 'folder' ? 'dossier' : `.${selectedNode.type}`}
            </span>
            {formatSize(selectedNode.size) && <span className="chip">{formatSize(selectedNode.size)}</span>}
            {formatDate(selectedNode.lastModified) && <span className="chip">Modifié : {formatDate(selectedNode.lastModified)}</span>}
          </div>

          <div className="meta-row">
            <button className="btn btn-claude" onClick={() => focusNode(selectedNode)}>Centrer la caméra</button>
            <button className="btn btn-danger" onClick={() => hideNodeAndChildren(selectedNode.id)}>Masquer</button>
          </div>

          {selectedNode.info && (
            <div className="note-box">
              <strong>Note de l'agent</strong>
              {selectedNode.info}
            </div>
          )}

          {selectedClasses.length > 0 && (
            <div>
              <div className="section-label">Classes ({selectedClasses.length})</div>
              <div className="chip-row">
                {selectedClasses.slice(0, 16).map(c => <span key={c} className="chip">{c}</span>)}
                {selectedClasses.length > 16 && <span className="chip">+{selectedClasses.length - 16}</span>}
              </div>
            </div>
          )}

          {selectedFunctions.length > 0 && (
            <div>
              <div className="section-label">Fonctions ({selectedFunctions.length})</div>
              <div className="chip-row">
                {selectedFunctions.slice(0, 20).map(f => <span key={f} className="chip">{f}()</span>)}
                {selectedFunctions.length > 20 && <span className="chip">+{selectedFunctions.length - 20}</span>}
              </div>
            </div>
          )}

          <div style={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 }}>
            <div className="section-label">Contenu</div>
            <div className="code-block">
              <code>{fileContent || 'Chargement...'}</code>
            </div>
          </div>
        </aside>
      )}
    </div>
  );
}
'@
Write-Utf8NoBOM (Join-Path $installDir "frontend\src\index.css") $indexCss
Write-Utf8NoBOM (Join-Path $installDir "frontend\src\App.jsx") $appJsx

# 5. Créer les règles globales (.antigravityrules) dans le dossier User
Write-Host "[5/6] Configuration des fichiers de règles automatiques globaux..." -ForegroundColor White

$rulesTemplate = @'
# Antigravity Rules - Multi-Agent Workflow & 3D Node Map (Token-Optimized)
You are the Orchestrator (Antigravity / Gemini) for this workspace. For any coding task, follow this exact workflow.

## 1. Start the visualizer
- Assume the 3D visualizer is NOT running. ALWAYS run the `init-workflow.bat` at the project root first. It launches the backend + frontend, and opens the live 3D map at http://localhost:3000.
- Folder trust and tool permissions for Claude Code are handled automatically at launch via `--dangerously-skip-permissions` (pre-approved in `~/.claude.json` by `orchestrate.js`).
- The page at http://localhost:3000 is a polished real-time dashboard: top bar with file search and live file/folder counts; agent panel showing status and current file (green = Antigravity, purple = Claude); detail panel (opened by clicking a node/search result) showing status badge, size, exports, and agent notes. Everything renders live from status/notes emitted via `orchestrate.js`. If "Backend injoignable / port 3001" is shown, re-run `init-workflow.bat`.

## 2. Track yourself on the map (MANDATORY)
- Start status is `disconnected`. Go online immediately at start:
  `node "INSTALL_DIR\orchestrate.js" --project="[WORKSPACE_PATH]" --agent=antigravity --node="" --status=idle`
- On every read, think, plan, or edit, update status and node path:
  `node "INSTALL_DIR\orchestrate.js" --project="[WORKSPACE_PATH]" --agent=antigravity --node="[RELATIVE_FILE_PATH]" --status=[STATUS]`
- Status values:
  - `planning`: creating/updating checklists or plans (e.g. implementation_plan.md, task.md).
  - `thinking`: reasoning, brainstorming, researching.
  - `analyzing`: reading files, searching directories, analyzing code structure.
  - `coding`: editing files, running tests, writing code.
  - `idle`: waiting for input, or finished.
- Node updates trigger a glowing light (green for Antigravity, purple for Claude) and path flow animation (~1.5s).
- When waiting or finished, set `idle` with `--node=""` (Do not set `disconnected` manually).

## 3. Save tokens with the map (MANDATORY)
- NEVER open `.agent-map.json` directly (thousands of lines). Query it instead:
- NEVER open `orchestrate.js` — GEMINI.md fully describes it; re-reading wastes tokens.
  - Understand exports, classes, imports, and notes for ONE file:
    `node "INSTALL_DIR\orchestrate.js" --project="[WORKSPACE_PATH]" --query=node --node="[RELATIVE_FILE_PATH]"`
  - High-level overview of all agents and active/done files:
    `node "INSTALL_DIR\orchestrate.js" --project="[WORKSPACE_PATH]" --query=summary`
  - List every file and its status:
    `node "INSTALL_DIR\orchestrate.js" --project="[WORKSPACE_PATH]" --query=files`
- Critical Note Usage Guidelines:
  - ALWAYS READ NOTES FIRST: Before opening/reading any source file, you MUST query the node note using `query=node`.
  - TRUST THE NOTES: If a note describes file behavior, exports, or changes, assume it is correct and build around it without re-reading.

## 4. Delegate code changes to Claude Code
- For ANY code modification, refactor, or file creation, do NOT write the code yourself. Delegate:
  `node "INSTALL_DIR\orchestrate.js" --project="[WORKSPACE_PATH]" --agent=claude --node="[RELATIVE_FILE_PATH]" --task="[VERY DETAILED TASK]"`
- Model: defaults to Sonnet. Add `--model=opus` only for complex work. Task must be extremely detailed (what to do, constraints, no `=` or `"` in task text).
- BLOCKING: command holds terminal until Claude finishes. Don't poll or add timers — just wait. Set your own status=idle before launching.
- Claude behavior: Permissions pre-approved; Claude manages its own status and disconnects on finish — NEVER set Claude's status yourself.

## 5. Record notes to help the next agent (saves tokens later)
- After any change, save a 1-line summary note on the file's node:
  `node "INSTALL_DIR\orchestrate.js" --project="[WORKSPACE_PATH]" --agent=antigravity --node="[RELATIVE_FILE_PATH]" --note="[concise summary]"`
- Critical Note Saving Guidelines:
  - MANDATORY NOTE SAVING: You MUST write a note for every file you modify or create.
  - WHAT TO INCLUDE: Specific, concise 1-line note (functions/classes exported, queried DB tables, logic). Example: `Exports validateUser() and authMiddleware() for JWT verification.`
  - PERSISTENCE: Saved locally in `.agent-map.json` and globally in `%USERPROFILE%\custom-workflow\global-notes.json` (persists across resets).

'@
$rulesContent = $rulesTemplate.Replace('INSTALL_DIR', $installDir)

# Écrire dans le profil utilisateur global
Write-Utf8NoBOM (Join-Path $userPath ".antigravityrules") $rulesContent
Write-Utf8NoBOM (Join-Path $targetDir ".antigravityrules") $rulesContent

# Créer le plugin global pour Antigravity
$pluginDir = Join-Path $userPath ".gemini\config\plugins\multi-agent-orchestrator"
New-Item -ItemType Directory -Force -Path (Join-Path $pluginDir "rules") | Out-Null
$pluginManifest = @'
{
  "name": "multi-agent-orchestrator",
  "version": "1.0.0",
  "description": "Orchestrates multi-agent workflow using local Claude Code CLI and updates the 3D Node Map.",
  "author": { "name": "Dimitri Pape" },
  "license": "Apache-2.0"
}
'@
Write-Utf8NoBOM (Join-Path $pluginDir "plugin.json") $pluginManifest
Write-Utf8NoBOM (Join-Path $pluginDir "rules\orchestration-rules.md") $rulesContent

# Créer le script d'initialisation automatique (.bat double-cliquable)
$initScriptContent = @'
@echo off
set "projPath=%cd%"
set "installDir=%USERPROFILE%\custom-workflow\agent-workflow-visualizer"

echo ==========================================================
echo    INITIALISATION WORKFLOW MULTI-AGENT DANS CE PROJET
echo ==========================================================
echo Projet : %projPath%

:: La confiance du dossier et les permissions de Claude Code sont gerees
:: automatiquement au lancement de l'agent (--dangerously-skip-permissions
:: + pre-acceptation dans ~/.claude.json par orchestrate.js).
echo [*] Confiance du dossier geree automatiquement au lancement de Claude.

:: Copie locale de la regle dans GEMINI.md (lu automatiquement par Gemini/Antigravity)
copy /y "%USERPROFILE%\custom-workflow\.antigravityrules" "%projPath%\GEMINI.md" >nul
echo [+] Fichier de regles GEMINI.md cree a la racine du projet.

:: Creation ou mise a jour du .gitignore local (exclut les regles et le batch, sauf la map)
set "gitIgnoreFile=%projPath%\.gitignore"
if not exist "%gitIgnoreFile%" (
    echo # Antigravity multi-agent workflow > "%gitIgnoreFile%"
    echo GEMINI.md >> "%gitIgnoreFile%"
    echo init-workflow.bat >> "%gitIgnoreFile%"
    echo .claude-exit-code.txt >> "%gitIgnoreFile%"
    echo [+] Fichier .gitignore cree et fichiers de workflow ignores.
) else (
    :: Verification et ajout individuel de chaque fichier si absent
    findstr /c:"GEMINI.md" "%gitIgnoreFile%" >nul
    if errorlevel 1 (
        echo. >> "%gitIgnoreFile%"
        echo GEMINI.md >> "%gitIgnoreFile%"
        echo [+] GEMINI.md ajoute a .gitignore.
    )
    findstr /c:"init-workflow.bat" "%gitIgnoreFile%" >nul
    if errorlevel 1 (
        echo init-workflow.bat >> "%gitIgnoreFile%"
        echo [+] init-workflow.bat ajoute a .gitignore.
    )
    findstr /c:".claude-exit-code.txt" "%gitIgnoreFile%" >nul
    if errorlevel 1 (
        echo .claude-exit-code.txt >> "%gitIgnoreFile%"
        echo [+] .claude-exit-code.txt ajoute a .gitignore.
    )
)

:: Demarrage du visualiseur backend et frontend en CMD natif (rapide, sans bug de quotes ni blocage)
echo [*] Demarrage du serveur de visualisation...
start /b /d "%installDir%\backend" cmd /c node server.js "%projPath%"
start /b /d "%installDir%\frontend" cmd /c npm run dev

:: Ouverture du navigateur avec un ping d'attente compatible avec la redirection
ping -n 8 127.0.0.1 >nul
start "" "http://localhost:3000"
echo [+] Graphe 3D et Agents initialises !
cmd /k
'@
Write-Utf8NoBOM (Join-Path $targetDir "init-workflow.bat") $initScriptContent

# 6. Installation des dépendances NPM
Write-Host "[6/6] Installation des packages NPM en cours (veuillez patienter)..." -ForegroundColor White
Write-Host "-> Backend..." -ForegroundColor DarkGray
cd (Join-Path $installDir "backend")
npm install --no-audit --no-fund

Write-Host "-> Frontend..." -ForegroundColor DarkGray
cd (Join-Path $installDir "frontend")
npm install --no-audit --no-fund

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  WORKFLOW INSTALLÉ ET CONFIGURÉ AVEC SUCCÈS !           " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "Pour initialiser et lancer le workflow sur N'IMPORTE QUEL projet :"
Write-Host "1. Copiez le fichier `"$targetDir\init-workflow.bat`" dans votre projet."
Write-Host "2. Double-cliquez dessus pour lancer le visualiseur 3D et copier les regles."
Write-Host "==========================================================" -ForegroundColor Green

Read-Host "`nAppuyez sur Entrée pour fermer"
