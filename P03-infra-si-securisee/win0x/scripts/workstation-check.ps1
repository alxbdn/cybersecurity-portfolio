#Requires -RunAsAdministrator
<#
    workstation-check.ps1
    Run on win01 or win02 AFTER the join and reboot, as local admin:
        powershell -ExecutionPolicy Bypass -File .\workstation-check.ps1
    Checks the OU and the GPOs: session lock, no RDP for local admins, AppLocker (win02 only), LAPS.
    Also enables the built-in Administrator: the account LAPS manages.

    Then, logged on as .\Administrator with the LAPS password (proves LAPS works):
        powershell -ExecutionPolicy Bypass -File .\workstation-check.ps1 -Cleanup
    deletes the temporary local accounts.
#>
param(
    [switch]$Cleanup
)
$ErrorActionPreference = 'Stop'

function Step($Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Result($OK, $Text) {
    if ($OK) { Write-Host "  OK  $Text" -ForegroundColor Green }
    else     { Write-Host "  KO  $Text" -ForegroundColor Red }
}
function Get-PolicyValue($Key, $Name) {
    (Get-ItemProperty -Path "Registry::$Key" -Name $Name -ErrorAction SilentlyContinue).$Name
}
$TempAccounts = 'setup', 'tmp-setup'
$Admin        = Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' }   # name depends on language

# --- Cleanup (2nd run) ----------------------------------------------------------------
if ($Cleanup) {
    Step "Delete temporary local accounts"
    # Never leave the PC without a usable local admin
    if (-not $Admin.Enabled) { throw "$($Admin.Name) is disabled: run this script without -Cleanup first." }
    # Real account of this process ($env:USERNAME is wrong in a UAC-elevated window)
    $Me = ([Security.Principal.WindowsIdentity]::GetCurrent().Name -split '\\')[-1]
    foreach ($Name in $TempAccounts) {
        if ($Name -eq $Me) { Write-Host "  !  $Name is the current session: log on as .\$($Admin.Name)" -ForegroundColor Yellow; continue }
        if (Get-LocalUser -Name $Name -ErrorAction SilentlyContinue) {
            Remove-LocalUser -Name $Name
            Write-Host "  -  $Name deleted"
        }
    }
    # Profile folder + registry entry (fails if the profile is loaded: reboot first)
    Get-CimInstance Win32_UserProfile |
        Where-Object { $_.LocalPath -match '\\(setup|tmp-setup)$' } |
        ForEach-Object { Remove-CimInstance $_; Write-Host "  -  profile $($_.LocalPath) deleted" }
    Get-LocalUser | Format-Table Name, Enabled, Description -AutoSize
    return
}

# --- 1. Domain and OU ----------------------------------------------------------------
Step "1. Domain and OU"
$System = Get-CimInstance Win32_ComputerSystem
Result ($System.PartOfDomain -and $System.Domain -eq 'p03.lan') "member of $($System.Domain), name $env:COMPUTERNAME"
Result (Test-ComputerSecureChannel) "secure channel with ad01"
gpupdate /force /target:computer | Out-Null
# Read from the local GPO state (works from a local account, unlike gpresult)
$GPState    = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine'
$ComputerDN = "$((Get-ItemProperty -Path $GPState -ErrorAction SilentlyContinue).'Distinguished-Name')"
$ExpectedOU = if ($env:COMPUTERNAME -eq 'win01') { 'OU=Postes-Admin' } else { 'OU=Postes-Utilisateurs' }
Result ($ComputerDN -like "*$ExpectedOU*") "computer object: $ComputerDN"
Write-Host "  GPOs applied to the computer:"
Get-ChildItem "$GPState\GPO-List" -ErrorAction SilentlyContinue |
    ForEach-Object { (Get-ItemProperty $_.PSPath).DisplayName } |
    Where-Object { $_ -like 'GPO-P03*' } | ForEach-Object { Write-Host "     $_" }

# --- 2. GPO settings ------------------------------------------------------------------
Step "2. Settings received"
Result ((Get-PolicyValue 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System' 'InactivityTimeoutSecs') -eq 600) `
    "session lock at 600 s"

$Rights = Join-Path $env:TEMP 'rights.inf'
secedit /export /areas USER_RIGHTS /cfg $Rights | Out-Null
$DenyRDP = Select-String -Path $Rights -Pattern '^SeDenyRemoteInteractiveLogonRight' | Select-Object -First 1
Remove-Item $Rights
Result ("$DenyRDP" -like '*S-1-5-114*') "RDP denied to local admin accounts (S-1-5-114)"

$Policy  = [xml](Get-AppLockerPolicy -Effective -Xml)
$ExeRule = $Policy.AppLockerPolicy.RuleCollection | Where-Object Type -eq 'Exe'
if ($env:COMPUTERNAME -eq 'win02') {
    Result ($ExeRule.EnforcementMode -eq 'Enabled') "AppLocker: exe rules enforced"
    Result ((Get-Service AppIDSvc).Status -eq 'Running') "Application Identity service running (reboot if KO)"
    Write-Host "     Test as alx-wrk: copy whoami.exe to the Desktop and run it, it must be blocked."
} else {
    Result (-not $ExeRule -or $ExeRule.EnforcementMode -ne 'Enabled') "no AppLocker on the admin workstation"
}

# --- 3. Windows LAPS ------------------------------------------------------------------
Step "3. Windows LAPS"
Result ((Get-PolicyValue 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS' 'BackupDirectory') -eq 2) `
    "LAPS policy received, backup to AD"
if (-not $Admin.Enabled) {
    Enable-LocalUser -SID $Admin.SID
    Write-Host "  +  $($Admin.Name) enabled (managed by LAPS)"
}
Invoke-LapsPolicyProcessing
Start-Sleep -Seconds 5
$Event = Get-WinEvent -LogName 'Microsoft-Windows-LAPS/Operational' -MaxEvents 50 -ErrorAction SilentlyContinue |
    Where-Object Id -eq 10020 | Select-Object -First 1      # 10020 = password updated in AD
Result ([bool]$Event) "$($Admin.Name) password sent to AD $(if ($Event) { "on $($Event.TimeCreated)" })"
Write-Host "     Read it on win01 as alx-org: Get-LapsADPassword -Identity $env:COMPUTERNAME -AsPlainText"

# --- 4. Local accounts ---------------------------------------------------------------
Step "4. Local accounts"
Get-LocalUser | Format-Table Name, Enabled, LastLogon -AutoSize
Write-Host "Next: log off, log on as .\$($Admin.Name) with the LAPS password,"
Write-Host "then run this script with -Cleanup to delete $($TempAccounts -join ' and ')." -ForegroundColor Green
