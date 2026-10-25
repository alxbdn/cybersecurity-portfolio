#Requires -RunAsAdministrator
<#
    win01-admin-tools.ps1
    Sets up the admin workstation win01. Two steps, at different times:

    -RSAT    BEFORE moving win01 to VMnet13 (still on NAT): RSAT downloads from Windows Update.
                 powershell -ExecutionPolicy Bypass -File .\win01-admin-tools.ps1 -RSAT

    -SSHKey  AFTER the join, logged on as P03\alx-org: stores the webadmin private key in
             alx-org's profile, readable by alx-org only. First drop the key file
             (host: C:\Users\alxbdn\.ssh\webadmin) on alx-org's Desktop, then:
                 powershell -ExecutionPolicy Bypass -File .\win01-admin-tools.ps1 -SSHKey
#>
param(
    [switch]$RSAT,
    [switch]$SSHKey
)
$ErrorActionPreference = 'Stop'

function Step($Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

if (-not ($RSAT -or $SSHKey)) { throw "Use -RSAT or -SSHKey (see the script header)." }

# --- RSAT -----------------------------------------------------------------------------------
# Only what we use: AD (dsa.msc + PowerShell module), GPMC, DNS. LAPS module is built into Windows 11.
# Admin from win01, not on the DC: nobody logs on to a DC for daily admin.
if ($RSAT) {
    Step "RSAT install"
    $Tools = 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0',
             'Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0',
             'Rsat.Dns.Tools~~~~0.0.1.0'
    foreach ($Tool in $Tools) {
        if ((Get-WindowsCapability -Online -Name $Tool).State -eq 'Installed') {
            Write-Host "  = $Tool already installed"
        } else {
            Write-Host "  + $Tool (a few minutes)..."
            Add-WindowsCapability -Online -Name $Tool | Out-Null
        }
    }
}

# --- webadmin SSH key -------------------------------------------------------------------------
# Key in the admin account, on the admin PC; fw01 only allows SSH to web01 from the Admin zone.
# OpenSSH refuses a private key others can read: no inheritance, alx-org + SYSTEM only.
if ($SSHKey) {
    Step "webadmin SSH key for $env:USERNAME"
    if ($env:USERNAME -ne 'alx-org') { throw "Run this step in the P03\alx-org session." }
    $Source = Join-Path ([Environment]::GetFolderPath('Desktop')) 'webadmin'
    $Folder = Join-Path $env:USERPROFILE '.ssh'
    $Key    = Join-Path $Folder 'webadmin'
    if (-not (Test-Path $Key)) {
        if (-not (Test-Path $Source)) { throw "Key not found: drop the webadmin file on the Desktop." }
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        Move-Item -Path $Source -Destination $Key
    }
    icacls $Key /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R)" "*S-1-5-18:(F)" | Out-Null
    icacls $Key
    $Config = Join-Path $Folder 'config'
    if (-not (Test-Path $Config) -or -not (Select-String -Path $Config -Pattern '^Host web01' -Quiet)) {
        Add-Content -Path $Config -Encoding ASCII -Value @(
            'Host web01'
            '    HostName 10.0.10.10'
            '    User webadmin'
            "    IdentityFile $Key"
            '    IdentitiesOnly yes'
        )
        Write-Host "  + web01 entry in $Config"
    }
    Write-Host "`nTest: ssh web01   (should log on as webadmin, no password)" -ForegroundColor Green
}
