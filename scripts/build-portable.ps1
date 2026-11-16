$ErrorActionPreference = "Stop"

function Invoke-Checked {
  param([string]$File, [string[]]$Arguments, [string]$Failure)
  & $File @Arguments
  if ($LASTEXITCODE -ne 0) { throw $Failure }
}

$archive = Get-ChildItem -Path $env:GITHUB_WORKSPACE -Filter "*.zip" -File | Select-Object -First 1
if (-not $archive) { throw "Project ZIP not found in repository root." }

$source = Join-Path $env:RUNNER_TEMP "ctav-yad-source"
New-Item -ItemType Directory -Force -Path $source | Out-Null
Expand-Archive -LiteralPath $archive.FullName -DestinationPath $source -Force
Write-Host "Extracted source archive: $($archive.Name)"

# Download the exact ONNX model assets used by the application code.
$modelDir = Join-Path $source "models/mishkefet"
New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
$modelBase = "https://huggingface.co/itayinbar/Mishkefet-v1/resolve/main/onnx"
$assets = @("backbone.fp16.onnx", "charlm.bin", "words.bin", "head.bin", "charset.json")
foreach ($name in $assets) {
  $target = Join-Path $modelDir $name
  Write-Host "Downloading model asset: $name"
  Invoke-WebRequest -Uri "$modelBase/$name" -OutFile $target
  if (-not (Test-Path $target) -or (Get-Item $target).Length -lt 100) {
    throw "Model asset download failed or returned an invalid file: $name"
  }
}

# Tesseract's server and browser OCR paths both expect Hebrew traineddata.
$tessDir = Join-Path $source "public/tessdata"
New-Item -ItemType Directory -Force -Path $tessDir | Out-Null
$trainedData = Join-Path $tessDir "heb.traineddata"
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/heb.traineddata" -OutFile $trainedData
if ((Get-Item $trainedData).Length -lt 500000) { throw "Hebrew Tesseract traineddata download is incomplete." }

@"
Mishkefet-v1
Author: Itay Inbar
Source: https://huggingface.co/itayinbar/Mishkefet-v1
License: Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International (CC BY-NC-SA 4.0)
License text: https://creativecommons.org/licenses/by-nc-sa/4.0/
The model weights and their derivatives may not be used commercially.
"@ | Set-Content -Path (Join-Path $modelDir "LICENSE.txt") -Encoding utf8

# Replace the server-only PostgreSQL driver with local, disk-persistent PGlite.
$dbFile = Join-Path $source "src/db/index.ts"
@'
import path from "node:path";
import { PGlite } from "@electric-sql/pglite";
import { drizzle } from "drizzle-orm/pglite";
import { migrate } from "drizzle-orm/pglite/migrator";

const buildMode = process.env.CTAV_BUILD_MODE === "1";
const dataDir = process.env.PGLITE_DATA_DIR || path.join(process.cwd(), "data", "database");
const migrationsFolder = process.env.DRIZZLE_MIGRATIONS_DIR || path.join(process.cwd(), "drizzle");

const client = buildMode ? new PGlite() : new PGlite(dataDir);
export const db = drizzle(client);

export const databaseReady = buildMode
  ? Promise.resolve()
  : (async () => {
      await client.waitReady;
      await migrate(db, { migrationsFolder });
    })();
'@ | Set-Content -Path $dbFile -Encoding utf8

@'
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs" && process.env.CTAV_BUILD_MODE !== "1") {
    const { databaseReady } = await import("./db");
    await databaseReady;
  }
}
'@ | Set-Content -Path (Join-Path $source "src/instrumentation.ts") -Encoding utf8

# Put mutable training data and fine-tuned model heads beside the portable EXE.
$datasetFile = Join-Path $source "src/lib/dataset.ts"
$datasetText = Get-Content -Path $datasetFile -Raw
$datasetOld = 'export const DATA_DIR = path.join(process.cwd(), "data");'
$datasetNew = 'export const DATA_DIR = process.env.DATA_DIR ? path.resolve(process.env.DATA_DIR) : path.join(process.cwd(), "data");'
if (-not $datasetText.Contains($datasetOld)) { throw "Could not locate DATA_DIR declaration in dataset.ts." }
Set-Content -Path $datasetFile -Value $datasetText.Replace($datasetOld, $datasetNew) -Encoding utf8

