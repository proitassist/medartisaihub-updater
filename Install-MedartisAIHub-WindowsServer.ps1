$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

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
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
} else {
    Write-Host "[1/4] Node.js is already installed ($nodeVersion)" -ForegroundColor Green
}

# 2. Authentication
Write-Host "`n[2/4] Authentication Required" -ForegroundColor Cyan
$GitHubUsername = Read-Host "Enter your GitHub Username"
$GitHubToken = Read-Host "Enter your GitHub Personal Access Token (PAT)" -AsSecureString
$PlainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto([System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($GitHubToken))

$Headers = @{
    Authorization = "Bearer $PlainToken"
    Accept = "application/vnd.github.v3+json"
}

# 3. Fetch latest release
Write-Host "`n[3/4] Finding latest Windows build in the cloud..." -ForegroundColor Cyan
$ReleasesUrl = "https://api.github.com/repos/proitassist/medartisaihub/releases/latest"

try {
    $Release = Invoke-RestMethod -Uri $ReleasesUrl -Headers $Headers
} catch {
    Write-Host "Authentication failed! Make sure your PAT token is correct and has repo access." -ForegroundColor Red
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
$InstallDir = "C:\MedartisAIHub"
if (-Not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }

$ZipPath = Join-Path $InstallDir "Medartis-Windows-Build.zip"
Write-Host "Downloading the pre-compiled application ($($Asset.size / 1MB | ForEach-Object ToString "0.00") MB)..." -ForegroundColor Yellow

$AssetHeaders = @{
    Authorization = "Bearer $PlainToken"
    Accept = "application/octet-stream"
}
Invoke-WebRequest -Uri $Asset.url -Headers $AssetHeaders -OutFile $ZipPath

Write-Host "Extracting application files..." -ForegroundColor Yellow
Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
Remove-Item -Path $ZipPath -Force

# 5. Create Start Shortcut
Write-Host "`n[4/4] Creating Desktop Shortcut..." -ForegroundColor Cyan
$StartBatPath = Join-Path $InstallDir "Start-Medartis.bat"
$StartBatContent = @"
@echo off
echo Starting Medartis AI Hub on Windows Server...
cd /d "C:\MedartisAIHub"
set NODE_ENV=production
node server.js
pause
"@
Set-Content -Path $StartBatPath -Value $StartBatContent

$WshShell = New-Object -comObject WScript.Shell
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$Shortcut = $WshShell.CreateShortcut("$DesktopPath\Start Medartis AI Hub.lnk")
$Shortcut.TargetPath = $StartBatPath
$Shortcut.Description = "Start Medartis AI Hub"
$Shortcut.IconLocation = "%SystemRoot%\System32\SHELL32.dll,14"
$Shortcut.Save()

Write-Host "`n==========================================" -ForegroundColor Green
Write-Host "  Installation Complete!                  " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "You can now double click 'Start Medartis AI Hub' on your Desktop to run the app natively!"
Write-Host "It will start a black window and host the application at http://localhost:3000"
Write-Host ""
Pause
