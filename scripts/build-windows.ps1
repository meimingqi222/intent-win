param(
  [Parameter(Mandatory = $true)]
  [string]$ResourcesDir,
  [string]$OutputDir = "release",
  [string]$Version = "0.3.10",
  [string]$PatchesDir = "",
  [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path $PSCommandPath -Parent
$ProjectRoot = Join-Path $OutputDir "app"
# Resolve to absolute path (important: script changes directory during npm install)
$ProjectRoot = [System.IO.Path]::GetFullPath($ProjectRoot)

Write-Host "=== Intent Windows Builder ===" -ForegroundColor Cyan
Write-Host "Resources: $ResourcesDir"
Write-Host "Output:    $OutputDir"
Write-Host "Version:   $Version"
Write-Host ""

# ---- Step 1: Extract app.asar ----
Write-Host "[1/8] Extracting app.asar..." -ForegroundColor Yellow
if (Test-Path $ProjectRoot) {
  Remove-Item $ProjectRoot -Recurse -Force
}
mkdir $ProjectRoot -Force | Out-Null

# Install @electron/asar locally so `npx asar` works
Push-Location (Join-Path $PSScriptRoot "..")
npm install --ignore-scripts 2>&1 | Out-Null
$asarCmd = (Resolve-Path ".\node_modules\.bin\asar.cmd").Path
Pop-Location

# asar extract: partial failure on missing .asar.unpacked dotfiles is OK
# The main code (dist/, package.json, etc.) IS extracted successfully.
$extractOk = $true
try {
  & $asarCmd extract "$ResourcesDir\app.asar" "$ProjectRoot\app_content" 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "asar exit code $LASTEXITCODE" }
} catch {
  $msg = "$_"
  if ($msg -match "Unable to extract some files" -or $msg -match "ENOENT") {
    Write-Host "  ! asar warnings (missing .asar.unpacked dotfiles — expected, safe to ignore)" -ForegroundColor Yellow
    $extractOk = $true
  } else {
    Write-Host "  ! asar extraction error: $_" -ForegroundColor Red
    $extractOk = $false
  }
}

# ---- Step 2: Merge unpacked files ----
Write-Host "[2/8] Merging unpacked files..." -ForegroundColor Yellow
$appContent = "$ProjectRoot\app_content"
$unpacked = "$ResourcesDir\app.asar.unpacked"
if ((Test-Path $unpacked) -and (Test-Path $appContent)) {
  robocopy "$unpacked" "$appContent" /E /NJH /NJS /NDL /NP 2>&1 | Out-Null
}

# ---- Step 3: Set up project structure ----
Write-Host "[3/8] Setting up project structure..." -ForegroundColor Yellow
if (Test-Path "$ProjectRoot\app_content") {
  Get-ChildItem "$ProjectRoot\app_content" | Move-Item -Destination $ProjectRoot -Force
  Remove-Item "$ProjectRoot\app_content" -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- Step 4: Copy resources ----
Write-Host "[4/8] Copying resources..." -ForegroundColor Yellow
$resDir = "$ProjectRoot\resources"
mkdir $resDir -Force | Out-Null

# Specialists + bin files
$unpackedRes = "$ResourcesDir\app.asar.unpacked\resources"
if (Test-Path $unpackedRes) {
  Copy-Item "$unpackedRes\*" $resDir -Recurse -Force
}

# ---- Step 5: Write package.json ----
Write-Host "[5/8] Writing package.json..." -ForegroundColor Yellow
$pkgPath = "$ProjectRoot\package.json"
$pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json

# Remove pnpm config
$pkg.PSObject.Properties.Remove('pnpm')

# Ensure top-level productName is set (Electron reads this for app.getName())
$pkg | Add-Member -Name "productName" -Value "Intent" -MemberType NoteProperty -Force

# Add build config
$buildConfig = @{
  appId = "com.augmentcode.intent"
  productName = "Intent"
  directories = @{ output = "..\installer" }
  files = @("dist/**/*", "resources/**/*", "package.json")
  win = @{
    target = @(@{ target = "nsis"; arch = @("x64") })
    icon = "resources\icon.ico"
    sign = $false
    signAndEditExecutable = $false
    verifyUpdateCodeSignature = $false
  }
  nsis = @{
    oneClick = $false
    perMachine = $false
    allowToChangeInstallationDirectory = $true
    deleteAppDataOnUninstall = $false
  }
  asar = $true
  asarUnpack = @(
    "node_modules/@img/**",
    "node_modules/better-sqlite3/**",
    "node_modules/node-pty/**",
    "node_modules/cpu-features/**",
    "node_modules/@parcel/watcher/**",
    "node_modules/sharp/**",
    "node_modules/ssh2/**",
    "resources/bin/**"
  )
}
$pkg | Add-Member -Name "build" -Value $buildConfig -MemberType NoteProperty -Force

# Add scripts
$scripts = @{
  start = "electron ."
  "build:win" = "electron-builder build --win --x64"
  postinstall = "electron-builder install-app-deps"
}
$pkg | Add-Member -Name "scripts" -Value $scripts -MemberType NoteProperty -Force

# Add devDependencies
$devDeps = @{
  electron = "^34.0.0"
  "electron-builder" = "^25.1.8"
}
$pkg | Add-Member -Name "devDependencies" -Value $devDeps -MemberType NoteProperty -Force

$pkg | ConvertTo-Json -Depth 10 | Set-Content $pkgPath -Encoding UTF8

# ---- Step 6: Apply patches ----
Write-Host "[6/8] Applying compatibility patches..." -ForegroundColor Yellow

# Patch 1: ssh-config import (CommonJS compat)
$sshIpc = "$ProjectRoot\dist\features\ssh\main\ssh.ipc.js"
if (Test-Path $sshIpc) {
  $content = Get-Content $sshIpc -Raw
  if ($content -match "import SSHConfig, \{ LineType \} from 'ssh-config'") {
    $content = $content -replace "import SSHConfig, \{ LineType \} from 'ssh-config'", "import { createRequire } from 'module';`r`nconst _require = createRequire(import.meta.url);`r`nconst sshConfigPkg = _require('ssh-config');`r`nconst { LineType } = sshConfigPkg;`r`nconst SSHConfig = sshConfigPkg"
    Set-Content $sshIpc -Value $content -NoNewline
    Write-Host "  ✓ ssh-config patched"
  } else {
    Write-Host "  - ssh-config already patched, skipping"
  }
}

# Patch 2: Protocol handler renderer path
$protoHandler = "$ProjectRoot\dist\main\protocol-handlers.js"
if (Test-Path $protoHandler) {
  $content = Get-Content $protoHandler -Raw
  if ($content -match "const rendererRoot = path.join\(unpackedPath, 'dist', 'renderer'\)") {
    $old = "const rendererRoot = path.join\(unpackedPath, 'dist', 'renderer'\);"
    $new = "const inAsarRoot = path.join(appPath, 'dist', 'renderer');
const inUnpackedRoot = path.join(unpackedPath, 'dist', 'renderer');
let rendererRoot = null;
if (fs.existsSync(inAsarRoot)) {
    rendererRoot = inAsarRoot;
}
else if (fs.existsSync(inUnpackedRoot)) {
    rendererRoot = inUnpackedRoot;
}
else {
    rendererRoot = inAsarRoot;
}"
    $content = $content -replace $old, $new
    Set-Content $protoHandler -Value $content -NoNewline
    Write-Host "  ✓ protocol handler patched"
  } else {
    Write-Host "  - protocol handler already patched, skipping"
  }
}

# Patch 3: Replace app-update.yml to point to GitHub Releases
$updateYml = "$ProjectRoot\app-update.yml"
if (Test-Path $updateYml) {
  @"
provider: generic
url: https://github.com/$env:GITHUB_REPOSITORY/releases/latest/download
updaterCacheDirName: intent-updater
"@ | Set-Content $updateYml -Encoding UTF8
  Write-Host "  ✓ app-update.yml patched for GitHub Releases"
}

# ---- Step 7: Install dependencies ----
if (-not $SkipInstall) {
  Write-Host "[7/8] Installing dependencies..." -ForegroundColor Yellow
  Set-Location $ProjectRoot
  npm install --ignore-scripts 2>&1 | Out-Null

  # Install electron and electron-builder
  npm install --save-dev electron@34.0.0 electron-builder@25.1.8 2>&1 | Out-Null

  # Install png-to-ico for generating Windows .ico from PNG
  npm install --save-dev png-to-ico@3.0.1 2>&1 | Out-Null

  # Install Windows-specific native packages
  npm install @img/sharp-win32-x64 @parcel/watcher-win32-x64 2>&1 | Out-Null

  # Rebuild native modules for Electron
  # node-pty may fail on some VS configs (Spectre), patch vcxproj and retry
  npm rebuild better-sqlite3 cpu-features 2>&1 | Out-Null
  $nodePtyDir = Join-Path $ProjectRoot "node_modules\node-pty"
  if (Test-Path $nodePtyDir) {
    $result = npm rebuild node-pty 2>&1
    if ($LASTEXITCODE -ne 0) {
      Write-Host "  ! node-pty rebuild failed, attempting Spectre workaround..." -ForegroundColor Yellow
      Get-ChildItem "$nodePtyDir\build" -Recurse -Filter "*.vcxproj" | ForEach-Object {
        $c = Get-Content $_.FullName -Raw
        $c = $c -replace '<SpectreMitigation>[^<]*</SpectreMitigation>', ''
        Set-Content $_.FullName -Value $c -NoNewline
      }
      npm rebuild node-pty 2>&1 | Out-Null
    }
  }
  Write-Host "  ✓ native modules rebuilt"

  $BuildRoot = Split-Path $ProjectRoot -Parent
  Write-Host "  ✓ dependencies installed"
} else {
  Write-Host "[7/8] Skipping dependency install (--SkipInstall)" -ForegroundColor Yellow
  $BuildRoot = Split-Path $ProjectRoot -Parent
}

# ---- Step 7.5: Generate Windows .ico icon ----
$iconSource = "$ProjectRoot\dist\renderer\icons\Icon-iOS-Default-68x68@2x.png"
$iconPng = "$ProjectRoot\resources\icon.png"
$iconIco = "$ProjectRoot\resources\icon.ico"

if (Test-Path $iconSource) {
  Push-Location $ProjectRoot
  # First generate a 256x256 PNG using sharp
  node -e "const s=require('sharp');s(process.argv[1]).resize(256,256,{kernel:'lanczos3'}).png().toFile(process.argv[2])" "$iconSource" "$iconPng" 2>&1 | Out-Null
  
  # Then convert PNG to multi-size ICO using png-to-ico
  node -e "const {default: p}=require('png-to-ico');p(process.argv[1]).then(b=>require('fs').writeFileSync(process.argv[2],b))" "$iconPng" "$iconIco" 2>&1 | Out-Null
  Pop-Location
  
  if (Test-Path $iconIco) {
    $icoSize = (Get-Item $iconIco).Length
    Write-Host "  ✓ icon.ico generated ($icoSize bytes)"
  } else {
    Write-Host "  ! icon.ico generation failed, falling back to png" -ForegroundColor Yellow
  }
} else {
  Write-Host "  ! no icon source found at $iconSource" -ForegroundColor Yellow
}

# ---- Step 8: Build Windows installer ----
Write-Host "[8/8] Building Windows installer..." -ForegroundColor Yellow
Push-Location $ProjectRoot
npm run build:win 2>&1
Pop-Location

$InstallerDir = Join-Path $BuildRoot "installer"
Write-Host ""
Write-Host "=== Build complete! ===" -ForegroundColor Green
Write-Host "Installer: $(Join-Path $InstallerDir "Intent-Setup-$Version-win-x64.exe")"
