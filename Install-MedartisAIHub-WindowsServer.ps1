Clear-Host
$ErrorActionPreference = "Stop"

# Self-elevate if not running as Administrator
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Administrator privileges are required. Requesting elevation..." -ForegroundColor Yellow
    if ($PSCommandPath) {
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    } else {
        # Fallback if running via pipeline
        $scriptPath = "$env:TEMP\updater_elevated.ps1"
        $MyInvocation.MyCommand.ScriptBlock.ToString() | Out-File $scriptPath
        Start-Process powershell.exe -ArgumentList "-ExecutionPolicy Bypass -File `"$scriptPath`"" -Verb RunAs
    }
    exit
}

Write-Host "=========================================="
Write-Host "  Medartis AI Hub - Windows Server Installer"
Write-Host "=========================================="
Write-Host ""

# 1. Install Node.js if missing
$nodeVersion = (node -v) 2>$null
if (-not $nodeVersion) {
    Write-Host "[1/4] Node.js not found. Downloading and installing Node.js..." -ForegroundColor Cyan
    $nodeInstaller = "$env:TEMP\node-installer.msi"
    Invoke-WebRequest "https://nodejs.org/dist/v22.9.0/node-v22.9.0-x64.msi" -OutFile $nodeInstaller
    Start-Process msiexec.exe -ArgumentList "/i $nodeInstaller /quiet /norestart" -Wait -NoNewWindow
    Write-Host "Node.js installed! (You might need to restart the script if it still can't find 'node')" -ForegroundColor Green
    
    # Refresh environment variables in current session
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
}
else {
    Write-Host "[1/4] Node.js is already installed ($nodeVersion)" -ForegroundColor Green
}

# 2. Authentication
$InstallDir = "C:\MedartisAIHub"
if (-Not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
$CredFile = Join-Path $InstallDir ".github-credentials.txt"

if (Test-Path $CredFile) {
    Write-Host "`n[2/4] Found saved credentials for 1-click updates!" -ForegroundColor Green
    $CredContent = Get-Content $CredFile
    $GitHubUsername = ($CredContent | Select-String "Username:" | Out-String).Split(":")[-1].Trim()
    $PlainToken = ($CredContent | Select-String "Token:" | Out-String).Split(":")[-1].Trim()
}
else {
    Write-Host "`n[2/4] Authentication Required" -ForegroundColor Cyan
    $GitHubUsername = Read-Host "Enter your GitHub Username"
    $GitHubToken = Read-Host "Enter your GitHub Personal Access Token (PAT)" -AsSecureString
    $PlainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($GitHubToken))
    
    "Username: $GitHubUsername`nToken: $PlainToken" | Set-Content $CredFile -Force
}

$Headers = @{
    Authorization = "token $PlainToken"
    Accept        = "application/vnd.github.v3+json"
    "User-Agent"  = "MedartisAIHub-Installer"
}

# 3. Fetch latest release
Write-Host "`n[3/4] Finding latest Windows build in the cloud..." -ForegroundColor Cyan
$ReleasesUrl = "https://api.github.com/repos/proitassist/medartisaihub/releases/latest"

try {
    $Release = Invoke-RestMethod -Uri $ReleasesUrl -Headers $Headers
    
    # Also fetch the friendly app version from the version.json file
    try {
        $VersionJson = Invoke-RestMethod -Uri "https://raw.githubusercontent.com/proitassist/medartisaihub-updater/main/version.json" -UseBasicParsing
        Write-Host "Discovered cloud version: $($VersionJson.version)" -ForegroundColor Green
    } catch {
        Write-Host "Discovered cloud build: $($Release.tag_name)" -ForegroundColor Green
    }
}
catch {
    Write-Host ""
    Write-Host "GitHub API Request Failed!" -ForegroundColor Red
    Write-Host "Error Details: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ErrorDetails) {
        Write-Host "Response from GitHub: $($_.ErrorDetails.Message)" -ForegroundColor Yellow
    }
    Write-Host "If this says 'Not Found', your PAT token might not have 'repo' access or the repository is fully empty." -ForegroundColor Yellow
    Write-Host ""
    Pause
    exit
}

$Asset = $Release.assets | Where-Object { $_.name -eq "Medartis-Windows-Build.zip" }
if (-not $Asset) {
    Write-Host "Error: Could not find Medartis-Windows-Build.zip in the latest release!" -ForegroundColor Red
    Pause
    exit
}

# 4. Download and Extract
$ZipPath = Join-Path $InstallDir "Medartis-Windows-Build.zip"
Write-Host "Downloading the pre-compiled application ($($Asset.size / 1MB | ForEach-Object ToString "0.00") MB)..." -ForegroundColor Yellow

$request = [System.Net.WebRequest]::Create($Asset.url)
$request.UserAgent = "MedartisAIHub-Installer"
$request.Headers.Add("Authorization", "token $PlainToken")
$request.Accept = "application/octet-stream"

$response = $request.GetResponse()
$totalBytes = $response.ContentLength
$stream = $response.GetResponseStream()

$fileStream = [System.IO.File]::Create($ZipPath)
$buffer = New-Object byte[] 81920
$read = 0
$downloadedBytes = 0
$lastUpdate = [datetime]::Now