$engineFile = Join-Path $source "src/lib/mishkefet/engine.ts"
$engineText = Get-Content -Path $engineFile -Raw
$headOld = 'export const HEADS_DIR = path.join(process.cwd(), "data", "heads");'
$headNew = 'export const HEADS_DIR = path.join(process.env.DATA_DIR ? path.resolve(process.env.DATA_DIR) : path.join(process.cwd(), "data"), "heads");'
if (-not $engineText.Contains($headOld)) { throw "Could not locate HEADS_DIR declaration in engine.ts." }
Set-Content -Path $engineFile -Value $engineText.Replace($headOld, $headNew) -Encoding utf8

# Configure Next.js file tracing and generate PostgreSQL-compatible schema migrations.
$nextConfigFile = Join-Path $source "next.config.ts"
$nextConfig = Get-Content -Path $nextConfigFile -Raw
if ($nextConfig -notmatch 'output:\s*["'']standalone["'']') {
  $replacement = 'const nextConfig: NextConfig = {' + [Environment]::NewLine + '  output: "standalone",'
  $nextConfig = $nextConfig.Replace('const nextConfig: NextConfig = {', $replacement)
}
Set-Content -Path $nextConfigFile -Value $nextConfig -Encoding utf8

@'
import { defineConfig } from "drizzle-kit";
export default defineConfig({
  dialect: "postgresql",
  schema: "./src/db/schema.ts",
  out: "./drizzle",
  dbCredentials: { url: "postgresql://postgres:postgres@127.0.0.1:5432/ctavyad" }
});
'@ | Set-Content -Path (Join-Path $source "drizzle.config.ts") -Encoding utf8

Set-Location $source
Invoke-Checked "npm" @("install", "--no-audit", "--no-fund") "npm install failed."
Invoke-Checked "npm" @("install", "@electric-sql/pglite", "--save", "--no-audit", "--no-fund") "Installing PGlite failed."
Invoke-Checked "npm" @("install", "onnxruntime-node@latest", "--save", "--no-audit", "--no-fund") "Updating ONNX Runtime failed."
Invoke-Checked "npm" @("ls", "onnxruntime-node") "Could not verify ONNX Runtime package version."

# Use a private DLL name because Windows may resolve System32\onnxruntime.dll
# even when an app-local copy exists. The N-API binding's PE import table is patched
# to reference our private copy, avoiding Windows 11's inbox ORT 1.17.1.
$ortBinRoot = Join-Path $source "node_modules/onnxruntime-node/bin"
$ortDllCandidate = Get-ChildItem $ortBinRoot -Recurse -Filter "onnxruntime.dll" -File |
  Where-Object { $_.FullName -match '[\\/]win32[\\/]x64[\\/]' } |
  Select-Object -First 1
if (-not $ortDllCandidate) {
  $available = Get-ChildItem $ortBinRoot -Recurse -Filter "onnxruntime.dll" -File | Select-Object -ExpandProperty FullName
  throw "Could not find the Windows x64 onnxruntime.dll. Available DLLs: $($available -join '; ')"
}
$ortNativeDir = $ortDllCandidate.DirectoryName
$ortDll = $ortDllCandidate.FullName
$ortVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ortDll).FileVersion
Write-Host "Bundled Windows x64 ONNX DLL: $ortDll"
Write-Host "Bundled ONNX DLL version: $ortVersion"

$privateOrtName = "ctavort.dll"
$privateOrtName = "ctavort.dll"
$patchScript = Join-Path $env:RUNNER_TEMP "patch-onnx-import.cjs"
@'
const fs = require("node:fs");
const path = require("node:path");
const root = process.argv[2];
const oldName = Buffer.from("onnxruntime.dll", "ascii");
const newName = Buffer.alloc(oldName.length);
Buffer.from("ctavort.dll", "ascii").copy(newName);
let total = 0;

