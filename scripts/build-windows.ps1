param(
  [Parameter(Mandatory = $true)]
  [string]$ResourcesDir,
  [string]$OutputDir = "release",
  [string]$Version = "0.3.10",
  [string]$PatchesDir = "",
  [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Join-Path $OutputDir "app"

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

# Use Node.js script for robust extraction (handles missing unpacked dotfiles gracefully)
node "$PSScriptRoot\extract-asar.js" "$ResourcesDir\app.asar" "$ProjectRoot\app_content"

# ---- Step 2: Merge unpacked files ----
Write-Host "[2/8] Merging unpacked files..." -ForegroundColor Yellow
$unpacked = "$ResourcesDir\app.asar.unpacked"
if (Test-Path $unpacked) {
  Copy-Item "$unpacked\*" "$ProjectRoot\app_content" -Recurse -Force
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

# Icon — prefer pre-generated .ico (from patches), fallback to .icns → convert
if (-not [string]::IsNullOrEmpty($PatchesDir) -and (Test-Path "$PatchesDir\icon.ico")) {
  Copy-Item "$PatchesDir\icon.ico" $resDir -Force
  Write-Host "  ✓ icon.ico from patches"
}
elseif (Test-Path "$ResourcesDir\icon.ico") {
  Copy-Item "$ResourcesDir\icon.ico" $resDir -Force
  Write-Host "  ✓ icon.ico from resources"
}
else {
  # Generate .ico from the iOS PNG (upscale to 256x256)
  $iconPng = "$ProjectRoot\dist\renderer\icons\Icon-iOS-Default-68x68@2x.png"
  if (Test-Path $iconPng) {
    try {
      $sharp = npm pack @img/sharp-win32-x64 2>&1 | Out-Null
      # Use built-in Node.js to create minimal ICO (PNG-based)
      $pngBuf = [System.IO.File]::ReadAllBytes($iconPng)
      # Pad/scale via simple nearest-neighbor (we just need a valid .ico)
      Add-Type -AssemblyName System.Drawing
      $img = [System.Drawing.Image]::FromStream([System.IO.MemoryStream]::new($pngBuf))
      $bmp = New-Object System.Drawing.Bitmap(256, 256)
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
      $g.DrawImage($img, 0, 0, 256, 256)
      $g.Dispose()
      $ms = [System.IO.MemoryStream]::new()
      $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
      $png256 = $ms.ToArray()
      $bmp.Dispose()
      $img.Dispose()
      # Write ICO header + PNG as first (and only) entry
      $fs = [System.IO.File]::Open("$resDir\icon.ico", [System.IO.FileMode]::Create)
      $writer = [System.IO.BinaryWriter]::new($fs)
      $writer.Write([UInt16]0)     # reserved
      $writer.Write([UInt16]1)     # ICO type
      $writer.Write([UInt16]1)     # 1 image
      $writer.Write([byte]0)       # width (0=256)
      $writer.Write([byte]0)       # height (0=256)
      $writer.Write([byte]0)       # colors
      $writer.Write([byte]0)       # reserved
      $writer.Write([UInt16]1)     # color planes
      $writer.Write([UInt16]32)    # bits per pixel
      $writer.Write([UInt32]$png256.Length)  # size
      $writer.Write([UInt32]22)    # offset (6+16)
      $writer.Write($png256)
      $writer.Dispose()
      $fs.Dispose()
      Write-Host "  ✓ icon.ico generated (256x256)"
    }
    catch {
      Write-Host "  ! icon generation failed: $_" -ForegroundColor Yellow
      # Copy .icns as fallback
      if (Test-Path "$ResourcesDir\icon.icns") {
        Copy-Item "$ResourcesDir\icon.icns" $resDir -Force
      }
    }
  }
}

# ---- Step 5: Write package.json ----
Write-Host "[5/8] Writing package.json..." -ForegroundColor Yellow
$pkgPath = "$ProjectRoot\package.json"
$pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json

# Remove pnpm config
$pkg.PSObject.Properties.Remove('pnpm')

# Add build config
$buildConfig = @{
  appId = "com.augmentcode.intent"
  productName = "Intent"
  directories = @{ output = "..\installer" }
  files = @("dist/**/*", "resources/**/*", "package.json")
  win = @{
    target = @(@{ target = "nsis"; arch = @("x64") })
    icon = "resources\icon.ico"
    artifactName = "Intent-Setup-$Version-win-x64.${ext}"
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

# Patch 4: Check for other ESM/CJS issues
$esmIssues = @(
  @{ file = "node_modules/ssh-config/package.json"; addTypeModule = $true }
)
foreach ($issue in $esmIssues) {
  $fp = Join-Path $ProjectRoot $issue.file
  if ($issue.addTypeModule -and (Test-Path $fp)) {
    $pkg2 = Get-Content $fp -Raw | ConvertFrom-Json
    if (-not $pkg2.type) {
      $pkg2 | Add-Member -Name "type" -Value "module" -MemberType NoteProperty -Force
      $pkg2 | ConvertTo-Json -Depth 5 | Set-Content $fp -Encoding UTF8
      Write-Host "  ✓ fixed $($issue.file)"
    }
  }
}

# ---- Step 7: Install dependencies ----
if (-not $SkipInstall) {
  Write-Host "[7/8] Installing dependencies..." -ForegroundColor Yellow
  Set-Location $ProjectRoot
  npm install --ignore-scripts 2>&1 | Out-Null

  # Install electron and electron-builder
  npm install --save-dev electron@34.0.0 electron-builder@25.1.8 2>&1 | Out-Null

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

  $BuildRoot = (Resolve-Path "$ProjectRoot\..").Path
  Write-Host "  ✓ dependencies installed"
} else {
  Write-Host "[7/8] Skipping dependency install (--SkipInstall)" -ForegroundColor Yellow
  $BuildRoot = (Resolve-Path "$ProjectRoot\..").Path
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
