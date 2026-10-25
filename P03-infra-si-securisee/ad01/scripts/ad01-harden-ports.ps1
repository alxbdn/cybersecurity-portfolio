#Requires -RunAsAdministrator
<#
    ad01-harden-ports.ps1
    Reduces what ad01 exposes on the network, on top of fw01 (defense in depth):
      1. SSH         OpenSSH server off (not used: admin goes through WinRM / RSAT)
      2. Admin ports RDP, WinRM, AD Web Services: Admin zone (10.0.30.0/24) only
      3. RDP         Network Level Authentication required
      4. Report      ports still listening

    Domain ports (DNS, Kerberos, LDAP, SMB, RPC...) stay open: every domain member needs them.
    fw01 decides which zones reach them (fw01-ad-flows.nft).

    Run ON ad01 (console, RDP or Enter-PSSession ad01), as a domain admin:
        powershell -ExecutionPolicy Bypass -File .\ad01-harden-ports.ps1
    Idempotent: safe to re-run.
#>
$AdminNet = '10.0.30.0/24'
$ErrorActionPreference = 'Stop'

function Step($Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

# --- 1. SSH off -------------------------------------------------------------------------
Step "1. OpenSSH server off"
$Sshd = Get-Service sshd -ErrorAction SilentlyContinue
if ($Sshd) {
    Stop-Service sshd
    Set-Service sshd -StartupType Disabled
    Write-Host "  -  sshd stopped and disabled"
} else {
    Write-Host "  =  sshd not installed"
}
Get-NetFirewallRule | Where-Object { $_.Name -like '*SSH*' -or $_.DisplayName -like '*OpenSSH*' } |
    ForEach-Object { Disable-NetFirewallRule -Name $_.Name; Write-Host "  -  rule $($_.DisplayName) disabled" }

# --- 2. Admin ports: Admin zone only ----------------------------------------------------
# Rule names (not display names): same on every Windows language
Step "2. RDP, WinRM, ADWS: $AdminNet only"
$AdminRules = 'RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP',   # 3389
              'WINRM-HTTP-In-TCP', 'WINRM-HTTP-In-TCP-PUBLIC',                    # 5985
              'ADWS-TCP-In'                                                       # 9389
foreach ($Name in $AdminRules) {
    if (Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue) {
        Set-NetFirewallRule -Name $Name -RemoteAddress $AdminNet
        Write-Host "  +  $Name -> $AdminNet"
    } else {
        Write-Host "  =  $Name not present" -ForegroundColor Yellow
    }
}

# --- 3. RDP: NLA required ----------------------------------------------------------------
# NLA: authentication before the session opens (no logon screen exposed to anyone)
Step "3. RDP Network Level Authentication"
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' UserAuthentication 1
Write-Host "  +  NLA required"

# --- 4. Report ---------------------------------------------------------------------------
Step "4. Listening TCP ports"
$Names = @{ 53='DNS'; 88='Kerberos'; 135='RPC'; 139='NetBIOS'; 389='LDAP'; 445='SMB'; 464='Kerberos pwd';
            636='LDAPS'; 3268='GC'; 3269='GC SSL'; 3389='RDP'; 5985='WinRM'; 9389='ADWS'; 47001='WinRM (local)' }
Get-NetTCPConnection -State Listen |
    Where-Object { $_.LocalAddress -notin '127.0.0.1', '::1' -and $_.LocalPort -lt 49152 } |
    Sort-Object LocalPort -Unique |
    ForEach-Object { '  {0,-6} {1}' -f $_.LocalPort, $Names[[int]$_.LocalPort] }
Write-Host "  (+ RPC dynamic ports 49152-65535, reached through 135)"

Write-Host "`nDone. Test from win01: Enter-PSSession ad01. From win02: Test-NetConnection ad01 -Port 5985 must fail." -ForegroundColor Green
