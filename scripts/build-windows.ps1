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
    signAndEditExecutable = $true
    verifyUpdateCodeSignature = $false
  }
  nsis = @{
    oneClick = $false
    perMachine = $false
    allowToChangeInstallationDirectory = $true
    deleteAppDataOnUninstall = $false
    installerIcon = "resources\icon.ico"
    uninstallerIcon = "resources\icon.ico"
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

# Patch 1: Windows shell quoting for external ACP providers (codex, claude-code, etc.)
# On Windows, shell:true causes cmd.exe to mangle -c key=toml_value args containing
# nested quotes (e.g., -c mcp_servers.x.args=["a","b"]). Use shell:false where possible.
# npm shims (codex.cmd, npx.cmd, etc.) are expanded to `node.exe <bin.js>` so they
# also avoid cmd.exe while remaining runnable from Electron/Node.
$acpProvider = "$ProjectRoot\dist\features\agent\main\agent-providers\acp-provider.js"
if (Test-Path $acpProvider) {
  $content = Get-Content $acpProvider -Raw
  $oldStr = @'
        // On Windows with shell: true, quote the command path to handle spaces
        // (e.g. "C:\Program Files\nodejs\npx.cmd"). Without quotes, cmd.exe splits
        // the path at the space and fails to find the executable.
        if (process.platform === 'win32') {
            spawnCommand = `"${spawnCommand}"`;
        }
        // Spawn the agent process using safe spawn with fallback options
        const spawnOptions = {
            cwd: workingDirectory,
            env: {
                ...process.env,
                ...configEnv,
                // Force unbuffered output
                NODE_NO_READLINE: '1',
                PYTHONUNBUFFERED: '1',
                // Isolate npm cache per agent to prevent cross-provider ENOTEMPTY errors
                ...(agentNpmCachePath ? { NPM_CONFIG_CACHE: agentNpmCachePath } : {}),
            },
            // stdio will be set by safeSpawn
            detached: false,
            shell: process.platform === 'win32',
            windowsHide: true,
        };
'@
  $newStr = @'
        // External providers (codex, claude-code, opencode, cortex) pass -c key=value
        // or --model args that may contain nested quotes (TOML arrays, quoted strings).
        // On Windows, shell:true routes through cmd.exe, which strips/realigns those
        // quotes. Prefer shell:false. npm .cmd shims are not directly runnable with
        // shell:false, so expand them to `node.exe <shim-target.js> ...args`.
        const resolveWindowsNpmShim = (command) => {
            if (process.platform !== 'win32' || !command || caps.id === 'auggie') {
                return null;
            }
            const unquotedCommand = command.replace(/^"(.*)"$/, '$1');
            const commandHasPath = /[\\/]/.test(unquotedCommand);
            const commandExt = path.extname(unquotedCommand).toLowerCase();
            const candidates = [];
            const addCandidate = (candidate) => {
                if (candidate && !candidates.includes(candidate)) {
                    candidates.push(candidate);
                }
            };
            if (commandHasPath) {
                addCandidate(unquotedCommand);
                if (!commandExt) {
                    addCandidate(`${unquotedCommand}.cmd`);
                }
            }
            else {
                const pathEntries = (process.env.PATH || '').split(path.delimiter).filter(Boolean);
                for (const pathEntry of pathEntries) {
                    if (commandExt) {
                        addCandidate(path.join(pathEntry, unquotedCommand));
                    }
                    else {
                        addCandidate(path.join(pathEntry, `${unquotedCommand}.cmd`));
                        addCandidate(path.join(pathEntry, unquotedCommand));
                    }
                }
            }
            for (const candidate of candidates) {
                if (!fs.existsSync(candidate) || fs.statSync(candidate).isDirectory()) {
                    continue;
                }
                const candidateExt = path.extname(candidate).toLowerCase();
                const shimDir = path.dirname(candidate);
                let shimText = '';
                try {
                    shimText = fs.readFileSync(candidate, 'utf8');
                }
                catch {
                    continue;
                }
                let jsTarget = null;
                if (candidateExt === '.cmd' || candidateExt === '.bat') {
                    const match = shimText.match(/"((?:%dp0%|%~dp0%)[^"]+?\.js)"\s+%\*/i);
                    if (match) {
                        jsTarget = match[1]
                            .replace(/%~?dp0%\\?/ig, `${shimDir}\\`)
                            .replace(/\\/g, path.sep);
                    }
                }
                else if (!candidateExt) {
                    const match = shimText.match(/"\$basedir\/([^"]+?\.js)"\s+"\$@"/);
                    if (match) {
                        jsTarget = path.join(shimDir, ...match[1].split('/'));
                    }
                }
                if (!jsTarget || !fs.existsSync(jsTarget)) {
                    continue;
                }
                const localNode = path.join(shimDir, 'node.exe');
                const nodeCommand = fs.existsSync(localNode) ? localNode : 'node.exe';
                return { command: nodeCommand, jsTarget, shimPath: candidate };
            }
            return null;
        };
        const shimResolution = resolveWindowsNpmShim(spawnCommand);
        if (shimResolution) {
            logger.info('Resolved Windows npm shim for shellless spawn', {
                providerId: caps.id,
                originalCommand: spawnCommand,
                shimPath: shimResolution.shimPath,
                nodeCommand: shimResolution.command,
                jsTarget: shimResolution.jsTarget,
            });
            spawnCommand = shimResolution.command;
            args.unshift(shimResolution.jsTarget);
        }
        const needsShellSpawn = process.platform === 'win32' && (
            caps.id === 'auggie' ||
            (!shimResolution && /\.(cmd|bat)$/i.test(spawnCommand))
        );
        if (process.platform === 'win32' && needsShellSpawn) {
            spawnCommand = `"${spawnCommand}"`;
        }
        // Spawn the agent process using safe spawn with fallback options
        const spawnOptions = {
            cwd: workingDirectory,
            env: {
                ...process.env,
                ...configEnv,
                // Force unbuffered output
                NODE_NO_READLINE: '1',
                PYTHONUNBUFFERED: '1',
                // Isolate npm cache per agent to prevent cross-provider ENOTEMPTY errors
                ...(agentNpmCachePath ? { NPM_CONFIG_CACHE: agentNpmCachePath } : {}),
            },
            // stdio will be set by safeSpawn
            detached: false,
            shell: needsShellSpawn,
            windowsHide: true,
        };
