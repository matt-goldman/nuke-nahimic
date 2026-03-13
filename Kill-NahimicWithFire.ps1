#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Permanently removes Nahimic/A-Volute software from a Lenovo Legion system.

.DESCRIPTION
    Performs complete removal in the correct order:
      1. Stops and deletes Nahimic services
      2. Removes driver packages from the Windows driver store
      3. Deletes Nahimic files from System32 (taking ownership as needed)
      4. Applies ACL deny rules to block execution even if files return
      5. Configures group policy to block device installation
      6. Cleans up registry entries

    Run from an elevated PowerShell prompt, ideally in Safe Mode.
    Safe Mode prevents the service and drivers from being loaded,
    which avoids file-in-use errors during deletion.

.NOTES
    Author : Matt Goldman
    Repo   : https://github.com/matt-goldman/nuke-nahimic
    Version: 1.0
    Tested : Windows 11 24H2, Lenovo Legion 9i

    If Nahimic returns after running this script, run it again -
    it is idempotent and safe to run multiple times.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n>>> $Message" -ForegroundColor Cyan
}

function Write-Done {
    param([string]$Message)
    Write-Host "    OK  $Message" -ForegroundColor Green
}

function Write-Skip {
    param([string]$Message)
    Write-Host "    --  $Message" -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    !!  $Message" -ForegroundColor Yellow
}

function Deny-FileAccess {
    param([string]$FilePath)
    try {
        & takeown /f $FilePath /a 2>$null | Out-Null
        & icacls $FilePath /grant "Administrators:F" 2>$null | Out-Null

        $acl = Get-Acl $FilePath
        $deny = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "Everyone", "FullControl", "Deny")
        $denySystem = New-Object System.Security.AccessControl.FileSystemAccessRule(
            "SYSTEM", "FullControl", "Deny")
        $acl.SetAccessRule($deny)
        $acl.SetAccessRule($denySystem)
        Set-Acl $FilePath $acl
        Write-Done "ACL deny applied: $([System.IO.Path]::GetFileName($FilePath))"
    }
    catch {
        Write-Warn "Could not apply ACL to $FilePath`: $_"
    }
}

function Remove-FileForced {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) {
        Write-Skip "Not found: $([System.IO.Path]::GetFileName($FilePath))"
        return
    }
    try {
        & takeown /f $FilePath /a 2>$null | Out-Null
        & icacls $FilePath /grant "Administrators:F" 2>$null | Out-Null
        Remove-Item $FilePath -Force
        Write-Done "Deleted: $([System.IO.Path]::GetFileName($FilePath))"
    }
    catch {
        Write-Warn "Could not delete $FilePath`: $_ - applying ACL deny instead"
        Deny-FileAccess $FilePath
    }
}

# ── Banner ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  Nahimic Nuclear Removal Script" -ForegroundColor Magenta
Write-Host "  Lenovo Legion / Windows 11" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

$inSafeMode = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option" -ErrorAction SilentlyContinue)
if (-not $inSafeMode) {
    Write-Host ""
    Write-Host "  NOTE: Not running in Safe Mode." -ForegroundColor Yellow
    Write-Host "  Safe Mode is recommended - some files may be locked." -ForegroundColor Yellow
    Write-Host "  The script will attempt ACL denial on any locked files." -ForegroundColor Yellow
}

Write-Host ""

# ── Step 1: Stop and delete services ─────────────────────────────────────────

Write-Step "Step 1: Stopping and removing Nahimic services"

$nahimicServices = @(
    "NahimicService",
    "NahimicBTLink",
    "Nahimic_Mirroring",
    "NahimicXVAD"
)

foreach ($svc in $nahimicServices) {
    $existing = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
            Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
            & sc.exe delete $svc 2>$null | Out-Null
            Write-Done "Service removed: $svc"
        }
        catch {
            Write-Warn "Could not fully remove service $svc`: $_"
        }
    }
    else {
        Write-Skip "Service not present: $svc"
    }
}

# ── Step 2: Remove from driver store ─────────────────────────────────────────

Write-Step "Step 2: Removing Nahimic/A-Volute packages from driver store"

$driverPackages = Get-WindowsDriver -Online |
    Where-Object { $_.ProviderName -like "*Nahimic*" -or $_.ProviderName -like "*A-Volute*" }

if ($driverPackages) {
    foreach ($pkg in $driverPackages) {
        try {
            & pnputil /delete-driver $pkg.Driver /uninstall /force 2>$null | Out-Null
            Write-Done "Driver store entry removed: $($pkg.Driver) ($($pkg.OriginalFileName | Split-Path -Leaf))"
        }
        catch {
            Write-Warn "Could not remove driver package $($pkg.Driver)`: $_"
        }
    }
}
else {
    Write-Skip "No Nahimic/A-Volute packages found in driver store"
}

# ── Step 3: Disable PnP devices ──────────────────────────────────────────────

Write-Step "Step 3: Disabling Nahimic PnP devices"

$devices = Get-PnpDevice | Where-Object { $_.FriendlyName -like "*Nahimic*" }