function walk(dir) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full);
      continue;
    }
    if (!entry.isFile() || ![".node", ".dll"].includes(path.extname(entry.name).toLowerCase())) continue;
    const bytes = fs.readFileSync(full);
    let offset = 0;
    let count = 0;
    while ((offset = bytes.indexOf(oldName, offset)) !== -1) {
      newName.copy(bytes, offset);
      offset += oldName.length;
      count++;
    }
    if (count) {
      fs.writeFileSync(full, bytes);
      total += count;
      process.stdout.write("Patched " + full + ": " + count + " reference(s)\n");
    }
  }
}

walk(root);
if (total < 1) {
  process.stderr.write("No native PE import references to onnxruntime.dll were found.\n");
  process.exit(1);
}
process.stdout.write("Total private ONNX import references: " + total + "\n");
'@ | Set-Content -Path $patchScript -Encoding utf8
Invoke-Checked "node" @($patchScript, $ortNativeDir) "Patching ONNX native imports to the private DLL name failed."
$privateOrtDll = Join-Path $ortNativeDir $privateOrtName
Move-Item -LiteralPath $ortDll -Destination $privateOrtDll -Force
$ortDll = $privateOrtDll
Write-Host "Private ONNX DLL name: $privateOrtName (patched $patchedImports import reference(s))"
$runtimeNativeDir = Join-Path $source "runtime-native"
New-Item -ItemType Directory -Force -Path $runtimeNativeDir | Out-Null
Copy-Item -Path (Join-Path $ortNativeDir "*") -Destination $runtimeNativeDir -Recurse -Force

Invoke-Checked "npm" @("install", "--save-dev", "electron", "electron-builder", "--no-audit", "--no-fund") "Installing Electron build tools failed."

# The Electron launcher is deliberately small; the actual app and all models are placed in resources/app.
$pkg = Get-Content package.json -Raw | ConvertFrom-Json
if (-not $pkg.version) { $pkg | Add-Member -NotePropertyName version -NotePropertyValue "1.0.0" -Force }
$pkg | Add-Member -NotePropertyName main -NotePropertyValue "electron-main.cjs" -Force
$buildConfig = @{
  appId = "org.shichati.ctavyad"
  productName = "KtavYad"
  asar = $false
  directories = @{ output = "dist-electron" }
  files = @("electron-main.cjs", "package.json")
  extraResources = @(
    @{ from = "runtime-app.zip"; to = "app.zip" },
    @{ from = "runtime-app-version.txt"; to = "app-version.txt" }
  )
  win = @{
    target = @(@{ target = "portable"; arch = @("x64") })
    signAndEditExecutable = $false
  }
  portable = @{ artifactName = "KtavYad-Portable.exe" }
  extraFiles = @(@{ from = "runtime-native"; to = "." })
}
$pkg | Add-Member -NotePropertyName build -NotePropertyValue $buildConfig -Force
$pkg | ConvertTo-Json -Depth 100 | Set-Content package.json -Encoding utf8

@'
const { app, BrowserWindow, dialog } = require("electron");
const { spawn } = require("node:child_process");
const fs = require("node:fs");
const net = require("node:net");
const path = require("node:path");

let serverProcess = null;
let mainWindow = null;
let quitting = false;

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function startupPage() {
  return "<!doctype html><html lang='he' dir='rtl'><meta charset='utf-8'>" +
    "<meta name='viewport' content='width=device-width,initial-scale=1'>" +
    "<title>כתב יד</title><style>" +
    "html,body{height:100%;margin:0;font-family:Segoe UI,Arial,sans-serif;background:#111827;color:#f8fafc}" +
    "body{display:grid;place-items:center}.panel{text-align:center;padding:36px;max-width:520px}" +
    ".mark{font-size:42px;margin-bottom:18px}.title{font-size:25px;font-weight:700}" +
    ".status{margin-top:18px;color:#cbd5e1;font-size:15px}.spinner{width:28px;height:28px;" +
    "border:3px solid #475569;border-top-color:#e2e8f0;border-radius:50%;margin:26px auto 0;" +
    "animation:spin 1s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}" +
    "</style><body><main class='panel'><div class='mark'>✍</div>" +
    "<div class='title'>כתב יד</div><div id='status' class='status'>מכין את התוכנה להפעלה…</div>" +
    "<div class='spinner'></div></main></body></html>";
}

