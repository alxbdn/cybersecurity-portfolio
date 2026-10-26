#Requires -RunAsAdministrator
<#
    ad01-setup-domain.ps1
    Prepares the p03.lan domain structure before workstations join:
      1. OUs         P03 > Ordinateurs (Postes-Admin, Postes-Utilisateurs), Utilisateurs, Admins, Groupes
      2. Passwords   two fine-grained password policies (users / admins)
      3. Accounts    one standard user + one separate admin account

    Next: ad01-setup-gpo.ps1 (GPOs, AppLocker, LAPS).
    Run on ad01 (or win01 with RSAT) as a domain admin, in Windows PowerShell 5.1:
        powershell -ExecutionPolicy Bypass -File .\ad01-setup-domain.ps1
    Idempotent: safe to re-run.
#>
$StandardUser = 'alx-wrk'     # daily account (OU Utilisateurs)
$AdminUser    = 'alx-org'     # domain admin (OU Admins), used from win01 only
$ErrorActionPreference = 'Stop'

function Step($Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

# --- Prerequisites ---------------------------------------------------------------
Import-Module ActiveDirectory

$Domain = Get-ADDomain
$DN     = $Domain.DistinguishedName          # DC=p03,DC=lan
$FQDN   = $Domain.DNSRoot                    # p03.lan
$SID    = $Domain.DomainSID.Value

# Built-in groups by SID: their names depend on the Windows language
$DomainUsers  = Get-ADGroup -Identity "$SID-513"
$DomainAdmins = Get-ADGroup -Identity "$SID-512"

$Root          = "OU=P03,$DN"
$OUComputers   = "OU=Ordinateurs,$Root"
$OUAdminPCs    = "OU=Postes-Admin,$OUComputers"
$OUUserPCs     = "OU=Postes-Utilisateurs,$OUComputers"
$OUUsers       = "OU=Utilisateurs,$Root"
$OUAdmins      = "OU=Admins,$Root"

# --- 1. OUs ----------------------------------------------------------------------
# Without OUs, joined PCs land in "Computers", where no GPO can be linked.
Step "1. Organizational units"
function New-OUIfMissing($Name, $Parent) {
    if (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -SearchBase $Parent -SearchScope OneLevel) {
        Write-Host "  = OU $Name exists"
    } else {
        New-ADOrganizationalUnit -Name $Name -Path $Parent -ProtectedFromAccidentalDeletion $true
        Write-Host "  + OU $Name"
    }
}
New-OUIfMissing 'P03' $DN
'Ordinateurs', 'Utilisateurs', 'Admins', 'Groupes' | ForEach-Object { New-OUIfMissing $_ $Root }
'Postes-Admin', 'Postes-Utilisateurs'             | ForEach-Object { New-OUIfMissing $_ $OUComputers }

# --- 2. Password policies (PSO) ----------------------------------------------------
# Stricter rules for admins. Lower precedence wins. Applies at the next password change.
Step "2. Password policies"
function Set-PSO($Name, $Settings, $Subject) {
    if (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$Name'") {
        Set-ADFineGrainedPasswordPolicy -Identity $Name @Settings
        Write-Host "  = $Name updated"
    } else {
        New-ADFineGrainedPasswordPolicy -Name $Name @Settings
        Write-Host "  + $Name"
    }
    Add-ADFineGrainedPasswordPolicySubject -Identity $Name -Subjects $Subject
}
Set-PSO 'PSO-Utilisateurs' @{
    Precedence                  = 20
    MinPasswordLength           = 12
    ComplexityEnabled           = $true
    PasswordHistoryCount        = 12
    MinPasswordAge              = '1.00:00:00'
    MaxPasswordAge              = '365.00:00:00'
    LockoutThreshold            = 5
    LockoutDuration             = '00:15:00'
    LockoutObservationWindow    = '00:15:00'
    ReversibleEncryptionEnabled = $false
} $DomainUsers
Set-PSO 'PSO-Admins' @{
    Precedence                  = 10
    MinPasswordLength           = 16
    ComplexityEnabled           = $true
    PasswordHistoryCount        = 24
    MinPasswordAge              = '1.00:00:00'
    MaxPasswordAge              = '180.00:00:00'
    LockoutThreshold            = 5
    LockoutDuration             = '00:30:00'
    LockoutObservationWindow    = '00:30:00'
    ReversibleEncryptionEnabled = $false
} $DomainAdmins

# --- 3. Accounts ---------------------------------------------------------------------
# Two accounts per admin: alx-wrk for daily use, alx-org for administration only.
Step "3. Accounts"
function New-UserIfMissing($Sam, $OU, $Description) {
    if (Get-ADUser -Filter "SamAccountName -eq '$Sam'") { Write-Host "  = $Sam exists"; return }
    $Password = Read-Host -AsSecureString "  Password for $Sam"
    New-ADUser -Name $Sam -SamAccountName $Sam -UserPrincipalName "$Sam@$FQDN" `
        -Path $OU -Description $Description -AccountPassword $Password -Enabled $true
    Write-Host "  + $Sam"
}
New-UserIfMissing $StandardUser $OUUsers  'Standard user'
New-UserIfMissing $AdminUser    $OUAdmins 'Domain admin (from win01 only)'
Add-ADGroupMember -Identity $DomainAdmins -Members $AdminUser

# 3b. Admin account hardening
#     LogonWorkstations: logon only on win01 / ad01 (a stolen password is useless elsewhere)
#     AccountNotDelegated: no Kerberos delegation
#     Protected Users: no NTLM, no cached credentials (RDP to ad01 by name, not IP)
Step "3b. Hardening $AdminUser"
Set-ADUser -Identity $AdminUser -LogonWorkstations 'win01,ad01' -AccountNotDelegated $true
Add-ADGroupMember -Identity (Get-ADGroup -Identity "$SID-525") -Members $AdminUser   # 525 = Protected Users
Write-Host "  = $AdminUser : win01 / ad01 only, not delegable, Protected Users"

# --- Summary -----------------------------------------------------------------------------
Step "Summary"
Get-ADOrganizationalUnit -Filter * -SearchBase $Root | Format-Table Name, DistinguishedName -AutoSize
Get-ADFineGrainedPasswordPolicy -Filter * | Format-Table Name, Precedence, MinPasswordLength, MaxPasswordAge, AppliesTo -AutoSize
Write-Host "`nDone. Next: ad01-setup-gpo.ps1. Change the domain Administrator password (PSO-Admins: 16 characters)." -ForegroundColor Green