if ($devices) {
    foreach ($device in $devices) {
        try {
            Disable-PnpDevice -InstanceId $device.InstanceId -Confirm:$false
            Write-Done "Device disabled: $($device.FriendlyName)"
        }
        catch {
            Write-Warn "Could not disable device $($device.FriendlyName)`: $_"
        }
    }
}
else {
    Write-Skip "No Nahimic PnP devices found"
}

# ── Step 4: Delete System32 files ────────────────────────────────────────────

Write-Step "Step 4: Deleting Nahimic files from System32"

$system32 = "$env:SystemRoot\System32"
$system32Files = Get-ChildItem "$system32\Nahimic*" -ErrorAction SilentlyContinue

if ($system32Files) {
    foreach ($f in $system32Files) {
        Remove-FileForced $f.FullName
    }
}
else {
    Write-Skip "No Nahimic files found in System32"
}

# ── Step 5: Delete driver store repository folders ───────────────────────────

Write-Step "Step 5: Cleaning up driver store repository folders"

$driverStorePaths = @(
    "$env:SystemRoot\System32\DriverStore\FileRepository\avolutenh3ext.inf_amd64*",
    "$env:SystemRoot\System32\DriverStore\FileRepository\nahimicbtlink.inf_amd64*",
    "$env:SystemRoot\System32\DriverStore\FileRepository\nahimicxvad.inf_amd64*",
    "$env:SystemRoot\System32\DriverStore\FileRepository\nahimic_mirroring.inf_amd64*",
    "$env:SystemRoot\System32\DriverStore\FileRepository\a-volutenhapo4swc.inf_amd64*"
)

foreach ($pattern in $driverStorePaths) {
    $folders = Get-Item $pattern -ErrorAction SilentlyContinue
    foreach ($folder in $folders) {
        try {
            & takeown /f $folder.FullName /r /a /d y 2>$null | Out-Null
            & icacls $folder.FullName /grant "Administrators:F" /t 2>$null | Out-Null
            Remove-Item $folder.FullName -Recurse -Force
            Write-Done "Removed driver store folder: $($folder.Name)"
        }
        catch {
            Write-Warn "Could not remove $($folder.FullName)`: $_"
        }
    }
    if (-not (Get-Item $pattern -ErrorAction SilentlyContinue)) {
        Write-Skip "Not found: $([System.IO.Path]::GetFileName($pattern.TrimEnd('*')))*"
    }
}

# ── Step 6: Apply ACL deny to any remaining files ────────────────────────────

Write-Step "Step 6: Applying ACL deny rules to any remaining Nahimic files"

$remainingFiles = Get-ChildItem "$system32\Nahimic*" -ErrorAction SilentlyContinue

if ($remainingFiles) {
    Write-Warn "Some files could not be deleted - applying ACL deny as fallback"
    foreach ($f in $remainingFiles) {
        Deny-FileAccess $f.FullName
    }
}
else {
    Write-Done "No remaining files to ACL - clean deletion successful"
}

# ── Step 7: Registry cleanup ─────────────────────────────────────────────────

Write-Step "Step 7: Cleaning up registry entries"

$registryPaths = @(
    "HKLM:\SYSTEM\CurrentControlSet\Services\NahimicService",
    "HKLM:\SYSTEM\CurrentControlSet\Services\NahimicBTLink",
    "HKLM:\SYSTEM\CurrentControlSet\Services\Nahimic_Mirroring",
    "HKLM:\SYSTEM\CurrentControlSet\Services\NahimicXVAD"
)

foreach ($path in $registryPaths) {
    if (Test-Path $path) {
        try {
            Remove-Item $path -Recurse -Force
            Write-Done "Registry key removed: $path"
        }
        catch {
            Write-Warn "Could not remove registry key $path`: $_"
        }
    }
    else {
        Write-Skip "Registry key not present: $path"
    }
}

# ── Step 8: Group policy device installation block ───────────────────────────

Write-Step "Step 8: Configuring group policy to block Nahimic device installation"

$restrictionsPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
$denyIDsPath = "$restrictionsPath\DenyDeviceIDs"

# Ensure the policy keys exist
New-Item -Path $restrictionsPath -Force | Out-Null
New-Item -Path $denyIDsPath -Force | Out-Null

# Enable the deny list
Set-ItemProperty -Path $restrictionsPath -Name "DenyDeviceIDs" -Value 1 -Type DWord -Force
# Also block already-installed devices
Set-ItemProperty -Path $restrictionsPath -Name "DenyDeviceIDsRetroactive" -Value 1 -Type DWord -Force

$deviceIDs = @(
    "ROOT\NahimicBTLink",
    "ROOT\Nahimic_Mirroring",
    "ROOT\NahimicXVAD"
)

# Read existing entries to avoid duplicates
$existingEntries = @{}
$existingValues = Get-ItemProperty -Path $denyIDsPath -ErrorAction SilentlyContinue
if ($existingValues) {
    $existingValues.PSObject.Properties |
        Where-Object { $_.Name -match '^\d+$' } |
        ForEach-Object { $existingEntries[$_.Value] = $_.Name }
}