function updateStatus(message) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const script = "const e=document.getElementById('status');if(e)e.textContent=" + JSON.stringify(message) + ";";
  mainWindow.webContents.executeJavaScript(script).catch(() => {});
}

function resolveDataRoot() {
  const portableDir = process.env.PORTABLE_EXECUTABLE_DIR;
  if (portableDir) {
    const portableData = path.join(portableDir, "KtavYad-Data");
    try {
      fs.mkdirSync(portableData, { recursive: true });
      fs.accessSync(portableData, fs.constants.W_OK);
      return portableData;
    } catch {}
  }
  return path.join(app.getPath("userData"), "data");
}

function extractRuntimeArchive(archiveFile, stagingDir) {
  return new Promise((resolve, reject) => {
    fs.rmSync(stagingDir, { recursive: true, force: true });
    fs.mkdirSync(stagingDir, { recursive: true });

    const script =
      "try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}; " +
      "Add-Type -AssemblyName System.IO.Compression.FileSystem; " +
      "[System.IO.Compression.ZipFile]::ExtractToDirectory($env:CTAV_APP_ZIP,$env:CTAV_APP_STAGE)";
    const extractor = spawn("powershell.exe", [
      "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script
    ], {
      windowsHide: true,
      stdio: ["ignore", "ignore", "pipe"],
      env: {
        ...process.env,
        CTAV_APP_ZIP: archiveFile,
        CTAV_APP_STAGE: stagingDir,
      },
    });

    let errorText = "";
    extractor.stderr.on("data", (chunk) => {
      if (errorText.length < 8000) errorText += chunk.toString();
    });
    extractor.once("error", reject);
    extractor.once("close", (code) => {
      if (code !== 0) {
        fs.rmSync(stagingDir, { recursive: true, force: true });
        reject(new Error("פריסת קובצי התוכנה נכשלה. " + errorText));
        return;
      }
      if (!fs.existsSync(path.join(stagingDir, "server.js"))) {
        fs.rmSync(stagingDir, { recursive: true, force: true });
        reject(new Error("קובץ השרת חסר בארכיון התוכנה."));
        return;
      }
      resolve();
    });
  });
}

function setServerPriority(pid) {
  if (process.platform !== "win32" || !pid) return;
  const helper = spawn("powershell.exe", [
    "-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
    "$p=Get-Process -Id $env:CTAV_SERVER_PID -ErrorAction SilentlyContinue; if($p){try{$p.PriorityClass='BelowNormal'}catch{}}"
  ], {
    windowsHide: true,
    stdio: "ignore",
    env: { ...process.env, CTAV_SERVER_PID: String(pid) },
  });
  helper.unref();
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      const port = address && typeof address === "object" ? address.port : null;
      server.close((error) => error ? reject(error) : port ? resolve(port) : reject(new Error("Could not allocate a local port")));
    });
  });
}

async function waitForServer(url, timeoutMs, logFile) {
  const end = Date.now() + timeoutMs;
  let lastError = "server did not respond";
  while (Date.now() < end) {
    if (quitting) throw new Error("ההפעלה בוטלה.");
    if (serverProcess && serverProcess.exitCode !== null) {
      throw new Error("השרת המקומי נסגר. פרטי התקלה נשמרו כאן: " + logFile);
    }
    try {
      const response = await fetch(url + "/api/health", { signal: AbortSignal.timeout(2500) });
      if (response.ok) return;
      lastError = "health check returned HTTP " + response.status;
    } catch (error) {
      lastError = error instanceof Error ? error.message : String(error);
    }
    await delay(700);
  }
  throw new Error("השרת המקומי לא עלה בזמן. " + lastError + ". פרטי התקלה: " + logFile);
}