'@
  if ($content.Contains($oldStr)) {
    $content = $content.Replace($oldStr, $newStr)
    Set-Content $acpProvider -Value $content -NoNewline
    Write-Host "  ✓ acp-provider shell=true patched for Windows"
  } elseif ($content.Contains("resolveWindowsNpmShim")) {
    Write-Host "  - acp-provider already patched, skipping"
  } else {
    throw "acp-provider patch target not found; upstream spawn block changed"
  }
}

# Patch 2: ssh-config import (CommonJS compat)
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

# Patch 3: Protocol handler renderer path
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

# Patch 4: Replace app-update.yml to point to GitHub Releases
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

# ---- Step 7.5: Copy pre-built Windows .ico icon ----
$iconRepo = Join-Path (Split-Path $PSScriptRoot -Parent) "assets\icon.ico"
$iconDest = "$ProjectRoot\resources\icon.ico"

if (Test-Path $iconRepo) {
  Copy-Item $iconRepo $iconDest -Force
  $icoSize = (Get-Item $iconDest).Length
  Write-Host "  ✓ icon.ico copied ($icoSize bytes)"
} else {
  throw "pre-built icon.ico not found at $iconRepo"
}

if (-not (Test-Path $iconDest) -or (Get-Item $iconDest).Length -le 0) {
  throw "Windows icon is missing or empty at $iconDest"
}

# ---- Step 8: Build Windows installer ----
Write-Host "[8/8] Building Windows installer..." -ForegroundColor Yellow
$InstallerDir = Join-Path $BuildRoot "installer"
Push-Location $ProjectRoot
try {
  npm run build:win 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "electron-builder failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

$MainExe = Join-Path $InstallerDir "win-unpacked\Intent.exe"
if (-not (Test-Path $MainExe)) {
  throw "Built main executable was not found at $MainExe"
}

$versionInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($MainExe)
if ($versionInfo.ProductName -eq "Electron" -or $versionInfo.OriginalFilename -eq "electron.exe") {
  throw "Intent.exe still has Electron default executable resources; icon/resource editing did not run"
}

Write-Host ""
Write-Host "=== Build complete! ===" -ForegroundColor Green
Write-Host "Installer: $(Join-Path $InstallerDir "Intent-Setup-$Version-win-x64.exe")"