# Find next available index
$nextIndex = 1
if ($existingEntries.Count -gt 0) {
    $nextIndex = ($existingEntries.Values | ForEach-Object { [int]$_ } | Measure-Object -Maximum).Maximum + 1
}

foreach ($id in $deviceIDs) {
    if ($existingEntries.ContainsKey($id)) {
        Write-Skip "Already in deny list: $id"
    }
    else {
        Set-ItemProperty -Path $denyIDsPath -Name "$nextIndex" -Value $id -Type String -Force
        Write-Done "Added to deny list: $id"
        $nextIndex++
    }
}

# ── Step 9: Block driver reinstall via Windows Update ────────────────────────

Write-Step "Step 9: Configuring Windows Update to exclude driver packages"

$wuPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
New-Item -Path $wuPolicyPath -Force | Out-Null
Set-ItemProperty -Path $wuPolicyPath -Name "ExcludeWUDriversInQualityUpdate" -Value 1 -Type DWord -Force
Write-Done "Windows Update driver exclusion enabled"
Write-Warn "Note: This prevents ALL driver updates via Windows Update."
Write-Warn "      Update drivers manually from nvidia.com / Lenovo support as needed."

# ── Step 10: Scheduled task to re-apply policy after Windows Update ───────────

Write-Step "Step 10: Creating scheduled task to re-apply group policy block"

$taskName = "NahimicPolicyGuard"
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

if ($existingTask) {
    Write-Skip "Scheduled task already exists: $taskName"
}
else {
    $scriptBlock = @'
$restrictionsPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions"
$denyIDsPath = "$restrictionsPath\DenyDeviceIDs"
New-Item -Path $restrictionsPath -Force | Out-Null
New-Item -Path $denyIDsPath -Force | Out-Null
Set-ItemProperty -Path $restrictionsPath -Name "DenyDeviceIDs" -Value 1 -Type DWord -Force
Set-ItemProperty -Path $restrictionsPath -Name "DenyDeviceIDsRetroactive" -Value 1 -Type DWord -Force
$ids = @("ROOT\NahimicBTLink","ROOT\Nahimic_Mirroring","ROOT\NahimicXVAD")
$i = 1
foreach ($id in $ids) {
    Set-ItemProperty -Path $denyIDsPath -Name "$i" -Value $id -Type String -Force
    $i++
}
'@

    $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptBlock))

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NonInteractive -NoProfile -EncodedCommand $encodedScript"

    $trigger = New-ScheduledTaskTrigger -AtStartup

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew

    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Trigger $trigger `
        -Principal $principal `
        -Settings $settings `
        -Description "Re-applies Nahimic device installation block after Windows Update" `
        -Force | Out-Null

    Write-Done "Scheduled task created: $taskName (runs at startup as SYSTEM)"
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  Removal complete. Summary:" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host ""

$remainingServices = Get-Service -Name "Nahimic*" -ErrorAction SilentlyContinue
$remainingFiles    = Get-ChildItem "$system32\Nahimic*" -ErrorAction SilentlyContinue
$remainingDrivers  = Get-WindowsDriver -Online |
    Where-Object { $_.ProviderName -like "*Nahimic*" -or $_.ProviderName -like "*A-Volute*" }

if ($remainingServices) {
    Write-Host "  SERVICES STILL PRESENT:" -ForegroundColor Red
    $remainingServices | ForEach-Object { Write-Host "    - $($_.Name) [$($_.Status)]" -ForegroundColor Red }
}
else {
    Write-Host "  Services:     Clean" -ForegroundColor Green
}

if ($remainingFiles) {
    Write-Host "  SYSTEM32 FILES STILL PRESENT (ACL deny applied):" -ForegroundColor Yellow
    $remainingFiles | ForEach-Object { Write-Host "    - $($_.Name)" -ForegroundColor Yellow }
}
else {
    Write-Host "  System32:     Clean" -ForegroundColor Green
}

if ($remainingDrivers) {
    Write-Host "  DRIVER STORE ENTRIES STILL PRESENT:" -ForegroundColor Red
    $remainingDrivers | ForEach-Object { Write-Host "    - $($_.Driver) ($($_.ProviderName))" -ForegroundColor Red }
}
else {
    Write-Host "  Driver store: Clean" -ForegroundColor Green
}

Write-Host "  Policy block: Applied (survives reboot via scheduled task)" -ForegroundColor Green
Write-Host "  WU drivers:   Excluded" -ForegroundColor Green
Write-Host ""
Write-Host "  Reboot to complete removal." -ForegroundColor Cyan
Write-Host "  After reboot, verify with:" -ForegroundColor Cyan
Write-Host "    Get-Service -Name 'Nahimic*'" -ForegroundColor Cyan
Write-Host "    Get-ChildItem 'C:\Windows\System32\Nahimic*'" -ForegroundColor Cyan
Write-Host "    Get-WindowsDriver -Online | Where-Object { `$_.ProviderName -like '*Nahimic*' }" -ForegroundColor Cyan
Write-Host ""