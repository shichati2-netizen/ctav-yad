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
  Invoke-WebRequest -Uri "$modelBase/$name?download=true" -OutFile $target
  if (-not (Test-Path $target) -or (Get-Item $target).Length -lt 100) {
    throw "Model asset download failed or returned an invalid file: $name"
  }
}

# Tesseract's server and browser OCR paths both expect Hebrew traineddata.
$tessDir = Join-Path $source "public/tessdata"
New-Item -ItemType Directory -Force -Path $tessDir | Out-Null
$trainedData = Join-Path $tessDir "heb.traineddata"
Invoke-WebRequest -Uri "https://tessdata.projectnaptha.com/4.0.0/heb.traineddata" -OutFile $trainedData
if ((Get-Item $trainedData).Length -lt 1000000) { throw "Hebrew Tesseract traineddata download is incomplete." }

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
  extraResources = @(@{ from = ".next/standalone"; to = "app" })
  win = @{
    target = @(@{ target = "portable"; arch = @("x64") })
    signAndEditExecutable = $false
  }
  portable = @{ artifactName = "KtavYad-Portable.exe" }
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
let quitting = false;

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

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForServer(url, timeoutMs, logFile) {
  const end = Date.now() + timeoutMs;
  let lastError = "server did not respond";
  while (Date.now() < end) {
    if (serverProcess && serverProcess.exitCode !== null) {
      throw new Error("The local server exited. Log: " + logFile);
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
  throw new Error("The local server did not become ready: " + lastError + ". Log: " + logFile);
}

app.whenReady().then(async () => {
  try {
    const appRoot = path.join(process.resourcesPath, "app");
    const serverFile = path.join(appRoot, "server.js");
    if (!fs.existsSync(serverFile)) throw new Error("The packaged Next.js server is missing.");

    let dataRoot;
    const portableDir = process.env.PORTABLE_EXECUTABLE_DIR;
    if (portableDir) {
      dataRoot = path.join(portableDir, "KtavYad-Data");
      try {
        fs.mkdirSync(dataRoot, { recursive: true });
        fs.accessSync(dataRoot, fs.constants.W_OK);
      } catch {
        dataRoot = path.join(app.getPath("userData"), "data");
      }
    } else {
      dataRoot = path.join(app.getPath("userData"), "data");
    }

    const databaseDir = path.join(dataRoot, "database");
    const workingDataDir = path.join(dataRoot, "data");
    const logsDir = path.join(dataRoot, "logs");
    fs.mkdirSync(databaseDir, { recursive: true });
    fs.mkdirSync(workingDataDir, { recursive: true });
    fs.mkdirSync(logsDir, { recursive: true });

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
      },
    });
    serverProcess.stdout.pipe(logStream);
    serverProcess.stderr.pipe(logStream);
    serverProcess.once("error", (error) => logStream.write("\nSERVER SPAWN ERROR: " + error.stack + "\n"));

    await waitForServer(baseUrl, 120000, logFile);
    if (quitting) return;

    const window = new BrowserWindow({
      width: 1280,
      height: 900,
      minWidth: 900,
      minHeight: 650,
      show: true,
      autoHideMenuBar: true,
      title: "כתב יד",
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: true,
      },
    });
    await window.loadURL(baseUrl);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    dialog.showErrorBox("KtavYad - Startup failed", message);
    app.quit();
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

# Validate model files and load the ONNX graph with the Windows native runtime.
Push-Location $standalone
try {
  node -e "const fs=require('fs');const p='models/mishkefet';const c=JSON.parse(fs.readFileSync(p+'/charset.json','utf8'));if(!Array.isArray(c)||c.length!==198)throw new Error('Unexpected charset');const h=fs.readFileSync(p+'/head.bin');if(h.toString('ascii',0,4)!=='MKH1')throw new Error('Invalid head.bin');for(const f of ['charlm.bin','words.bin','backbone.fp16.onnx'])if(fs.statSync(p+'/'+f).size<1000)throw new Error('Invalid '+f);console.log('Model assets OK; charset='+c.length);"
  if ($LASTEXITCODE -ne 0) { throw "Model asset verification failed." }

  node -e "const ort=require('onnxruntime-node');ort.InferenceSession.create('models/mishkefet/backbone.fp16.onnx',{executionProviders:['cpu'],graphOptimizationLevel:'disabled'}).then(s=>{console.log('ONNX model loaded:',s.inputNames[0],'=>',s.outputNames[0]);process.exit(0)}).catch(e=>{console.error(e);process.exit(1)});"
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime could not load the bundled model." }

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
