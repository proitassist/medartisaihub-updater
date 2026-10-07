# ==============================================================================
# Watchdog (Scheduled Task) for Medartis AI Hub
# ==============================================================================
# SECURITY BEST PRACTICE (LEAST PRIVILEGE):
# To prevent hackers from gaining full server control if the app is compromised,
# do NOT run this task as SYSTEM or Administrator. Instead:
#   A) Use a standard, restricted Windows User or Domain User.
#   B) Give this user "Full Control" over the C:\MedartisAIHub folder (via Properties -> Security).
#   C) Domain Users must be granted the "Log on as a batch job" right via Group Policy (gpmc.msc) 
#      or Local Security Policy (secpol.msc).
#
# HOW TO INSTALL IN TASK SCHEDULER:
# 1. Open "Task Scheduler" on Windows Server and click "Create Task...".
# 2. General Tab: 
#    - Name: "MedartisAIHub_Watchdog"
#    - Change User or Group: Select your restricted user.
#    - Check "Run whether user is logged on or not".
#    - Leave "Run with highest privileges" UNCHECKED (for security).
# 3. Triggers Tab: New -> Begin the task: "At startup".
# 4. Actions Tab: New -> Action: "Start a program". 
#    - Program/script: powershell.exe
#    - Add arguments: -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\MedartisAIHub\Watchdog (Scheduled Task).ps1"
# 5. Settings Tab: Uncheck "Stop the task if it runs longer than: 3 days".
# ==============================================================================

$AppUrl = "http://127.0.0.1:3000"
$InstallDir = "C:\MedartisAIHub"
$LogFile = "$InstallDir\Watchdog.log"
$MaxConsecutiveRestarts = 5

function Write-Log($Message) {
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] $Message"
    Write-Host $LogMessage
    Add-Content -Path $LogFile -Value $LogMessage
}

function Start-App {
    Write-Log "Starting Medartis AI Hub..."
    $Env:NODE_ENV = "production"
    $Env:HTTP_PORT = "3080" # Avoid Port 80 conflict with IIS on Windows Server
    
    # Try to find the absolute path of Node, as background users might not have it in their PATH
    $NodePath = "node.exe"
    if (Test-Path "C:\Program Files\nodejs\node.exe") {
        $NodePath = "C:\Program Files\nodejs\node.exe"
    } elseif (Test-Path "C:\Program Files (x86)\nodejs\node.exe") {
        $NodePath = "C:\Program Files (x86)\nodejs\node.exe"
    }

    # Start the app silently in the background, redirecting output for debugging
    Start-Process -FilePath $NodePath -ArgumentList "server.js" -WorkingDirectory $InstallDir -WindowStyle Hidden -RedirectStandardOutput "$InstallDir\node_out.log" -RedirectStandardError "$InstallDir\node_err.log"
    
    Write-Log "Waiting 15 seconds for application to boot..."
    Start-Sleep -Seconds 15
}

function Kill-App {
    Write-Log "Attempting to kill existing node processes running server.js..."
    $processes = Get-WmiObject Win32_Process -Filter "Name='node.exe'"
    foreach ($p in $processes) {
        if ($p.CommandLine -match "server.js") {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Log "Killed node process with ID $($p.ProcessId)"
        }
    }
}

$ConsecutiveRestarts = 0
Write-Log "Watchdog started. Monitoring $AppUrl"

# Initial cleanup and start
Kill-App
Start-App

while ($true) {
    Start-Sleep -Seconds 5
    
    try {
        # Create request with tight timeout
        $request = [System.Net.WebRequest]::Create($AppUrl)
        $request.Timeout = 10000 # 10 seconds max wait
        $request.Method = "GET"
        
        $response = $request.GetResponse()
        $response.Close()
        
        # If no exception was thrown, the app is responsive
        if ($ConsecutiveRestarts -gt 0) {
            Write-Log "Application is responsive again. Resetting restart counter."
            $ConsecutiveRestarts = 0
        }
    }
    catch {
        Write-Log "Health check failed: $($_.Exception.Message)"
        
        $ConsecutiveRestarts++
        Write-Log "Consecutive restarts: $ConsecutiveRestarts / $MaxConsecutiveRestarts"
        
        if ($ConsecutiveRestarts -ge $MaxConsecutiveRestarts) {
            Write-Log "CRITICAL: Reached maximum consecutive restarts ($MaxConsecutiveRestarts). Watchdog will stop trying for 5 minutes to prevent CPU spinning."
            Start-Sleep -Seconds 300
            $ConsecutiveRestarts = 0 # Reset to try again later
        }
        
        Kill-App
        Start-App
    }
}
