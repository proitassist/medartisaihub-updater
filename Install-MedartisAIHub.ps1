<#
.SYNOPSIS
Installs and launches the Medartis AI Hub via Docker.

.DESCRIPTION
This script automates the deployment of the Medartis AI Hub.
It checks for Docker, prompts for GitHub credentials to access the private container registry,
generates the required configuration files, and starts the application.
#>

$ErrorActionPreference = "Stop"
$AppDir = "C:\MedartisAIHub"
$ImageName = "ghcr.io/proitassist/medartisaihub:latest"

# 1. Require Administrator Privileges
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "This script requires Administrator privileges to configure Docker."
    Write-Host "Please right-click this script and select 'Run with PowerShell' or open an elevated PowerShell prompt." -ForegroundColor Yellow
    Pause
    exit
}

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Medartis AI Hub - Installation Wizard   " -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# 2. Check for Docker Desktop
Write-Host "[1/5] Checking for Docker..." -ForegroundColor Yellow
if (-not (Get-Command "docker" -ErrorAction SilentlyContinue)) {
    Write-Host "Docker is not installed on this system." -ForegroundColor Red
    Write-Host "Downloading Docker Desktop Installer..." -ForegroundColor Cyan
    
    $InstallerPath = "$env:TEMP\DockerDesktopInstaller.exe"
    Invoke-WebRequest -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -OutFile $InstallerPath
    
    Write-Host "Installing Docker Desktop (this may take a few minutes)..." -ForegroundColor Cyan
    Start-Process -FilePath $InstallerPath -ArgumentList "install", "--quiet", "--accept-license" -Wait -NoNewWindow
    
    Write-Host "Docker Desktop installed! You may need to restart your computer and run this script again." -ForegroundColor Magenta
    Pause
    exit
} else {
    Write-Host "Docker is already installed!" -ForegroundColor Green
}

# Ensure Docker engine is running
Write-Host "Starting Docker Engine if it's not already running..." -ForegroundColor Yellow
Start-Process "C:\Program Files\Docker\Docker\Docker Desktop.exe" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 10

# 3. Authenticate with GitHub Container Registry
Write-Host ""
Write-Host "[2/5] Authentication Required" -ForegroundColor Yellow
Write-Host "To download the secure Medartis container, please provide your license details."
$GitHubUsername = Read-Host "Enter your GitHub Username"
$GitHubToken = Read-Host "Enter your GitHub Personal Access Token (PAT)" -AsSecureString

$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($GitHubToken)
$PlainToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

Write-Host "Logging into GitHub Container Registry (ghcr.io)..." -ForegroundColor Cyan
$PlainToken | docker login ghcr.io -u $GitHubUsername --password-stdin
if ($LASTEXITCODE -ne 0) {
    Write-Host "Authentication failed! Please check your Token and try again." -ForegroundColor Red
    Pause
    exit
}
Write-Host "Authentication successful!" -ForegroundColor Green

# Update the ImageName to use their actual username
$ImageName = "ghcr.io/$($GitHubUsername.ToLower())/medartisaihub:latest"

# 4. Create App Directory and Config
Write-Host ""
Write-Host "[3/5] Configuring Application Environment..." -ForegroundColor Yellow
if (-not (Test-Path $AppDir)) {
    New-Item -ItemType Directory -Path $AppDir | Out-Null
}

$ComposeContent = @"
version: '3.8'

services:
  medartis-ai-hub:
    image: $ImageName
    container_name: MedartisAIHub
    restart: unless-stopped
    ports:
      - "3000:3000"
      - "80:80"
    volumes:
      - ./data/db:/app/db
      - ./data/uploads:/app/public/uploads/articles
      - ./data/logs:/app/logs
    environment:
      - NODE_ENV=production

  watchtower:
    image: containrrr/watchtower
    container_name: watchtower
    restart: unless-stopped
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_HTTP_API_UPDATE=true
      - WATCHTOWER_HTTP_API_TOKEN=medartis-internal-update-token
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - WATCHTOWER_INCLUDE_STOPPED=true
      - REPO_USER=`${GH_USER}
      - REPO_PASS=`${GH_PAT}
    ports:
      - "8080:8080"
    command: --interval 31536000
"@

$ComposePath = Join-Path $AppDir "docker-compose.yml"
Set-Content -Path $ComposePath -Value $ComposeContent

$EnvContent = @"
GH_USER=$GitHubUsername
GH_PAT=$PlainToken
"@
$EnvPath = Join-Path $AppDir ".env"
Set-Content -Path $EnvPath -Value $EnvContent
Write-Host "Configuration files created in $AppDir" -ForegroundColor Green

# 5. Fetch and Start the Container
Write-Host ""
Write-Host "[4/5] Downloading and Starting Medartis AI Hub..." -ForegroundColor Yellow
Set-Location $AppDir
docker compose pull
docker compose up -d

if ($LASTEXITCODE -ne 0) {
    Write-Host "Failed to start the container. Please check Docker Desktop." -ForegroundColor Red
    Pause
    exit
}

# 6. Create Desktop Shortcut
Write-Host ""
Write-Host "[5/5] Creating Desktop Shortcut..." -ForegroundColor Yellow
$WshShell = New-Object -comObject WScript.Shell
$DesktopPath = [Environment]::GetFolderPath("Desktop")
$Shortcut = $WshShell.CreateShortcut("$DesktopPath\Medartis AI Hub.lnk")
$Shortcut.TargetPath = "https://localhost:3000"
$Shortcut.Description = "Open Medartis AI Hub"
$Shortcut.IconLocation = "%SystemRoot%\System32\SHELL32.dll,14" # Globe icon
$Shortcut.Save()

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Installation Complete!                  " -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host "The application is now running securely in the background."
Write-Host "You can access it anytime by double-clicking the 'Medartis AI Hub' shortcut on your Desktop!" -ForegroundColor Cyan
Write-Host "Or by visiting: https://localhost:3000"
Write-Host ""
Write-Host "Press any key to exit..."
$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
