$ErrorActionPreference = "Stop"

function Show-SmokeLogs([string]$LogFile) {
  if (Test-Path -LiteralPath $LogFile) {
    Write-Host "----- KtavYad packaged EXE server log (last 160 lines) -----"
    Get-Content -LiteralPath $LogFile -Tail 160 | ForEach-Object { Write-Host $_ }
    Write-Host "----- end server log -----"
  } else {
    Write-Host "No packaged EXE server log was created at: $LogFile"
  }
}

$packageDir = Join-Path $env:GITHUB_WORKSPACE "dist/KtavYad"
$appDir = Join-Path $packageDir "Application"
$exePath = Join-Path $appDir "KtavYad.exe"
$modelSource = Join-Path $env:GITHUB_WORKSPACE "dist/model-asset/backbone.fp16.onnx"
$testRoot = Join-Path $env:RUNNER_TEMP "ktavyad-electron-smoke"
$marker = Join-Path $testRoot "startup-marker.json"
$logFile = Join-Path $testRoot "KtavYad-Data/logs/server.log"
$proc = $null

foreach ($required in @($exePath, $modelSource)) {
  if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
    throw "Packaged EXE smoke test is missing required input: $required"
  }
}
$modelInfo = Get-Item -LiteralPath $modelSource
if ($modelInfo.Length -lt 50MB) {
  throw "The external ONNX model is too small for the packaged EXE smoke test: $($modelInfo.Length) bytes"
}
if (Test-Path -LiteralPath $testRoot) {
  Remove-Item -LiteralPath $testRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "models/mishkefet") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "AppData/Roaming") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $testRoot "AppData/Local") | Out-Null
$modelCopy = Join-Path $testRoot "models/mishkefet/backbone.fp16.onnx"
Copy-Item -LiteralPath $modelSource -Destination $modelCopy
if ((Get-Item -LiteralPath $modelCopy).Length -ne $modelInfo.Length) {
  throw "The ONNX model copy for the packaged EXE smoke test is incomplete."
}

# Reserve an ephemeral local port and pass it to the actual Electron launcher.
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
$port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()

$env:PORTABLE_EXECUTABLE_DIR = $testRoot
$env:CTAV_SMOKE_TEST = "1"
$env:CTAV_FIXED_PORT = [string]$port
$env:CTAV_SMOKE_TEST_MARKER = $marker
$env:APPDATA = Join-Path $testRoot "AppData/Roaming"
$env:LOCALAPPDATA = Join-Path $testRoot "AppData/Local"

Write-Host "Launching the real packaged Windows executable: $exePath"
Write-Host "Using external model asset: $([math]::Round($modelInfo.Length / 1MB, 1)) MB"
Write-Host "Expected local server endpoint: http://127.0.0.1:$port"

try {
  $proc = Start-Process -FilePath $exePath -PassThru -WindowStyle Hidden
  $started = $false
  for ($i = 0; $i -lt 150; $i++) {
    $proc.Refresh()
    if ($proc.HasExited) {
      Show-SmokeLogs $logFile
      throw "KtavYad.exe exited before startup completed (exit code $($proc.ExitCode))."
    }
    if (Test-Path -LiteralPath $marker -PathType Leaf) {
      $started = $true
      break
    }
    Start-Sleep -Seconds 1
  }
  if (-not $started) {
    Show-SmokeLogs $logFile
    throw "KtavYad.exe did not start its embedded server and load the homepage within 150 seconds."
  }

  $startup = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
  $baseUrl = [string]$startup.baseUrl
  if ($baseUrl -ne "http://127.0.0.1:$port") {
    throw "Packaged EXE reported an unexpected local server URL: $baseUrl"
  }
  Write-Host "Electron launcher created its startup marker after the server and homepage loaded."

  $health = Invoke-WebRequest -Uri "$baseUrl/api/health" -TimeoutSec 15
  if ($health.StatusCode -ne 200) { throw "Packaged EXE health endpoint did not return HTTP 200." }
  Write-Host "Packaged EXE health endpoint passed."

  $homeResponse = Invoke-WebRequest -Uri "$baseUrl/" -TimeoutSec 30
  if ($homeResponse.StatusCode -ne 200 -or $homeResponse.Content.Length -lt 1000) {
    throw "Packaged EXE homepage response is empty or unhealthy."
  }
  if ($homeResponse.Content -notmatch "כתב יד") {
    throw "Packaged EXE homepage did not return the expected Hebrew application UI."
  }
  Write-Host "Packaged EXE homepage returned the Hebrew application UI."

  $scripts = @()
  foreach ($match in [regex]::Matches($homeResponse.Content, 'src=([^ >]+\.js[^ >]*)')) {
    $src = $match.Groups[1].Value.Trim([char]34).Trim([char]39)
    if ($src -and -not ($scripts -contains $src)) { $scripts += $src }
  }
  if ($scripts.Count -lt 1) {
    throw "The packaged EXE homepage did not reference any JavaScript bundles."
  }
  foreach ($src in $scripts) {
    $scriptUrl = if ($src.StartsWith("http")) { $src } else { ([uri]::new([uri]$baseUrl, $src)).AbsoluteUri }
    $asset = Invoke-WebRequest -Uri $scriptUrl -TimeoutSec 30
    if ($asset.StatusCode -ne 200 -or $asset.Content.Length -lt 100) {
      throw "Packaged EXE JavaScript bundle failed to load: $scriptUrl"
    }
  }
  Write-Host "Packaged EXE loaded $($scripts.Count) JavaScript bundles."

  $modelState = Invoke-RestMethod -Uri "$baseUrl/api/mishkefet/ready" -Method Get -TimeoutSec 20
  if ($modelState.exists -ne $true) {
    throw "Packaged EXE could not see the external ONNX model: $($modelState.modelPath)"
  }
  Write-Host "Packaged EXE resolved the external ONNX model path."

  # This exercises the actual Electron-launched server, native ONNX binding,
  # bundled Windows DLL and model graph. Missing local devices are not tested.
  Write-Host "Loading the ONNX model through the packaged EXE runtime..."
  $ready = Invoke-RestMethod -Uri "$baseUrl/api/mishkefet/ready" -Method Post -TimeoutSec 240
  if ($ready.ready -ne $true) {
    throw "The packaged EXE could not initialize the ONNX model: $($ready.error)"
  }
  Write-Host "PACKAGED EXE SMOKE TEST PASSED: Electron, local server, Hebrew UI, JS bundles, external model and ONNX native runtime."
} catch {
  Show-SmokeLogs $logFile
  throw
} finally {
  if ($proc) {
    $proc.Refresh()
    if (-not $proc.HasExited) {
      Write-Host "Stopping the packaged EXE smoke-test process tree."
      & taskkill.exe /PID $proc.Id /T /F 2>$null | Out-Null
    }
  }
}