app.whenReady().then(async () => {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 900,
    minWidth: 900,
    minHeight: 650,
    show: true,
    autoHideMenuBar: true,
    title: "כתב יד",
    backgroundColor: "#111827",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  try {
    await mainWindow.loadURL("data:text/html;charset=utf-8," + encodeURIComponent(startupPage()));
    await delay(250);

    const dataRoot = resolveDataRoot();
    const databaseDir = path.join(dataRoot, "database");
    const workingDataDir = path.join(dataRoot, "data");
    const logsDir = path.join(dataRoot, "logs");
    const runtimeRoot = path.join(dataRoot, "runtime");
    fs.mkdirSync(databaseDir, { recursive: true });
    fs.mkdirSync(workingDataDir, { recursive: true });
    fs.mkdirSync(logsDir, { recursive: true });
    fs.mkdirSync(runtimeRoot, { recursive: true });

    const buildIdFile = path.join(process.resourcesPath, "app-version.txt");
    const archiveFile = path.join(process.resourcesPath, "app.zip");
    if (!fs.existsSync(buildIdFile) || !fs.existsSync(archiveFile)) {
      throw new Error("קובצי ההפעלה הפנימיים חסרים בחבילת EXE.");
    }
    const buildId = fs.readFileSync(buildIdFile, "utf8").trim();
    if (!/^[A-Za-z0-9._-]{1,128}$/.test(buildId)) {
      throw new Error("מספר גרסת חבילת התוכנה אינו תקין.");
    }

    const appRoot = path.join(runtimeRoot, buildId);
    const serverFile = path.join(appRoot, "server.js");
    if (!fs.existsSync(serverFile)) {
      updateStatus("מכין את קובצי התוכנה והמודלים בפעם הראשונה…");
      const stagingDir = path.join(runtimeRoot, buildId + ".tmp");
      await extractRuntimeArchive(archiveFile, stagingDir);
      fs.rmSync(appRoot, { recursive: true, force: true });
      fs.renameSync(stagingDir, appRoot);
    }

    if (!fs.existsSync(serverFile)) throw new Error("שרת התוכנה לא נמצא לאחר הפריסה.");

    for (const name of fs.readdirSync(runtimeRoot)) {
      if (name !== buildId) fs.rmSync(path.join(runtimeRoot, name), { recursive: true, force: true });
    }

    updateStatus("מפעיל את השרת המקומי ומאתחל את מסד הנתונים…");
    const port = await freePort();
    const baseUrl = "http://127.0.0.1:" + port;
    const logFile = path.join(logsDir, "server.log");
    const logStream = fs.createWriteStream(logFile, { flags: "a" });

    serverProcess = spawn(process.execPath, [serverFile], {
      cwd: appRoot,
      windowsHide: true,
      stdio: ["ignore", "pipe", "pipe"],
      env: {
        ...process.env,
        ELECTRON_RUN_AS_NODE: "1",
        NODE_ENV: "production",
        NEXT_TELEMETRY_DISABLED: "1",
        HOSTNAME: "127.0.0.1",
        PORT: String(port),
        PGLITE_DATA_DIR: databaseDir,
        DATA_DIR: workingDataDir,
        DRIZZLE_MIGRATIONS_DIR: path.join(appRoot, "drizzle"),
        UV_THREADPOOL_SIZE: "2",
        OMP_NUM_THREADS: "2",
        OMP_WAIT_POLICY: "PASSIVE",
        KMP_BLOCKTIME: "0",
        OPENBLAS_NUM_THREADS: "1",
        MKL_NUM_THREADS: "1",
      },
    });
    serverProcess.stdout.pipe(logStream);
    serverProcess.stderr.pipe(logStream);
    serverProcess.once("error", (error) => logStream.write("\nSERVER SPAWN ERROR: " + error.stack + "\n"));
    setServerPriority(serverProcess.pid);

    await waitForServer(baseUrl, 120000, logFile);
    if (quitting || !mainWindow || mainWindow.isDestroyed()) return;
    updateStatus("השרת מוכן. פותח את סביבת העבודה…");
    await mainWindow.loadURL(baseUrl);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    updateStatus("ההפעלה נכשלה: " + message);
    dialog.showErrorBox("כתב יד - שגיאה בהפעלה", message);
  }
});

app.on("before-quit", () => {
  quitting = true;
  if (serverProcess && serverProcess.exitCode === null) serverProcess.kill();
});
app.on("window-all-closed", () => app.quit());
'@ | Set-Content -Path (Join-Path $source "electron-main.cjs") -Encoding utf8

$env:CTAV_BUILD_MODE = "1"
$env:NEXT_TELEMETRY_DISABLED = "1"
Invoke-Checked "npx" @("drizzle-kit", "generate", "--config=drizzle.config.ts") "Generating local database migrations failed."
if (-not (Test-Path (Join-Path $source "drizzle/meta/_journal.json"))) { throw "Drizzle migration journal was not generated." }

