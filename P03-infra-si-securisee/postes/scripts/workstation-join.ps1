#Requires -RunAsAdministrator
<#
    workstation-join.ps1
    Configures a P03 workstation and joins it to p03.lan, straight into its OU:
        win01  admin PC  VMnet13  10.0.30.10/24  OU Postes-Admin
        win02  user PC   VMnet14  10.0.40.10/24  OU Postes-Utilisateurs
    Gateway .254 (fw01), DNS = ad01 (10.0.20.10) only: domain members must resolve AD SRV records.

    Before: VM NIC on the right VMnet, PC -> ad01 flows open on fw01 (fw01-ad-flows.nft).
    Run as local admin, in Windows PowerShell 5.1 (the PC restarts at the end):
        powershell -ExecutionPolicy Bypass -File .\workstation-join.ps1 -Name win01
#>
param(
    [Parameter(Mandatory)][ValidateSet('win01', 'win02')][string]$Name
)
$ErrorActionPreference = 'Stop'

function Step($Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

$Domain = 'p03.lan'
$DC     = '10.0.20.10'
$PCs    = @{
    win01 = @{ IP = '10.0.30.10'; OU = 'OU=Postes-Admin,OU=Ordinateurs,OU=P03,DC=p03,DC=lan' }
    win02 = @{ IP = '10.0.40.10'; OU = 'OU=Postes-Utilisateurs,OU=Ordinateurs,OU=P03,DC=p03,DC=lan' }
}
$IP      = $PCs[$Name].IP
$Gateway = $IP -replace '\.\d+$', '.254'

if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) {
    Write-Host "Already a domain member: nothing to do." -ForegroundColor Yellow
    return
}

# --- 1. Static IP ---------------------------------------------------------------------
Step "1. Static IP"
$NIC = Get-NetAdapter -Physical | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $NIC) { throw "No active network adapter: check the VM NIC is connected." }
Set-NetIPInterface -InterfaceIndex $NIC.ifIndex -AddressFamily IPv4 -Dhcp Disabled
Get-NetIPAddress -InterfaceIndex $NIC.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false
Get-NetRoute -InterfaceIndex $NIC.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false
New-NetIPAddress -InterfaceIndex $NIC.ifIndex -IPAddress $IP -PrefixLength 24 -DefaultGateway $Gateway | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $NIC.ifIndex -ServerAddresses $DC
Clear-DnsClientCache
Write-Host "  $($NIC.Name): $IP/24, gateway $Gateway, DNS $DC"

# --- 2. Pre-join checks -----------------------------------------------------------------
# One test per link (VMnet, fw01, DNS, AD ports) to know exactly what breaks.
Step "2. Pre-join checks"
Start-Sleep -Seconds 5      # let the address come up
function Test-Port($Port) { (Test-NetConnection $DC -Port $Port -WarningAction SilentlyContinue).TcpTestSucceeded }
$Tests = [ordered]@{
    "fw01 answers (ping $Gateway)"           = { Test-Connection $Gateway -Count 2 -Quiet }
    "DNS: SRV _ldap._tcp.dc._msdcs.$Domain"  = { [bool](Resolve-DnsName "_ldap._tcp.dc._msdcs.$Domain" -Type SRV -DnsOnly -ErrorAction SilentlyContinue) }
    "ad01: Kerberos (88)"                    = { Test-Port 88 }
    "ad01: RPC (135)"                        = { Test-Port 135 }
    "ad01: LDAP (389)"                       = { Test-Port 389 }
    "ad01: SMB (445)"                        = { Test-Port 445 }
}
$AllOK = $true
foreach ($Test in $Tests.Keys) {
    if (& $Tests[$Test]) { Write-Host "  OK  $Test" -ForegroundColor Green }
    else                 { Write-Host "  KO  $Test" -ForegroundColor Red; $AllOK = $false }
}
if (-not $AllOK) { throw "Join cancelled. Ping KO: wrong VMnet. DNS or ports KO: fw01 rules." }

# --- 3. Domain join -----------------------------------------------------------------------
# Rename + join in one go, straight into the OU: GPOs apply from the first reboot.
# Uses P03\Administrator: alx-org is limited to win01 / ad01 and the PC still has its temp name.
Step "3. Join $Domain (OU $($PCs[$Name].OU))"
$Cred   = Get-Credential -UserName 'P03\Administrator' -Message "Account allowed to join $Name to the domain"
$Params = @{
    DomainName = $Domain
    OUPath     = $PCs[$Name].OU
    Credential = $Cred
    Force      = $true
    Restart    = $true
}
if ($env:COMPUTERNAME -ne $Name) { $Params.NewName = $Name }
Add-Computer @Params
