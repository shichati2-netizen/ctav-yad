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

# Download only small Mishkefet support files. The large ONNX graph is supplied beside the portable EXE.
$modelDir = Join-Path $source "models/mishkefet"
New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
$modelBase = "https://huggingface.co/itayinbar/Mishkefet-v1/resolve/main/onnx"
$assets = @("charlm.bin", "words.bin", "head.bin", "charset.json")
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
$modelDirOld = 'export const MODEL_DIR = path.join(process.cwd(), "models", "mishkefet");'
$modelDirNew = 'export const MODEL_DIR = path.join(process.cwd(), "models", "mishkefet"); export const ONNX_MODEL_PATH = process.env.MISHKEFET_ONNX_PATH ? path.resolve(process.env.MISHKEFET_ONNX_PATH) : path.join(MODEL_DIR, "backbone.fp16.onnx");'
$onnxOld = 'const session = await ort.InferenceSession.create(path.join(MODEL_DIR, "backbone.fp16.onnx"), {'
$onnxNew = 'const session = await ort.InferenceSession.create(ONNX_MODEL_PATH, {'
$loadCoreOld = 'async function loadCore(): Promise<Core> {'
$loadCoreNew = 'async function loadCore(): Promise<Core> { if (!fs.existsSync(ONNX_MODEL_PATH)) throw new Error("קובץ backbone.fp16.onnx חסר. יש להעתיק אותו לתיקייה models/mishkefet ליד קובץ התוכנה. נתיב נבדק: " + ONNX_MODEL_PATH);'
if (-not $engineText.Contains($headOld)) { throw "Could not locate HEADS_DIR declaration in engine.ts." }
if (-not $engineText.Contains($modelDirOld)) { throw "Could not locate MODEL_DIR declaration in engine.ts." }
if (-not $engineText.Contains($onnxOld)) { throw "Could not locate ONNX model loading expression in engine.ts." }
if (-not $engineText.Contains($loadCoreOld)) { throw "Could not locate loadCore() in engine.ts." }
$engineText = $engineText.Replace($headOld, $headNew)
$engineText = $engineText.Replace($modelDirOld, $modelDirNew)
$engineText = $engineText.Replace($onnxOld, $onnxNew)
$graphOptionsOld = 'graphOptimizationLevel: "disabled",'
$graphOptionsNew = 'graphOptimizationLevel: "disabled", intraOpNumThreads: 2, interOpNumThreads: 1, executionMode: "sequential",'
if (-not $engineText.Contains($graphOptionsOld)) { throw "Could not locate ONNX graph options in engine.ts." }
$engineText = $engineText.Replace($graphOptionsOld, $graphOptionsNew)
$engineText = $engineText.Replace($loadCoreOld, $loadCoreNew)
Set-Content -Path $engineFile -Value $engineText -Encoding utf8

$readyRouteDir = Join-Path $source "src/app/api/mishkefet/ready"
New-Item -ItemType Directory -Force -Path $readyRouteDir | Out-Null
@'
import fs from "node:fs";
import { getCore, ONNX_MODEL_PATH } from "@/lib/mishkefet/engine";

export const dynamic = "force-dynamic";

export async function GET() {
  return Response.json({
    exists: fs.existsSync(ONNX_MODEL_PATH),
    modelPath: ONNX_MODEL_PATH,
  });
}

