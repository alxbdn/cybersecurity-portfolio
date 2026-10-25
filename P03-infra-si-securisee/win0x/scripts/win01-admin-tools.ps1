#Requires -RunAsAdministrator
<#
    win01-admin-tools.ps1
    Sets up the admin workstation win01. Two steps, at different times:

    -RSAT    BEFORE moving win01 to VMnet13 (still on NAT): RSAT downloads from Windows Update.
                 powershell -ExecutionPolicy Bypass -File .\win01-admin-tools.ps1 -RSAT

    -SSHKey  AFTER the join, logged on as P03\alx-org: stores the webadmin private key in
             alx-org's profile, generates the fwadmin-win01 key on the spot, makes both
             readable by alx-org only and writes a hardened ~/.ssh/config (fw01 + web01).
             First drop the key file
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

# --- SSH keys (webadmin + fwadmin-win01) + config ------------------------------------------
# Key in the admin account, on the admin PC; fw01 only allows SSH to web01 from the Admin zone.
# OpenSSH refuses a private key others can read: no inheritance, alx-org + SYSTEM only.
if ($SSHKey) {
    Step "SSH keys + config for $env:USERNAME"
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
    # fwadmin-win01 key: generated ON win01 and never leaves it (ANSSI: one key per machine,
    # no private key copied around). Only the public part goes to fw01.
    $FwKey = Join-Path $Folder 'fwadmin-win01'
    if (-not (Test-Path $FwKey)) {
        Write-Host "  + generating the fwadmin-win01 key (pick a passphrase)"
        ssh-keygen -t ecdsa -b 256 -f $FwKey -C 'fwadmin-win01'
    }
    icacls $FwKey /inheritance:r /grant:r "$($env:USERDOMAIN)\$($env:USERNAME):(R)" "*S-1-5-18:(F)" | Out-Null

    # Full ~/.ssh/config: hardened algorithms (ANSSI OpenSSH guide), one key per host,
    # no agent or X11 forwarding. Rewritten on every run, the previous one is backed up.
    $Config = Join-Path $Folder 'config'
    if (Test-Path $Config) { Copy-Item $Config "$Config.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" }
    Set-Content -Path $Config -Encoding ASCII -Value @(
        '# ~/.ssh/config - admin workstation win01 (written by win01-admin-tools.ps1)'
        'Host *'
        '    IdentitiesOnly yes'
        '    ForwardAgent no'
        '    ForwardX11 no'
        '    StrictHostKeyChecking ask'
        '    KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp256'
        '    Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com'
        '    MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com'
        '    ServerAliveInterval 60'
        '    ServerAliveCountMax 3'
        ''
        'Host fw01'
        '    HostName 10.0.30.254'
        '    User fwadmin'
        "    IdentityFile $FwKey"
        ''
        'Host web01'
        '    HostName 10.0.10.10'
        '    User webadmin'
        "    IdentityFile $Key"
    )
    Write-Host "  + $Config written (fw01 + web01)"

    Write-Host "`nPublic key to add on fw01 (~fwadmin/.ssh/authorized_keys):" -ForegroundColor Yellow
    Get-Content "$FwKey.pub"
    Write-Host "`nTests: ssh web01 (webadmin), then ssh fw01 (fwadmin) once the key is on fw01" -ForegroundColor Green
}