Invoke-Checked "npm" @("run", "build") "Next.js production build failed."
$standalone = Join-Path $source ".next/standalone"
if (-not (Test-Path (Join-Path $standalone "server.js"))) { throw "Next.js standalone server was not produced." }

# Copy assets that Next.js standalone intentionally leaves outside the traced server bundle.
New-Item -ItemType Directory -Force -Path (Join-Path $standalone "public") | Out-Null
Copy-Item -Path (Join-Path $source "public/*") -Destination (Join-Path $standalone "public") -Recurse -Force
$staticDest = Join-Path $standalone ".next/static"
New-Item -ItemType Directory -Force -Path $staticDest | Out-Null
Copy-Item -Path (Join-Path $source ".next/static/*") -Destination $staticDest -Recurse -Force
Copy-Item -Path (Join-Path $source "models") -Destination $standalone -Recurse -Force
Copy-Item -Path (Join-Path $source "drizzle") -Destination $standalone -Recurse -Force
$sourceOrtBin = Join-Path $source "node_modules/onnxruntime-node/bin"
$standaloneOrtBin = Join-Path $standalone "node_modules/onnxruntime-node/bin"
New-Item -ItemType Directory -Force -Path $standaloneOrtBin | Out-Null
Copy-Item -Path (Join-Path $sourceOrtBin "*") -Destination $standaloneOrtBin -Recurse -Force
$ortRelativePath = [System.IO.Path]::GetRelativePath($sourceOrtBin, $ortDll)
$standaloneOrtDll = Join-Path $standaloneOrtBin $ortRelativePath
if (-not (Test-Path $standaloneOrtDll)) {
  throw "The matching ONNX native DLL was not copied into the Next.js standalone package: $ortRelativePath"
}

# Keep the portable EXE's first-stage extraction small: ship the full server tree
# and all models as one archive, then expand it only after the splash window is visible.
$buildId = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { [System.Guid]::NewGuid().ToString("N") }
if ($buildId -notmatch '^[A-Za-z0-9._-]{1,128}
Push-Location $standalone
try {
  node -e "const fs=require('fs');const p='models/mishkefet';const c=JSON.parse(fs.readFileSync(p+'/charset.json','utf8'));if(!Array.isArray(c)||c.length!==198)throw new Error('Unexpected charset');const h=fs.readFileSync(p+'/head.bin');if(h.toString('ascii',0,4)!=='MKH1')throw new Error('Invalid head.bin');for(const f of ['charlm.bin','words.bin','backbone.fp16.onnx'])if(fs.statSync(p+'/'+f).size<1000)throw new Error('Invalid '+f);console.log('Model assets OK; charset='+c.length);"
  if ($LASTEXITCODE -ne 0) { throw "Model asset verification failed." }

  # Run Node from a clean directory with the package's own DLL beside node.exe.
  # This reproduces the executable-directory-first DLL lookup used by the packaged Electron app.
  $smokeNodeDir = Join-Path $env:RUNNER_TEMP "node-with-bundled-ort"
  New-Item -ItemType Directory -Force -Path $smokeNodeDir | Out-Null
  $nodeExe = (Get-Command node).Source
  Copy-Item -LiteralPath $nodeExe -Destination (Join-Path $smokeNodeDir "node.exe") -Force
  Copy-Item -LiteralPath (Join-Path $runtimeNativeDir "ctavort.dll") -Destination (Join-Path $smokeNodeDir "ctavort.dll") -Force

  $loadedOrtDll = Join-Path $smokeNodeDir "ctavort.dll"
  $loadedOrtVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($loadedOrtDll).FileVersion
  Write-Host "Smoke-test executable: $(Join-Path $smokeNodeDir 'node.exe')"
  Write-Host "Smoke-test ONNX DLL: $loadedOrtVersion"

  & (Join-Path $smokeNodeDir "node.exe") -e "const ort=require('onnxruntime-node');ort.InferenceSession.create('models/mishkefet/backbone.fp16.onnx',{executionProviders:['cpu'],graphOptimizationLevel:'disabled'}).then(s=>{console.log('ONNX model loaded:',s.inputNames[0],'=>',s.outputNames[0]);process.exit(0)}).catch(e=>{console.error(e);process.exit(1)});"
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime could not load the bundled model using the package-matched DLL." }

  if (-not (Test-Path "public/tessdata/heb.traineddata")) { throw "Hebrew Tesseract data is missing." }

  # Start the standalone server once to verify migrations and the embedded local database.
  $env:CTAV_BUILD_MODE = ""
  $env:PGLITE_DATA_DIR = Join-Path $env:RUNNER_TEMP "ctav-yad-smoke-db"
  $env:DATA_DIR = Join-Path $env:RUNNER_TEMP "ctav-yad-smoke-data"
  $env:PORT = "32191"
  $env:HOSTNAME = "127.0.0.1"
  $stdout = Join-Path $env:RUNNER_TEMP "ctav-server-out.log"
  $stderr = Join-Path $env:RUNNER_TEMP "ctav-server-err.log"
  $proc = Start-Process -FilePath (Get-Command node).Source -ArgumentList @("server.js") -WorkingDirectory $standalone -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  try {
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
      if ($proc.HasExited) { break }
      try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:32191/api/health" -TimeoutSec 3
        if ($response.StatusCode -eq 200) { $ready = $true; break }
      } catch {}
      Start-Sleep -Seconds 1
    }
    if (-not $ready) {
      if (Test-Path $stdout) { Get-Content $stdout | Write-Host }
      if (Test-Path $stderr) { Get-Content $stderr | Write-Host }
      throw "Portable server did not become healthy. See logs above."
    }
    Write-Host "Standalone app and embedded PostgreSQL-compatible database passed the health check."
  } finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  }
} finally {
  Pop-Location
}