export async function POST() {
  try {
    await getCore();
    return Response.json({ ready: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return Response.json({ ready: false, error: message }, { status: 503 });
  }
}
'@ | Set-Content -Path (Join-Path $readyRouteDir "route.ts") -Encoding utf8

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

# The Electron launcher is small; the complete unpacked app is stored in resources/app.
$pkg = Get-Content package.json -Raw | ConvertFrom-Json
if (-not $pkg.version) { $pkg | Add-Member -NotePropertyName version -NotePropertyValue "1.0.0" -Force }
$pkg | Add-Member -NotePropertyName main -NotePropertyValue "electron-main.cjs" -Force
$dist = Join-Path $env:GITHUB_WORKSPACE "dist"
if (Test-Path $dist) { Remove-Item -LiteralPath $dist -Recurse -Force }
$packageDir = Join-Path $dist "KtavYad"
New-Item -ItemType Directory -Force -Path $packageDir | Out-Null

$buildConfig = @{
  appId = "org.shichati.ctavyad"
  productName = "KtavYad"
  asar = $false
  directories = @{ output = $packageDir }
  files = @("electron-main.cjs", "package.json")
  extraResources = @(
    @{ from = ".next/standalone"; to = "runtime" },
    # Explicitly restore Next and SWC ESM files in the final Electron resources.
    @{ from = "node_modules/next"; to = "runtime/node_modules/next" },
    @{ from = ".next/standalone/node_modules/@swc/helpers/esm"; to = "runtime/node_modules/@swc/helpers/esm" }
  )
  win = @{
    signAndEditExecutable = $false
  }
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
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function setStatus(message) {
  if (!mainWindow || mainWindow.isDestroyed()) return;
  const js = "const e=document.getElementById('status');if(e)e.textContent=" + JSON.stringify(message) + ";";
  mainWindow.webContents.executeJavaScript(js).catch(() => {});
}
function setBelowNormal(pid) {
  if (!pid || process.platform !== "win32") return;
  const p = spawn("powershell.exe", ["-NoProfile","-NonInteractive","-Command", "$x=Get-Process -Id $env:CTAV_PID -ErrorAction SilentlyContinue; if($x){try{$x.PriorityClass='BelowNormal'}catch{}}"],
    { windowsHide:true, stdio:"ignore", env:{...process.env,CTAV_PID:String(pid)} });
  p.unref();
}
function getDataRoot() {
  const dir = process.env.PORTABLE_EXECUTABLE_DIR;
  if (dir) {
    const p = path.join(dir, "KtavYad-Data");
    try { fs.mkdirSync(p,{recursive:true}); fs.accessSync(p,fs.constants.W_OK); return p; } catch {}
  }
  return path.join(app.getPath("userData"), "data");
}
async function ensureModelFile(exeDir, dataRoot) {
  const preferred = path.join(exeDir, "models", "mishkefet", "backbone.fp16.onnx");
  const dataFallback = path.join(dataRoot, "models", "mishkefet", "backbone.fp16.onnx");
  const minimumBytes = 50 * 1024 * 1024;

  const isUsable = (file) => {
    try {
      const stat = fs.statSync(file);
      return stat.isFile() && stat.size >= minimumBytes;
    } catch { return false; }
  };

  if (isUsable(preferred)) return preferred;
  if (isUsable(dataFallback)) return dataFallback;

  setStatus("בפעם הראשונה יש לבחור את קובץ מודל הזיהוי (ONNX)...");
  const result = await dialog.showOpenDialog(mainWindow, {
    title: "בחירת מודל הזיהוי של כתב יד",
    buttonLabel: "בחר קובץ מודל",
    properties: ["openFile"],
    filters: [{ name: "Mishkefet ONNX model", extensions: ["onnx"] }]
  });
  if (result.canceled || !result.filePaths || !result.filePaths[0]) return null;

  const selected = path.resolve(result.filePaths[0]);
  if (path.extname(selected).toLowerCase() !== ".onnx") {
    throw new Error("יש לבחור קובץ עם סיומת .onnx.");
  }
  const sourceStat = fs.statSync(selected);
  if (!sourceStat.isFile() || sourceStat.size < minimumBytes) {
    throw new Error("הקובץ שנבחר קטן מדי או אינו קובץ מודל ONNX תקין.");
  }

  let destination = preferred;
  try {
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    if (selected !== path.resolve(destination)) await fs.promises.copyFile(selected, destination);
  } catch (error) {
    // Protected installation paths may be read-only: use the per-user folder.
    destination = dataFallback;
    fs.mkdirSync(path.dirname(destination), { recursive: true });
    if (selected !== path.resolve(destination)) await fs.promises.copyFile(selected, destination);
  }

  if (!isUsable(destination) || fs.statSync(destination).size !== sourceStat.size) {
    throw new Error("העתקת קובץ המודל לא הושלמה. נסה לבחור את הקובץ שוב.");
  }
  setStatus("קובץ המודל נשמר. מפעיל את מנוע הזיהוי...");
  return destination;
}
function freePort() {
  const requested=Number.parseInt(process.env.CTAV_FIXED_PORT||"",10);
  if(Number.isInteger(requested)&&requested>0&&requested<65536)return Promise.resolve(requested);
  return new Promise((resolve,reject)=>{
    const s=net.createServer(); s.once("error",reject);
    s.listen(0,"127.0.0.1",()=>{const a=s.address();const p=a&&typeof a==="object"?a.port:null;s.close(e=>e?reject(e):p?resolve(p):reject(new Error("Could not allocate port"))) });
  });
}
async function waitForServer(url, logFile) {
  const end=Date.now()+120000;
  while(Date.now()<end){
    if(quitting)throw new Error("ההפעלה בוטלה.");
    if(serverProcess&&serverProcess.exitCode!==null)throw new Error("השרת המקומי נסגר. יומן: "+logFile);
    try{const r=await fetch(url+"/api/health",{signal:AbortSignal.timeout(2500)});if(r.ok)return}catch{}
    await pause(700);
  }
  throw new Error("השרת המקומי לא עלה בזמן. יומן: "+logFile);
}
app.whenReady().then(async()=>{
  mainWindow=new BrowserWindow({width:1280,height:900,minWidth:900,minHeight:650,show:process.env.CTAV_SMOKE_TEST!=="1",
    autoHideMenuBar:true,title:"כתב יד",backgroundColor:"#111827",
    webPreferences:{contextIsolation:true,nodeIntegration:false,sandbox:true}});
  try{
    const splash="<!doctype html><html lang='he' dir='rtl'><meta charset='utf-8'><title>כתב יד</title>" +
      "<style>body{margin:0;height:100vh;display:grid;place-items:center;background:#111827;color:#f8fafc;font-family:Segoe UI,Arial}" +
      "main{text-align:center}h2{font-size:26px}.muted{color:#cbd5e1}.spin{margin:24px auto;border:3px solid #475569;border-top-color:white;border-radius:50%;width:28px;height:28px;animation:s 1s linear infinite}" +
      "@keyframes s{to{transform:rotate(360deg)}}</style><main><h2>כתב יד</h2><div id='status' class='muted'>מכין את התוכנה להפעלה…</div><div class='spin'></div></main></html>";
    await mainWindow.loadURL("data:text/html;charset=utf-8,"+encodeURIComponent(splash));
    await pause(250);
    const dataRoot=getDataRoot();
    const dbDir=path.join(dataRoot,"database"), dataDir=path.join(dataRoot,"data"), logsDir=path.join(dataRoot,"logs");
    for(const d of [dbDir,dataDir,logsDir])fs.mkdirSync(d,{recursive:true});
    const exeDir=process.env.PORTABLE_EXECUTABLE_DIR || path.dirname(process.execPath);
    const selectedModelPath=await ensureModelFile(exeDir,dataRoot);
    const appRoot=path.join(process.resourcesPath,"runtime");
    const supportDir=path.join(appRoot,"models","mishkefet");
    for(const file of ["charset.json","charlm.bin","words.bin","head.bin"]) {
      if(!fs.existsSync(path.join(supportDir,file))) throw new Error("קובץ עזר חסר בחבילת התוכנה: "+file);
    }
    const serverFile=path.join(appRoot,"server.js");
    if(!fs.existsSync(serverFile))throw new Error("קובצי השרת חסרים בתיקיית resources/runtime.");
    setStatus("הממשק מוכן. מפעיל את השרת המקומי…");
    const port=await freePort(), baseUrl="http://127.0.0.1:"+port, logFile=path.join(logsDir,"server.log"), log=fs.createWriteStream(logFile,{flags:"a"});
    serverProcess=spawn(process.execPath,[serverFile],{cwd:appRoot,windowsHide:true,stdio:["ignore","pipe","pipe"],env:{
      ...process.env,ELECTRON_RUN_AS_NODE:"1",NODE_ENV:"production",NEXT_TELEMETRY_DISABLED:"1",HOSTNAME:"127.0.0.1",PORT:String(port),
      PGLITE_DATA_DIR:dbDir,DATA_DIR:dataDir,DRIZZLE_MIGRATIONS_DIR:path.join(appRoot,"drizzle"),
      MISHKEFET_ONNX_PATH: selectedModelPath || path.join(exeDir,"models","mishkefet","backbone.fp16.onnx"),
      UV_THREADPOOL_SIZE:"2",OMP_NUM_THREADS:"2",OMP_WAIT_POLICY:"PASSIVE",KMP_BLOCKTIME:"0",OPENBLAS_NUM_THREADS:"1",MKL_NUM_THREADS:"1"
    }});
    serverProcess.stdout.pipe(log);serverProcess.stderr.pipe(log);
    serverProcess.once("error",e=>log.write("\nSERVER SPAWN ERROR: "+e.stack+"\n"));
    setBelowNormal(serverProcess.pid);
    await waitForServer(baseUrl,logFile);
    if(!quitting&&mainWindow&&!mainWindow.isDestroyed())await mainWindow.loadURL(baseUrl);
    if(process.env.CTAV_SMOKE_TEST_MARKER){
      fs.mkdirSync(path.dirname(process.env.CTAV_SMOKE_TEST_MARKER),{recursive:true});
      fs.writeFileSync(process.env.CTAV_SMOKE_TEST_MARKER,JSON.stringify({baseUrl,pid:process.pid,serverPid:serverProcess&&serverProcess.pid,loadedAt:new Date().toISOString()}));
    }
  }catch(e){const message=e instanceof Error?e.message:String(e);setStatus("ההפעלה נכשלה: "+message);dialog.showErrorBox("כתב יד - שגיאה בהפעלה",message)}
});
app.on("before-quit",()=>{quitting=true;if(serverProcess&&serverProcess.exitCode===null)serverProcess.kill()});
app.on("window-all-closed",()=>app.quit());
'@ | Set-Content -Path (Join-Path $source "electron-main.cjs") -Encoding utf8

$componentFile = Join-Path $source "src/components/TranscriberApp.tsx"
$componentText = Get-Content -Path $componentFile -Raw
$componentText = $componentText.Replace("`r`n", "`n")
$stateOld = '  const [useOcr, setUseOcr] = useState(true);'
$stateNew = @'
  const [useOcr, setUseOcr] = useState(true);
  const [modelLoadState, setModelLoadState] = useState<"checking" | "loading" | "ready" | "missing" | "error">("checking");
  const [modelLoadMessage, setModelLoadMessage] = useState("בודק את קובץ מודל הזיהוי...");
'@
if (-not $componentText.Contains($stateOld)) { throw "Could not find TranscriberApp OCR state declaration." }
$componentText = $componentText.Replace($stateOld, $stateNew.TrimEnd())

$effectsOld = @'
  useEffect(() => {
    void refreshAdapt();
    void refreshDocs();
  }, [refreshAdapt, refreshDocs]);
'@
$effectsNew = @'
  useEffect(() => {
    void refreshAdapt();
    void refreshDocs();
  }, [refreshAdapt, refreshDocs]);

  // The UI renders first. Only then does the background model warm-up begin.
  useEffect(() => {
    let cancelled = false;
    let slowTimer: number | undefined;
    const loadModel = async () => {
      try {
        setModelLoadState("checking");
        setModelLoadMessage("בודק את קובץ מודל הזיהוי...");
        const check = await fetch("/api/mishkefet/ready", { cache: "no-store" });
        const info = (await check.json()) as { exists?: boolean; modelPath?: string };
        if (cancelled) return;
        if (!check.ok || !info.exists) {
          setModelLoadState("missing");
          setModelLoadMessage(
            "קובץ backbone.fp16.onnx לא נמצא. העתק אותו לתיקייה models/mishkefet ליד KtavYad.exe, או ישירות לצד קובץ ה-EXE. נתיב שנבדק: " + (info.modelPath ?? "לא ידוע"),
          );
          return;
        }

        setModelLoadState("loading");
        setModelLoadMessage("קובץ המודל נמצא. טוען את מנוע הזיהוי ברקע...");
        slowTimer = window.setTimeout(() => {
          if (!cancelled) setModelLoadMessage("טעינת רשת הזיהוי עדיין מתבצעת. הממשק נשאר זמין בזמן הטעינה...");
        }, 5000);

        const response = await fetch("/api/mishkefet/ready", { method: "POST" });
        const result = (await response.json()) as { ready?: boolean; error?: string };
        if (cancelled) return;
        if (!response.ok || !result.ready) {
          setModelLoadState("error");
          setModelLoadMessage(result.error ?? "טעינת מודל הזיהוי נכשלה.");
          return;
        }
        setModelLoadState("ready");
        setModelLoadMessage("מנוע הזיהוי מוכן.");
      } catch (error) {
        if (!cancelled) {
          setModelLoadState("error");
          setModelLoadMessage(error instanceof Error ? error.message : String(error));
        }
      } finally {
        if (slowTimer !== undefined) window.clearTimeout(slowTimer);
      }
    };
    void loadModel();
    return () => {
      cancelled = true;
      if (slowTimer !== undefined) window.clearTimeout(slowTimer);
    };
  }, []);
'@
$effectsPattern = 'useEffect\(\(\) => \{\s*void refreshAdapt\(\);\s*void refreshDocs\(\);\s*\},\s*\[refreshAdapt,\s*refreshDocs\]\);'
$effectsRegex = [regex]::new($effectsPattern)
if (-not $effectsRegex.IsMatch($componentText)) { throw "Could not find TranscriberApp initialization effects (line-ending independent match)." }
$componentText = $effectsRegex.Replace($componentText, $effectsNew.Trim(), 1)

$bannerAnchor = @'
      </header>

      {trainingRunning && adapt && (
'@
$bannerMarkup = @'
      </header>

      {modelLoadState !== "ready" ? (
        <div
          role="status"
          aria-live="polite"
          className={
            "border-b px-4 py-3 " +
            (modelLoadState === "missing" || modelLoadState === "error"
              ? "border-amber-500/40 bg-amber-950/50 text-amber-100"
              : "border-indigo-500/40 bg-indigo-950/50 text-indigo-100")
          }
        >
          <div className="mx-auto flex max-w-7xl items-center gap-3">
            {modelLoadState === "loading" || modelLoadState === "checking" ? (
              <div className="size-5 shrink-0 animate-spin rounded-full border-2 border-indigo-800 border-t-indigo-200" />
            ) : (
              <span className="text-lg">!</span>
            )}
            <div className="min-w-0 flex-1">
              <div className="text-sm font-semibold">
                {modelLoadState === "missing" ? "נדרש קובץ מודל חיצוני" :
                 modelLoadState === "error" ? "טעינת המודל נכשלה" :
                 modelLoadState === "checking" ? "בודק את קובצי המודל" : "טוען את מודל הזיהוי"}
              </div>
              <div className="mt-1 break-words text-xs opacity-90">{modelLoadMessage}</div>
              {(modelLoadState === "loading" || modelLoadState === "checking") && (
                <div className="mt-2 h-1.5 overflow-hidden rounded-full bg-slate-800">
                  <div className="h-full w-1/3 animate-pulse rounded-full bg-indigo-300" />
                </div>
              )}
            </div>
          </div>
        </div>
      ) : (
        <div className="border-b border-emerald-500/20 bg-emerald-950/20 px-4 py-1 text-center text-xs text-emerald-300">
          מנוע הזיהוי מוכן
        </div>
      )}

      {trainingRunning && adapt && (
'@
$bannerPattern = '</header>\s*\{trainingRunning\s*&&\s*adapt\s*&&\s*\('
$bannerRegex = [regex]::new($bannerPattern)
if (-not $bannerRegex.IsMatch($componentText)) { throw "Could not find TranscriberApp header insertion point (line-ending independent match)." }
$componentText = $bannerRegex.Replace($componentText, $bannerMarkup.Trim(), 1)
Set-Content -Path $componentFile -Value $componentText -Encoding utf8

$env:CTAV_BUILD_MODE = "1"
$env:NEXT_TELEMETRY_DISABLED = "1"
Invoke-Checked "npx" @("drizzle-kit", "generate", "--config=drizzle.config.ts") "Generating local database migrations failed."
if (-not (Test-Path (Join-Path $source "drizzle/meta/_journal.json"))) { throw "Drizzle migration journal was not generated." }

# Build with the same Turbopack runtime that passed the standalone PGlite smoke test.
# Resolve its hashed external ONNX alias explicitly below instead of changing bundlers.
Invoke-Checked "npm" @("run", "build") "Next.js production build failed."
$standalone = Join-Path $source ".next/standalone"
if (-not (Test-Path (Join-Path $standalone "server.js"))) { throw "Next.js standalone server was not produced." }

# Next.js standalone tracing can omit the Next.js package itself in this generated
# desktop bundle. Ensure the runtime has Next.js at the exact location server.js resolves.
$standaloneNodeModules = Join-Path $standalone "node_modules"
New-Item -ItemType Directory -Force -Path $standaloneNodeModules | Out-Null
$sourceNextPackage = Join-Path $source "node_modules/next"
$standaloneNextPackage = Join-Path $standaloneNodeModules "next"
if (-not (Test-Path (Join-Path $sourceNextPackage "package.json"))) {
  throw "The installed Next.js package is missing from source node_modules."
}
if (Test-Path $standaloneNextPackage) {
  Remove-Item -LiteralPath $standaloneNextPackage -Recurse -Force
}
Copy-Item -LiteralPath $sourceNextPackage -Destination $standaloneNextPackage -Recurse -Force
$nextPackageInfo = Get-Content -LiteralPath (Join-Path $standaloneNextPackage "package.json") -Raw | ConvertFrom-Json
if (-not $nextPackageInfo.version) { throw "The copied Next.js package does not declare a version." }
Write-Host "Installing the complete production dependency tree for Next.js $($nextPackageInfo.version) into the standalone runtime."
Invoke-Checked "npm" @(
  "install", "--prefix", $standalone, "--no-save", "--no-package-lock",
  "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund",
  "next@$($nextPackageInfo.version)"
) "Installing Next.js runtime dependencies into the standalone package failed."

# Next 16.3+ with @swc/helpers 0.5.17+ adds the Node 22.12+ "module-sync"
# export condition. Node 22/24 resolves the ESM helpers, but Next's standalone
# file tracer may copy only CJS helpers. Explicitly restore the complete ESM tree.
$sourceSwcPackage = Join-Path $source "node_modules/@swc/helpers"
$standaloneSwcPackage = Join-Path $standaloneNodeModules "@swc/helpers"
$sourceSwcEsm = Join-Path $sourceSwcPackage "esm"
$standaloneSwcEsm = Join-Path $standaloneSwcPackage "esm"
if (-not (Test-Path (Join-Path $sourceSwcPackage "package.json"))) {
  throw "The source @swc/helpers package is missing."
}
if (-not (Test-Path $sourceSwcEsm)) {
  throw "The source @swc/helpers ESM directory is missing."
}
$sourceSwcVersion = (Get-Content (Join-Path $sourceSwcPackage "package.json") -Raw | ConvertFrom-Json).version
$standaloneSwcVersion = (Get-Content (Join-Path $standaloneSwcPackage "package.json") -Raw | ConvertFrom-Json).version
if ($sourceSwcVersion -ne $standaloneSwcVersion) {
  throw "Source and standalone @swc/helpers versions differ ($sourceSwcVersion vs $standaloneSwcVersion)."
}
New-Item -ItemType Directory -Force -Path $standaloneSwcPackage | Out-Null
Copy-Item -LiteralPath $sourceSwcEsm -Destination $standaloneSwcPackage -Recurse -Force
foreach ($helper in @("_interop_require_default.js","_interop_require_wildcard.js")) {
  if (-not (Test-Path (Join-Path $standaloneSwcEsm $helper) -PathType Leaf)) {
    throw "Required @swc/helpers ESM file was not copied: $helper"
  }
}
Write-Host "Restored @swc/helpers $standaloneSwcVersion ESM files for Node module-sync resolution."

# Resolve every Turbopack content-hashed external module alias used by the
# server chunks. Next 16 may emit aliases for onnxruntime-node, jpeg-js, and
# other production packages. Keep a real wrapper package for each one.
$standaloneServerChunks = Join-Path $standalone ".next/server/chunks"
if (-not (Test-Path $standaloneServerChunks)) {
  throw "Turbopack server chunks are missing; cannot validate external package aliases."
}
$turbopackAliases = @()
$aliasRegex = [regex]::new('(?<alias>(?:@[A-Za-z0-9._-]+/)?[A-Za-z0-9._-]+-[0-9a-f]{8,32})',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
foreach ($chunk in Get-ChildItem -LiteralPath $standaloneServerChunks -Recurse -File -Filter "*.js") {
  $chunkText = [System.IO.File]::ReadAllText($chunk.FullName)
  foreach ($match in $aliasRegex.Matches($chunkText)) {
    $alias = $match.Groups["alias"].Value
    $packageName = [regex]::Replace($alias,'-[0-9a-f]{8,32}
Push-Location $standalone
try {
  node -e "const p=require.resolve('next/package.json');const swc=require.resolve('@swc/helpers/_/_interop_require_default');const helper=require('@swc/helpers/_/_interop_require_default');const wildcard=require('@swc/helpers/_/_interop_require_wildcard');require('next');console.log('Packaged Next.js and SWC ESM dependencies loaded:',p,'; SWC:',swc,'; helpers:',typeof helper._,typeof wildcard._);"
  if ($LASTEXITCODE -ne 0) { throw "Next.js or one of its runtime dependencies cannot be loaded from the standalone runtime." }
} finally {
  Pop-Location
}

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

# The standalone server is copied directly into resources/app; no runtime extraction is needed.

# Validate model files and load the ONNX graph with the Windows native runtime.
Push-Location $standalone
try {
  node -e "const fs=require('fs');const p='models/mishkefet';const c=JSON.parse(fs.readFileSync(p+'/charset.json','utf8'));if(!Array.isArray(c)||c.length!==198)throw new Error('Unexpected charset');const h=fs.readFileSync(p+'/head.bin');if(h.toString('ascii',0,4)!=='MKH1')throw new Error('Invalid head.bin');for(const f of ['charlm.bin','words.bin'])if(fs.statSync(p+'/'+f).size<1000)throw new Error('Invalid '+f);if(fs.existsSync(p+'/backbone.fp16.onnx'))throw new Error('ONNX model should not be bundled');console.log('Model support assets OK; charset='+c.length+'; ONNX graph excluded');"
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

  $env:CTAV_TURBOPACK_ALIASES = ($turbopackAliases | ForEach-Object { $_.Alias }) -join ";"
  & (Join-Path $smokeNodeDir "node.exe") -e "const path=require('path'),{createRequire}=require('module'),req=createRequire(path.join(process.cwd(),'.next','server','chunks','__aliascheck__.cjs')),aliases=(process.env.CTAV_TURBOPACK_ALIASES||'').split(';').filter(Boolean);for(const alias of aliases){const target=req.resolve(alias);const mod=req(alias);if(alias.startsWith('onnxruntime-node-')&&(!mod.InferenceSession||typeof mod.InferenceSession.create!=='function'))throw new Error('Invalid ONNX alias export: '+alias);console.log('Turbopack alias loaded:',alias,'=>',target)}"
  if ($LASTEXITCODE -ne 0) { throw "A Turbopack hashed external package alias could not be resolved or loaded." }
  Remove-Item Env:CTAV_TURBOPACK_ALIASES -ErrorAction SilentlyContinue

  & (Join-Path $smokeNodeDir "node.exe") -e "const ort=require('onnxruntime-node');if(!ort.InferenceSession||typeof ort.InferenceSession.create!=='function')throw new Error('ONNX binding unavailable');console.log('ONNX native binding loaded; graph supplied externally.');"
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime native binding could not load using the package-matched DLL." }

  if (-not (Test-Path "public/tessdata/heb.traineddata")) { throw "Hebrew Tesseract data is missing." }

  # Start the standalone server once to verify migrations and the embedded local database.
  $env:CTAV_BUILD_MODE = ""
  $env:PGLITE_DATA_DIR = Join-Path $env:RUNNER_TEMP "ctav-yad-smoke-db"
  $env:DATA_DIR = Join-Path $env:RUNNER_TEMP "ctav-yad-smoke-data"
  $env:PORT = "32191"
  $env:HOSTNAME = "127.0.0.1"
  $stdout = Join-Path $env:RUNNER_TEMP "ctav-server-out.log"
  $stderr = Join-Path $env:RUNNER_TEMP "ctav-server-err.log"
  $proc = Start-Process -FilePath (Join-Path $smokeNodeDir "node.exe") -ArgumentList @("server.js") -WorkingDirectory $standalone -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
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
    $baseUrl = "http://127.0.0.1:32191"
    $homeResponse = Invoke-WebRequest -Uri "$baseUrl/" -TimeoutSec 20
    if ($homeResponse.StatusCode -ne 200) { throw "Packaged homepage did not return HTTP 200." }
    $modelCheck = Invoke-WebRequest -Uri "$baseUrl/api/mishkefet/ready" -TimeoutSec 20
    $modelState = $modelCheck.Content | ConvertFrom-Json
    if ($modelState.exists -ne $false) { throw "The build smoke-test unexpectedly found a bundled ONNX backbone." }
    Write-Host "External ONNX model path is reported as missing without crashing the server: $($modelState.modelPath)"
    $chunkRoot = Join-Path $standalone ".next/static/chunks"
    if (-not (Test-Path $chunkRoot)) { throw "Next.js static chunks folder is missing." }
    $chunkFiles = @(Get-ChildItem $chunkRoot -Recurse -File -Filter "*.js")
    if ($chunkFiles.Count -lt 1) { throw "No Next.js JavaScript chunks were produced." }
    foreach ($chunk in $chunkFiles) {
      $relative = $chunk.FullName.Substring($chunkRoot.Length).TrimStart([char[]]"\/").Replace("\","/")
      $chunkResponse = Invoke-WebRequest -Uri "$baseUrl/_next/static/chunks/$relative" -TimeoutSec 20
      if ($chunkResponse.StatusCode -ne 200) { throw "Static JS chunk failed: $relative" }
    }
    foreach ($asset in @("tesseract/worker.min.js","tessdata/heb.traineddata")) {
      $assetPath = Join-Path (Join-Path $standalone "public") ($asset.Replace("/","\"))
      if (Test-Path $assetPath) {
        $assetResponse = Invoke-WebRequest -Uri "$baseUrl/$asset" -TimeoutSec 30
        if ($assetResponse.StatusCode -ne 200) { throw "OCR public asset failed: $asset" }
      }
    }
    Write-Host "Standalone app, database, homepage, $($chunkFiles.Count) JS chunks and OCR static assets passed."
  } finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  }
} finally {
  Pop-Location
}

# Electron Builder writes the complete unpacked application directly to dist/KtavYad.
# No second recursive PowerShell copy is needed.
Set-Location $source
Invoke-Checked "npx" @("electron-builder", "--win", "--dir", "--x64") "electron-builder directory packaging failed."
$builderOutput = Join-Path $packageDir "win-unpacked"
if (-not (Test-Path (Join-Path $builderOutput "KtavYad.exe"))) {
  throw "Electron Builder did not produce the expected win-unpacked/KtavYad.exe."
}
$applicationDir = Join-Path $packageDir "Application"
if (Test-Path $applicationDir) { Remove-Item -LiteralPath $applicationDir -Recurse -Force }
Move-Item -LiteralPath $builderOutput -Destination $applicationDir
$finalExe = Join-Path $applicationDir "KtavYad.exe"
$runtimeServer = Join-Path $applicationDir "resources/runtime/server.js"
$runtimeDir = Join-Path $applicationDir "resources/runtime"

# Recreate the real wrapper directories in the final Electron resources;
# electron-builder may copy broken trace junctions and the ZIP walker skips links.
$unusedTraceModules = Join-Path $runtimeDir ".next/node_modules"
Write-TurbopackAliasWrappers $unusedTraceModules
$runtimeNextPackage = Join-Path $runtimeDir "node_modules/next/package.json"
if (-not (Test-Path $finalExe)) { throw "KtavYad.exe was not produced in the final application folder." }
if (-not (Test-Path $runtimeServer)) { throw "The server runtime folder was not copied into resources/runtime." }
if (-not (Test-Path $runtimeNextPackage)) {
  throw "The final Electron package is missing resources/runtime/node_modules/next/package.json. Refusing to publish a broken app."
}
if (-not (Test-Path (Join-Path $runtimeDir ".next/static/chunks"))) {
  throw "The Next.js static chunks folder is missing from resources/runtime."
}

# Electron Builder can omit transitive runtime packages from extraResources.
# Replace its partial runtime/node_modules with the complete, production-tested
# standalone dependency tree produced above. This keeps every package and its
# package.json together (Next.js, @next/env, SWC, and their transitive dependencies).
$runtimeNodeModules = Join-Path $runtimeDir "node_modules"
if (-not (Test-Path $standaloneNodeModules)) {
  throw "The tested standalone node_modules directory is missing."
}
$standaloneNextEnv = Join-Path $standaloneNodeModules "@next/env/package.json"
if (-not (Test-Path $standaloneNextEnv -PathType Leaf)) {
  throw "The standalone production dependency tree is missing @next/env/package.json."
}
if (Test-Path $runtimeNodeModules) {
  Remove-Item -LiteralPath $runtimeNodeModules -Recurse -Force
}
Copy-Item -LiteralPath $standaloneNodeModules -Destination $runtimeNodeModules -Recurse -Force

$runtimeNextPackage = Join-Path $runtimeNodeModules "next/package.json"
$runtimeNextEnv = Join-Path $runtimeNodeModules "@next/env/package.json"
$runtimeSwcPackage = Join-Path $runtimeNodeModules "@swc/helpers"
$runtimeSwcPackageJson = Join-Path $runtimeSwcPackage "package.json"
$runtimeSwcEsm = Join-Path $runtimeSwcPackage "esm"
if (-not (Test-Path $runtimeNextPackage -PathType Leaf)) {
  throw "Final Electron runtime is missing next/package.json after restoring standalone dependencies."
}
if (-not (Test-Path $runtimeNextEnv -PathType Leaf)) {
  throw "Final Electron runtime is missing @next/env/package.json after restoring standalone dependencies."
}
if (-not (Test-Path $runtimeSwcPackageJson -PathType Leaf)) {
  throw "Final Electron runtime is missing @swc/helpers/package.json."
}
$runtimeSwcVersion = (Get-Content $runtimeSwcPackageJson -Raw | ConvertFrom-Json).version
if ($runtimeSwcVersion -ne $standaloneSwcVersion) {
  throw "Final @swc/helpers version differs from the tested standalone package ($runtimeSwcVersion vs $standaloneSwcVersion)."
}
foreach ($helper in @("_interop_require_default.js","_interop_require_wildcard.js")) {
  if (-not (Test-Path (Join-Path $runtimeSwcEsm $helper) -PathType Leaf)) {
    throw "Final Electron runtime is missing @swc/helpers ESM file: $helper"
  }
}
Write-Host "Restored complete standalone production dependency tree; Next.js, @next/env and @swc/helpers $runtimeSwcVersion are present."
Push-Location $runtimeDir
try {
  node -e "const p=require.resolve('next');const n=require('next/package.json').version;const e=require.resolve('@next/env');const d=require('@swc/helpers/_/_interop_require_default');const w=require('@swc/helpers/_/_interop_require_wildcard');require('next');console.log('Final packaged runtime dependency tree loaded:',n,'resolved to',p,'; @next/env:',e,'; helper exports:',typeof d._,typeof w._)"
  if ($LASTEXITCODE -ne 0) { throw "The final packaged runtime cannot load Next.js or its production dependencies." }
} finally {
  Pop-Location
}
@"
הפעלת הזיהוי האוטומטי:
1. חלץ את תיקיית KtavYad ושמור על מבנה התיקיות.
2. הפעל את Application\KtavYad.exe.
3. בהפעלה הראשונה תתבקש לבחור את קובץ backbone.fp16.onnx. התוכנה תעתיק אותו אוטומטית לתיקייה המתאימה. אין צורך לפתוח תיקיות או להעתיק ידנית.
4. בהפעלות הבאות התוכנה תשתמש בקובץ שכבר נשמר.

קובצי העזר הקטנים (charset.json, charlm.bin, words.bin, head.bin) כלולים בחבילה ונבדקים אוטומטית.
אם תיקיית Application מוגנת לכתיבה, קובץ המודל יישמר בתיקיית הנתונים של המשתמש.
אין צורך להתקין Node.js או Python.
"@ | Set-Content -Path (Join-Path $packageDir "README-Model.txt") -Encoding utf8
Write-Host "APPLICATION EXE: $finalExe"
Write-Host "EXE_SIZE_BYTES: $((Get-Item $finalExe).Length)"
Write-Host "APPLICATION FOLDER: $applicationDir"
Write-Host "RUNTIME FOLDER: $(Join-Path $applicationDir 'resources/runtime')"
Write-Host "MODEL SETUP GUIDE: $(Join-Path $packageDir 'README-Model.txt')"
,'',[System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $packageRelative = $packageName.Replace("/",[System.IO.Path]::DirectorySeparatorChar)
    $standalonePackage = Join-Path $standaloneNodeModules $packageRelative
    $sourcePackage = Join-Path (Join-Path $source "node_modules") $packageRelative
    if (-not (Test-Path (Join-Path $standalonePackage "package.json") -PathType Leaf)) {
      if (Test-Path (Join-Path $sourcePackage "package.json") -PathType Leaf) {
        New-Item -ItemType Directory -Force -Path (Split-Path $standalonePackage -Parent) | Out-Null
        if (Test-Path $standalonePackage) { Remove-Item -LiteralPath $standalonePackage -Recurse -Force }
        Copy-Item -LiteralPath $sourcePackage -Destination $standalonePackage -Recurse -Force
        Write-Host "Restored missing Turbopack dependency package: $packageName"
      } else {
        continue
      }
    }
    if (-not ($turbopackAliases | Where-Object { $_.Alias -eq $alias })) {
      $turbopackAliases += [pscustomobject]@{ Alias = $alias; Package = $packageName }
    }
  }
}
if ($turbopackAliases.Count -lt 1) {
  throw "Turbopack emitted no resolvable hashed external module aliases."
}
$turbopackAliases = @($turbopackAliases | Sort-Object -Property Alias -Unique)
Write-Host "Detected Turbopack aliases: $(($turbopackAliases | ForEach-Object { $_.Alias + ' -> ' + $_.Package }) -join '; ')"

function Write-TurbopackAliasWrappers([string]$Root) {
  $rootInfo = Get-Item -LiteralPath $Root -Force -ErrorAction SilentlyContinue
  if ($rootInfo -and (($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
    & cmd.exe /c rmdir "$Root"
    if ($LASTEXITCODE -ne 0) { throw "Could not remove Turbopack trace junction: $Root" }
  }
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  foreach ($entry in $turbopackAliases) {
    $aliasDir = Join-Path $Root $entry.Alias
    $existingAlias = Get-Item -LiteralPath $aliasDir -Force -ErrorAction SilentlyContinue
    if ($existingAlias) {
      if (($existingAlias.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        if (($existingAlias.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
          & cmd.exe /c rmdir "$aliasDir"
        } else {
          Remove-Item -LiteralPath $aliasDir -Force
        }
        if ($LASTEXITCODE -ne 0) { throw "Could not remove Turbopack alias link: $aliasDir" }
      } else {
        Remove-Item -LiteralPath $aliasDir -Recurse -Force
      }
    }
    New-Item -ItemType Directory -Force -Path $aliasDir | Out-Null
    @{ name = $entry.Alias; version = "1.0.0"; main = "index.cjs"; type = "commonjs" } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $aliasDir "package.json") -Encoding utf8
    ('module.exports = require("' + $entry.Package + '");') |
      Set-Content -LiteralPath (Join-Path $aliasDir "index.cjs") -Encoding utf8
  }
  Write-Host "Wrote $($turbopackAliases.Count) real Turbopack alias wrappers into $Root"
}

$standaloneTraceModules = Join-Path $standalone ".next/node_modules"
Write-TurbopackAliasWrappers $standaloneTraceModules

Push-Location $standalone
try {
  node -e "const p=require.resolve('next/package.json');const swc=require.resolve('@swc/helpers/_/_interop_require_default');const helper=require('@swc/helpers/_/_interop_require_default');const wildcard=require('@swc/helpers/_/_interop_require_wildcard');require('next');console.log('Packaged Next.js and SWC ESM dependencies loaded:',p,'; SWC:',swc,'; helpers:',typeof helper._,typeof wildcard._);"
  if ($LASTEXITCODE -ne 0) { throw "Next.js or one of its runtime dependencies cannot be loaded from the standalone runtime." }
} finally {
  Pop-Location
}

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

# The standalone server is copied directly into resources/app; no runtime extraction is needed.

# Validate model files and load the ONNX graph with the Windows native runtime.
Push-Location $standalone
try {
  node -e "const fs=require('fs');const p='models/mishkefet';const c=JSON.parse(fs.readFileSync(p+'/charset.json','utf8'));if(!Array.isArray(c)||c.length!==198)throw new Error('Unexpected charset');const h=fs.readFileSync(p+'/head.bin');if(h.toString('ascii',0,4)!=='MKH1')throw new Error('Invalid head.bin');for(const f of ['charlm.bin','words.bin'])if(fs.statSync(p+'/'+f).size<1000)throw new Error('Invalid '+f);if(fs.existsSync(p+'/backbone.fp16.onnx'))throw new Error('ONNX model should not be bundled');console.log('Model support assets OK; charset='+c.length+'; ONNX graph excluded');"
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

  & (Join-Path $smokeNodeDir "node.exe") -e "const ort=require('onnxruntime-node');if(!ort.InferenceSession||typeof ort.InferenceSession.create!=='function')throw new Error('ONNX binding unavailable');console.log('ONNX native binding loaded; graph supplied externally.');"
  if ($LASTEXITCODE -ne 0) { throw "ONNX Runtime native binding could not load using the package-matched DLL." }

  if (-not (Test-Path "public/tessdata/heb.traineddata")) { throw "Hebrew Tesseract data is missing." }

  # Start the standalone server once to verify migrations and the embedded local database.
  $env:CTAV_BUILD_MODE = ""
  $env:PGLITE_DATA_DIR = Join-Path $env:RUNNER_TEMP "ctav-yad-smoke-db"
  $env:DATA_DIR = Join-Path $env:RUNNER_TEMP "ctav-yad-smoke-data"
  $env:PORT = "32191"
  $env:HOSTNAME = "127.0.0.1"
  $stdout = Join-Path $env:RUNNER_TEMP "ctav-server-out.log"
  $stderr = Join-Path $env:RUNNER_TEMP "ctav-server-err.log"
  $proc = Start-Process -FilePath (Join-Path $smokeNodeDir "node.exe") -ArgumentList @("server.js") -WorkingDirectory $standalone -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
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
    $baseUrl = "http://127.0.0.1:32191"
    $homeResponse = Invoke-WebRequest -Uri "$baseUrl/" -TimeoutSec 20
    if ($homeResponse.StatusCode -ne 200) { throw "Packaged homepage did not return HTTP 200." }
    $modelCheck = Invoke-WebRequest -Uri "$baseUrl/api/mishkefet/ready" -TimeoutSec 20
    $modelState = $modelCheck.Content | ConvertFrom-Json
    if ($modelState.exists -ne $false) { throw "The build smoke-test unexpectedly found a bundled ONNX backbone." }
    Write-Host "External ONNX model path is reported as missing without crashing the server: $($modelState.modelPath)"
    $chunkRoot = Join-Path $standalone ".next/static/chunks"
    if (-not (Test-Path $chunkRoot)) { throw "Next.js static chunks folder is missing." }
    $chunkFiles = @(Get-ChildItem $chunkRoot -Recurse -File -Filter "*.js")
    if ($chunkFiles.Count -lt 1) { throw "No Next.js JavaScript chunks were produced." }
    foreach ($chunk in $chunkFiles) {
      $relative = $chunk.FullName.Substring($chunkRoot.Length).TrimStart([char[]]"\/").Replace("\","/")
      $chunkResponse = Invoke-WebRequest -Uri "$baseUrl/_next/static/chunks/$relative" -TimeoutSec 20
      if ($chunkResponse.StatusCode -ne 200) { throw "Static JS chunk failed: $relative" }
    }
    foreach ($asset in @("tesseract/worker.min.js","tessdata/heb.traineddata")) {
      $assetPath = Join-Path (Join-Path $standalone "public") ($asset.Replace("/","\"))
      if (Test-Path $assetPath) {
        $assetResponse = Invoke-WebRequest -Uri "$baseUrl/$asset" -TimeoutSec 30
        if ($assetResponse.StatusCode -ne 200) { throw "OCR public asset failed: $asset" }
      }
    }
    Write-Host "Standalone app, database, homepage, $($chunkFiles.Count) JS chunks and OCR static assets passed."
  } finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
  }
} finally {
  Pop-Location
}

# Electron Builder writes the complete unpacked application directly to dist/KtavYad.
# No second recursive PowerShell copy is needed.
Set-Location $source
Invoke-Checked "npx" @("electron-builder", "--win", "--dir", "--x64") "electron-builder directory packaging failed."
$builderOutput = Join-Path $packageDir "win-unpacked"
if (-not (Test-Path (Join-Path $builderOutput "KtavYad.exe"))) {
  throw "Electron Builder did not produce the expected win-unpacked/KtavYad.exe."
}
$applicationDir = Join-Path $packageDir "Application"
if (Test-Path $applicationDir) { Remove-Item -LiteralPath $applicationDir -Recurse -Force }
Move-Item -LiteralPath $builderOutput -Destination $applicationDir
$finalExe = Join-Path $applicationDir "KtavYad.exe"
$runtimeServer = Join-Path $applicationDir "resources/runtime/server.js"
$runtimeDir = Join-Path $applicationDir "resources/runtime"

# Preserve the real Turbopack ONNX alias wrappers. Remove stale symlinks from
# this trace directory without following them, then write plain package folders.
$unusedTraceModules = Join-Path $runtimeDir ".next/node_modules"
$traceModulesItem = Get-Item -LiteralPath $unusedTraceModules -Force -ErrorAction SilentlyContinue
if ($traceModulesItem -and (($traceModulesItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
  & cmd.exe /c rmdir "$unusedTraceModules"
  if ($LASTEXITCODE -ne 0) { throw "Could not remove unused Next.js trace junction: $unusedTraceModules" }
}
New-Item -ItemType Directory -Force -Path $unusedTraceModules | Out-Null
foreach ($alias in $onnxAliases) {
  $aliasDir = Join-Path $unusedTraceModules $alias
  $existingAlias = Get-Item -LiteralPath $aliasDir -Force -ErrorAction SilentlyContinue
  if ($existingAlias) {
    if (($existingAlias.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      if (($existingAlias.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
        & cmd.exe /c rmdir "$aliasDir"
      } else {
        Remove-Item -LiteralPath $aliasDir -Force
      }
      if ($LASTEXITCODE -ne 0) { throw "Could not remove final Turbopack alias junction: $aliasDir" }
    } else {
      Remove-Item -LiteralPath $aliasDir -Recurse -Force
    }
  }
  New-Item -ItemType Directory -Force -Path $aliasDir | Out-Null
  @{ name = $alias; version = "1.0.0"; main = "index.cjs"; type = "commonjs" } |
    ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $aliasDir "package.json") -Encoding utf8
  'module.exports = require("onnxruntime-node");' |
    Set-Content -LiteralPath (Join-Path $aliasDir "index.cjs") -Encoding utf8
}
Write-Host "Final package contains real Turbopack ONNX alias wrappers: $($onnxAliases -join ', ')"
$runtimeNextPackage = Join-Path $runtimeDir "node_modules/next/package.json"
if (-not (Test-Path $finalExe)) { throw "KtavYad.exe was not produced in the final application folder." }
if (-not (Test-Path $runtimeServer)) { throw "The server runtime folder was not copied into resources/runtime." }
if (-not (Test-Path $runtimeNextPackage)) {
  throw "The final Electron package is missing resources/runtime/node_modules/next/package.json. Refusing to publish a broken app."
}
if (-not (Test-Path (Join-Path $runtimeDir ".next/static/chunks"))) {
  throw "The Next.js static chunks folder is missing from resources/runtime."
}

# Electron Builder can omit transitive runtime packages from extraResources.
# Replace its partial runtime/node_modules with the complete, production-tested
# standalone dependency tree produced above. This keeps every package and its
# package.json together (Next.js, @next/env, SWC, and their transitive dependencies).
$runtimeNodeModules = Join-Path $runtimeDir "node_modules"
if (-not (Test-Path $standaloneNodeModules)) {
  throw "The tested standalone node_modules directory is missing."
}
$standaloneNextEnv = Join-Path $standaloneNodeModules "@next/env/package.json"
if (-not (Test-Path $standaloneNextEnv -PathType Leaf)) {
  throw "The standalone production dependency tree is missing @next/env/package.json."
}
if (Test-Path $runtimeNodeModules) {
  Remove-Item -LiteralPath $runtimeNodeModules -Recurse -Force
}
Copy-Item -LiteralPath $standaloneNodeModules -Destination $runtimeNodeModules -Recurse -Force

$runtimeNextPackage = Join-Path $runtimeNodeModules "next/package.json"
$runtimeNextEnv = Join-Path $runtimeNodeModules "@next/env/package.json"
$runtimeSwcPackage = Join-Path $runtimeNodeModules "@swc/helpers"
$runtimeSwcPackageJson = Join-Path $runtimeSwcPackage "package.json"
$runtimeSwcEsm = Join-Path $runtimeSwcPackage "esm"
if (-not (Test-Path $runtimeNextPackage -PathType Leaf)) {
  throw "Final Electron runtime is missing next/package.json after restoring standalone dependencies."
}
if (-not (Test-Path $runtimeNextEnv -PathType Leaf)) {
  throw "Final Electron runtime is missing @next/env/package.json after restoring standalone dependencies."
}
if (-not (Test-Path $runtimeSwcPackageJson -PathType Leaf)) {
  throw "Final Electron runtime is missing @swc/helpers/package.json."
}
$runtimeSwcVersion = (Get-Content $runtimeSwcPackageJson -Raw | ConvertFrom-Json).version
if ($runtimeSwcVersion -ne $standaloneSwcVersion) {
  throw "Final @swc/helpers version differs from the tested standalone package ($runtimeSwcVersion vs $standaloneSwcVersion)."
}
foreach ($helper in @("_interop_require_default.js","_interop_require_wildcard.js")) {
  if (-not (Test-Path (Join-Path $runtimeSwcEsm $helper) -PathType Leaf)) {
    throw "Final Electron runtime is missing @swc/helpers ESM file: $helper"
  }
}
Write-Host "Restored complete standalone production dependency tree; Next.js, @next/env and @swc/helpers $runtimeSwcVersion are present."
Push-Location $runtimeDir
try {
  node -e "const p=require.resolve('next');const n=require('next/package.json').version;const e=require.resolve('@next/env');const d=require('@swc/helpers/_/_interop_require_default');const w=require('@swc/helpers/_/_interop_require_wildcard');require('next');console.log('Final packaged runtime dependency tree loaded:',n,'resolved to',p,'; @next/env:',e,'; helper exports:',typeof d._,typeof w._)"
  if ($LASTEXITCODE -ne 0) { throw "The final packaged runtime cannot load Next.js or its production dependencies." }
} finally {
  Pop-Location
}
@"
הפעלת הזיהוי האוטומטי:
1. חלץ את תיקיית KtavYad ושמור על מבנה התיקיות.
2. הפעל את Application\KtavYad.exe.
3. בהפעלה הראשונה תתבקש לבחור את קובץ backbone.fp16.onnx. התוכנה תעתיק אותו אוטומטית לתיקייה המתאימה. אין צורך לפתוח תיקיות או להעתיק ידנית.
4. בהפעלות הבאות התוכנה תשתמש בקובץ שכבר נשמר.

קובצי העזר הקטנים (charset.json, charlm.bin, words.bin, head.bin) כלולים בחבילה ונבדקים אוטומטית.
אם תיקיית Application מוגנת לכתיבה, קובץ המודל יישמר בתיקיית הנתונים של המשתמש.
אין צורך להתקין Node.js או Python.
"@ | Set-Content -Path (Join-Path $packageDir "README-Model.txt") -Encoding utf8
Write-Host "APPLICATION EXE: $finalExe"
Write-Host "EXE_SIZE_BYTES: $((Get-Item $finalExe).Length)"
Write-Host "APPLICATION FOLDER: $applicationDir"
Write-Host "RUNTIME FOLDER: $(Join-Path $applicationDir 'resources/runtime')"
Write-Host "MODEL SETUP GUIDE: $(Join-Path $packageDir 'README-Model.txt')"
