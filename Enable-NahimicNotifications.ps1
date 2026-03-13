#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs a scheduled task that monitors for Nahimic file resurrection
    and fires a Windows toast notification if any are detected.

.DESCRIPTION
    Installs two components:
      1. A monitoring script saved to disk that checks for Nahimic files
         and sends a toast notification if any are found
      2. A scheduled task that runs the monitor every 30 minutes

    The notification includes a timestamp and file count, useful for
    correlating detections with Windows Update activity.

.NOTES
    To uninstall:
        Unregister-ScheduledTask -TaskName "NahimicMonitor" -Confirm:$false
        Remove-Item "C:\ProgramData\NahimicMonitor\Monitor-Nahimic.ps1" -Force

    To check task history:
        Get-ScheduledTaskInfo -TaskName "NahimicMonitor"
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$taskName   = "NahimicMonitor"
$scriptDir  = "C:\ProgramData\NahimicMonitor"
$scriptPath = "$scriptDir\Monitor-Nahimic.ps1"
$logPath    = "$scriptDir\detections.log"

# -- The monitor script --------------------------------------------------------
# This gets saved to disk and executed by the scheduled task.
# It runs as the current user (not SYSTEM) so toast notifications are visible.

$monitorScript = @'
$logPath = "C:\ProgramData\NahimicMonitor\detections.log"

# Check for Nahimic files
$nahimicFiles    = @(Get-ChildItem "C:\Windows\System32\Nahimic*"    -ErrorAction SilentlyContinue)
$nahimicDrivers  = @(Get-ChildItem "C:\Windows\System32\drivers\Nahimic*" -ErrorAction SilentlyContinue)
$nahimicServices = @(Get-Service -Name "Nahimic*" -ErrorAction SilentlyContinue |
                     Where-Object { $_.Status -eq 'Running' })

$allFindings = $nahimicFiles + $nahimicDrivers
$timestamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

if ($allFindings.Count -eq 0 -and $nahimicServices.Count -eq 0) {
    exit 0
}

# Build detail string
$details = [System.Collections.Generic.List[string]]::new()
if ($nahimicFiles.Count -gt 0) {
    $details.Add("$($nahimicFiles.Count) file(s) in System32")
}
if ($nahimicDrivers.Count -gt 0) {
    $details.Add("$($nahimicDrivers.Count) driver(s) in System32\drivers")
}
if ($nahimicServices.Count -gt 0) {
    $details.Add("$($nahimicServices.Count) service(s) running")
}
$detailString = $details -join ", "

# Log detection
$logEntry = "[$timestamp] DETECTED: $detailString"
Add-Content -Path $logPath -Value $logEntry -Encoding UTF8

# Fire toast notification
try {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $fileList = ($allFindings | Select-Object -First 5 | ForEach-Object { $_.Name }) -join ", "
    if ($allFindings.Count -gt 5) { $fileList += " ..." }

    $template = @"
<toast duration="long">
    <visual>
        <binding template="ToastGeneric">
            <text>⚠ Nahimic has returned</text>
            <text>$detailString detected at $timestamp</text>
            <text>$fileList</text>
        </binding>
    </visual>
    <actions>
        <action content="Open Log" activationType="protocol" arguments="file:///C:/ProgramData/NahimicMonitor/detections.log"/>
    </actions>
</toast>
"@

    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml($template)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Nahimic Monitor").Show($toast)
}
catch {
    # Toast failed - log it but don't crash
    Add-Content -Path $logPath -Value "[$timestamp] Toast notification failed: $_" -Encoding UTF8
}
'@

# -- Install -------------------------------------------------------------------

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  Nahimic Monitor - Installation" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host ""

# Create directory and save monitor script
if (-not (Test-Path $scriptDir)) {
    New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
}
Set-Content -Path $scriptPath -Value $monitorScript -Encoding UTF8
Write-Host "  OK  Monitor script saved to: $scriptPath" -ForegroundColor Green

# Create log file if it doesn't exist
if (-not (Test-Path $logPath)) {
    $header = "Nahimic Monitor - Detection Log`nInstalled: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`n$('-' * 60)"
    Set-Content -Path $logPath -Value $header -Encoding UTF8
}
Write-Host "  OK  Detection log: $logPath" -ForegroundColor Green

# Remove existing task if present
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "  --  Removed existing task" -ForegroundColor DarkGray
}

# The task runs as the current logged-in user so toast notifications are visible
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""

# Run at logon, then repeat every 30 minutes indefinitely
$triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $currentUser

$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable:$false

$principal = New-ScheduledTaskPrincipal `
    -UserId $currentUser `
    -LogonType Interactive `
    -RunLevel Highest

$task = Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $triggerLogon `
    -Principal $principal `
    -Settings $settings `
    -Description "Monitors for Nahimic file resurrection and fires a toast notification if detected. See $logPath for history." `
    -Force

# Add the 30-minute repeating trigger via XML (New-ScheduledTaskTrigger doesn't support repetition cleanly)
$taskXml = [xml]($task | Export-ScheduledTask)
$ns      = "http://schemas.microsoft.com/windows/2004/02/mit/task"

$triggerNode = $taskXml.Task.Triggers.LogonTrigger
$repetition  = $taskXml.CreateElement("Repetition", $ns)

$interval         = $taskXml.CreateElement("Interval", $ns)
$interval.InnerText = "PT30M"

$duration         = $taskXml.CreateElement("Duration", $ns)
$duration.InnerText = "P9999D"

$stopAtEnd        = $taskXml.CreateElement("StopAtDurationEnd", $ns)
$stopAtEnd.InnerText = "false"

$repetition.AppendChild($interval)  | Out-Null
$repetition.AppendChild($duration)  | Out-Null
$repetition.AppendChild($stopAtEnd) | Out-Null
$triggerNode.AppendChild($repetition) | Out-Null

# Re-register with the updated XML
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
Register-ScheduledTask -TaskName $taskName -Xml $taskXml.OuterXml -Force | Out-Null

Write-Host "  OK  Scheduled task installed: $taskName" -ForegroundColor Green
Write-Host "      Runs at logon, then every 30 minutes" -ForegroundColor DarkGray
Write-Host "      Running as: $currentUser" -ForegroundColor DarkGray

# Run it once immediately so you know it works
Write-Host ""
Write-Host "  Running monitor now to verify..." -ForegroundColor Cyan
& powershell.exe -NonInteractive -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $scriptPath

# Check log for immediate result
Start-Sleep -Seconds 2
$lastLog = Get-Content $logPath -Tail 3 -ErrorAction SilentlyContinue
if ($lastLog -match "DETECTED") {
    Write-Host "  !! Nahimic detected on first run - check notification and log" -ForegroundColor Yellow
}
else {
    Write-Host "  OK  First run clean - no Nahimic detected" -ForegroundColor Green
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  Installation complete." -ForegroundColor Magenta
Write-Host ""
Write-Host "  You will receive a toast notification if Nahimic" -ForegroundColor White
Write-Host "  returns. Detections are logged to:" -ForegroundColor White
Write-Host "  $logPath" -ForegroundColor Cyan
Write-Host ""
Write-Host "  To uninstall:" -ForegroundColor White
Write-Host "  Unregister-ScheduledTask -TaskName '$taskName' -Confirm:`$false" -ForegroundColor Cyan
Write-Host "  Remove-Item '$scriptDir' -Recurse -Force" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host ""