# Electron-builder's portable target is a single self-extracting Windows EXE.
Set-Location $source
Invoke-Checked "npx" @("electron-builder", "--win", "portable", "--x64") "electron-builder failed."
$builtExe = Get-ChildItem (Join-Path $source "dist-electron") -Filter "*.exe" -File | Select-Object -First 1
if (-not $builtExe) { throw "Portable EXE was not produced." }

$dist = Join-Path $env:GITHUB_WORKSPACE "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$finalExe = Join-Path $dist "KtavYad-Portable.exe"
Copy-Item -LiteralPath $builtExe.FullName -Destination $finalExe -Force
Write-Host "PORTABLE EXE: $finalExe"
Write-Host "SIZE_BYTES: $((Get-Item $finalExe).Length)"
) { throw "Invalid build identifier for runtime cache." }
$appArchive = Join-Path $source "runtime-app.zip"
$appVersionFile = Join-Path $source "runtime-app-version.txt"
if (Test-Path $appArchive) { Remove-Item -LiteralPath $appArchive -Force }
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory(
  $standalone,
  $appArchive,
  [System.IO.Compression.CompressionLevel]::Fastest,
  $false
)
Set-Content -Path $appVersionFile -Value $buildId -Encoding ascii
$archiveCheck = [System.IO.Compression.ZipFile]::OpenRead($appArchive)
try {
  $requiredEntries = @("server.js", "models/mishkefet/backbone.fp16.onnx", "drizzle/meta/_journal.json")
  foreach ($entryName in $requiredEntries) {
    if (-not ($archiveCheck.Entries | Where-Object { $_.FullName -eq $entryName })) {
      throw "Runtime archive is missing required entry: $entryName"
    }
  }
} finally {
  $archiveCheck.Dispose()
}
Write-Host "Runtime archive created: $([math]::Round((Get-Item $appArchive).Length / 1MB, 1)) MB"