while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
    $fileStream.Write($buffer, 0, $read)
    $downloadedBytes += $read
    
    if (([datetime]::Now - $lastUpdate).TotalMilliseconds -gt 500) {
        if ($totalBytes -gt 0) {
            $percent = [math]::Round(($downloadedBytes / $totalBytes) * 100)
            $downloadedMB = [math]::Round($downloadedBytes / 1MB, 2)
            $totalMB = [math]::Round($totalBytes / 1MB, 2)
            Write-Progress -Activity "Downloading Application" -Status "$percent% ($downloadedMB MB / $totalMB MB)" -PercentComplete $percent -Id 1
        }
        $lastUpdate = [datetime]::Now
    }
}

$fileStream.Close()
$stream.Close()
$response.Close()
Write-Progress -Activity "Downloading Application" -Completed -Id 1

Write-Host "Stopping any running instances of Medartis AI Hub & Watchdog..." -ForegroundColor Yellow

# Try to stop the Scheduled Task gracefully
try {
    Stop-ScheduledTask -TaskName "MedartisAIHub_Watchdog" -ErrorAction SilentlyContinue
} catch {}

# Stop any lingering powershell Watchdog processes
$powershells = Get-WmiObject Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'"
foreach ($p in $powershells) {
    if ($p.CommandLine -match "Watchdog") {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

# Stop the node server itself
Stop-Process -Name "node" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Write-Host "Extracting application files..." -ForegroundColor Yellow
& tar.exe -xf $ZipPath -C $InstallDir
Remove-Item -Path $ZipPath -Force

# 5. Create Desktop Shortcuts
Write-Host "`n[4/4] Creating Desktop Shortcuts..." -ForegroundColor Cyan
$StartBatPath = Join-Path $InstallDir "Start-Medartis.bat"
$StartBatContent = @"
@echo off
echo Starting Medartis AI Hub on Windows Server...

echo Stopping any background node processes, Watchdog, and freeing port 3000...
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Stop-ScheduledTask -TaskName 'MedartisAIHub_Watchdog' -ErrorAction SilentlyContinue } catch {}; Get-WmiObject Win32_Process -Filter 'Name=''powershell.exe'' OR Name=''pwsh.exe''' | Where-Object { `$_.CommandLine -match 'Watchdog' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }; Get-WmiObject Win32_Process -Filter 'Name=''node.exe''' | Where-Object { `$_.CommandLine -match 'MedartisAIHub' -or `$_.CommandLine -match 'server.js' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }; Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id `$_.OwningProcess -Force -ErrorAction SilentlyContinue }"

cd /d "C:\MedartisAIHub"
set NODE_ENV=production

start /B powershell -NoProfile -Command "Start-Sleep -Seconds 4; Start-Process 'https://localhost:3000'"
node server.js
pause
"@
Set-Content -Path $StartBatPath -Value $StartBatContent

$WshShell = New-Object -comObject WScript.Shell
$DesktopPath = [Environment]::GetFolderPath("Desktop")

# Start Shortcut
$Shortcut = $WshShell.CreateShortcut("$DesktopPath\Start Medartis AI Hub.lnk")
$Shortcut.TargetPath = $StartBatPath
$Shortcut.Description = "Start Medartis AI Hub"
$Shortcut.IconLocation = "%SystemRoot%\System32\SHELL32.dll,14"
$Shortcut.Save()

# Update Shortcut
$UpdateShortcut = $WshShell.CreateShortcut("$DesktopPath\Update Medartis AI Hub.lnk")
$UpdateShortcut.TargetPath = "powershell.exe"
$UpdateShortcut.Arguments = "-ExecutionPolicy Bypass -Command `"Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/proitassist/medartisaihub-updater/main/Install-MedartisAIHub-WindowsServer.ps1' -OutFile '$env:TEMP\updater.ps1'; & '$env:TEMP\updater.ps1'`""
$UpdateShortcut.Description = "Update Medartis AI Hub"
$UpdateShortcut.IconLocation = "%SystemRoot%\System32\SHELL32.dll,47"
$UpdateShortcut.Save()

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host "  Installation Complete!                  " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green

Write-Host "Restarting Medartis AI Hub Watchdog..." -ForegroundColor Yellow
$taskStarted = $false
try {
    Start-ScheduledTask -TaskName "MedartisAIHub_Watchdog" -ErrorAction Stop
    Write-Host "Watchdog scheduled task successfully restarted!" -ForegroundColor Green
    $taskStarted = $true
} catch {
    Write-Host "Could not automatically start the Watchdog scheduled task." -ForegroundColor Yellow
    Write-Host "If you haven't set it up yet, use the 'Start Medartis AI Hub' Desktop shortcut for now." -ForegroundColor Yellow
}

if (-not $taskStarted) {
    Write-Host "Please start Medartis AI Hub manually using the Desktop shortcut." -ForegroundColor Yellow
}

Write-Host "Waiting for Medartis AI Hub to boot up (this may take up to 20 seconds)..." -ForegroundColor Yellow
$MaxWaitSeconds = 40
$WaitCount = 0
$AppIsUp = $false

while ($WaitCount -lt $MaxWaitSeconds) {
    try {
        $request = [System.Net.WebRequest]::Create("http://localhost:3000")
        $request.Timeout = 2000
        $request.Method = "GET"
        $response = $request.GetResponse()
        $response.Close()
        $AppIsUp = $true
        break
    } catch {
        Start-Sleep -Seconds 2
        $WaitCount += 2
        Write-Host "." -NoNewline
    }
}

Write-Host ""

if ($AppIsUp) {
    Write-Host "Application is online! Opening in default browser..." -ForegroundColor Green
    Start-Process "https://localhost:3000"
} else {
    Write-Host "Application is taking longer than expected to start." -ForegroundColor Yellow
    Write-Host "You can open https://localhost:3000 in your browser manually in a few moments." -ForegroundColor Yellow
}