# Validate model files and load the ONNX graph with the Windows native runtime.
Push-Location $standalone
try {
  node -e "const fs=require('fs');const p='models/mishkefet';const c=JSON.parse(fs.readFileSync(p+'/charset.json','utf8'));if(!Array.isArray(c)||c.length!==198)throw new Error('Unexpected charset');const h=fs.readFileSync(p+'/head.bin');if(h.toString('ascii',0,4)!=='MKH1')throw new Error('Invalid head.bin');for(const f of ['charlm.bin','words.bin','backbone.fp16.onnx'])if(fs.statSync(p+'/'+f).size<1000)throw new Error('Invalid '+f);console.log('Model assets OK; charset='+c.length);"
  if ($LASTEXITCODE -ne 0) { throw "Model asset verification failed." }

  # Run Node from a clean directory with the package's own DLL beside node.exe.
  # This reproduces the executable-directory-first DLL lookup used by the packaged Electron app.
  $smokeNodeDir = Join-Path $env:RUNNER_TEMP "node-with-bundled-ort"
  New-Item -ItemType Directory -Force -Path $smokeNodeDir | Out-Null
  $nodeExe = (Get-Command node).Source
  Copy-Item -LiteralPath $nodeExe -Destination (Join-Path $smokeNodeDir "node.exe") -Force
  Copy-Item -LiteralPath (Join-Path $runtimeNativeDir "ctavort.dll") -Destination (Join-Path $smokeNodeDir "ctavort.dll") -Force

  $loadedOrtDll = Join-Path $smokeNodeDir "ctavort.dll"
  $loadedOrtVersion = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($loadedOrtDll).FileVersion
  Write-Host "Smoke-test executable: $(Join-Path $smokeNodeDir 'node.exe')"
  Write-Host "Smoke-test ONNX DLL: $loadedOrtVersion"

  & (Join-Path $smokeNodeDir "node.exe") -e "const ort=require('onnxruntime-node');ort.InferenceSession.create('models/mishkefet/backbone.fp16.onnx',{executionProviders:['cpu'],graphOptimizationLevel:'disabled'}).then(s=>{console.log('ONNX model loaded:',s.inputNames[0],'=>',s.outputNames[0]);process.exit(0)}).catch(e=>{console.error(e);process.exit(1)});"
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime could not load the bundled model using the package-matched DLL." }

  if (-not (Test-Path "public/tessdata/heb.traineddata")) { throw "Hebrew Tesseract data is missing." }

  # Start the standalone server once to verify migrations and the embedded local database.
  $env:CTAV_BUILD_MODE = ""
  $env:PGLITE_DATA_DIR = Join-Path $env:RUNNER_TEMP "ctav-yad-smoke-db"
  $env:DATA_DIR = Join-Path $env:RUNNER_TEMP "ctav-yad-smoke-data"
  $env:PORT = "32191"
  $env:HOSTNAME = "127.0.0.1"
  $stdout = Join-Path $env:RUNNER_TEMP "ctav-server-out.log"
  $stderr = Join-Path $env:RUNNER_TEMP "ctav-server-err.log"
  $proc = Start-Process -FilePath (Get-Command node).Source -ArgumentList @("server.js") -WorkingDirectory $standalone -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
  try {
    $ready = $false
    for ($i = 0; $i -lt 120; $i++) {
      if ($proc.HasExited) { break }
      try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:32191/api/health" -TimeoutSec 3
        if ($response.StatusCode -eq 200) { $ready = $true; break }
      } catch {}
      Start-Sleep -Seconds 1
    }
    if (-not $ready) {
      if (Test-Path $stdout) { Get-Content $stdout | Write-Host }
      if (Test-Path $stderr) { Get-Content $stderr | Write-Host }
      throw "Portable server did not become healthy. See logs above."
    }
    Write-Host "Standalone app and embedded PostgreSQL-compatible database passed the health check."
  } finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  }
} finally {
  Pop-Location
}

# Electron-builder's portable target is a single self-extracting Windows EXE.
Set-Location $source
Invoke-Checked "npx" @("electron-builder", "--win", "portable", "--x64") "electron-builder failed."
$builtExe = Get-ChildItem (Join-Path $source "dist-electron") -Filter "*.exe" -File | Select-Object -First 1
if (-not $builtExe) { throw "Portable EXE was not produced." }

$dist = Join-Path $env:GITHUB_WORKSPACE "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$finalExe = Join-Path $dist "KtavYad-Portable.exe"
Copy-Item -LiteralPath $builtExe.FullName -Destination $finalExe -Force
Write-Host "PORTABLE EXE: $finalExe"
Write-Host "SIZE_BYTES: $((Get-Item $finalExe).Length)"
