#Requires -RunAsAdministrator
<#
    ad01-setup-gpo.ps1
    Creates and links the P03 GPOs (run after ad01-setup-domain.ps1, the OUs must exist):
      1. Session lock        10 min idle, all P03 OUs
      2. No RDP for local    local admin accounts denied RDP, all PCs
      3. AppLocker           user workstations: only Windows and Program Files can run
      4. Windows LAPS        unique local admin password per PC, all PCs

    Run on ad01 (or win01 with RSAT) as a domain admin, in Windows PowerShell 5.1:
        powershell -ExecutionPolicy Bypass -File .\ad01-setup-gpo.ps1
    Idempotent: safe to re-run.
#>
$ErrorActionPreference = 'Stop'

function Step($Text) { Write-Host "`n=== $Text ===" -ForegroundColor Cyan }

# --- Prerequisites ---------------------------------------------------------------
Import-Module ActiveDirectory
if (-not (Get-Module -ListAvailable GroupPolicy)) { throw "GroupPolicy module missing (install GPMC / RSAT)." }
Import-Module GroupPolicy

$Domain = Get-ADDomain
$DN     = $Domain.DistinguishedName          # DC=p03,DC=lan
$FQDN   = $Domain.DNSRoot                    # p03.lan

$Root          = "OU=P03,$DN"
$OUComputers   = "OU=Ordinateurs,$Root"
$OUAdminPCs    = "OU=Postes-Admin,$OUComputers"
$OUUserPCs     = "OU=Postes-Utilisateurs,$OUComputers"

foreach ($OU in $Root, $OUComputers, $OUAdminPCs, $OUUserPCs) {
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$OU'")) { throw "Missing OU ${OU}: run ad01-setup-domain.ps1 first." }
}

# --- Helpers ---------------------------------------------------------------------------
function Get-OrNewGPO($Name, $Comment) {
    $G = Get-GPO -Name $Name -ErrorAction SilentlyContinue
    if (-not $G) { $G = New-GPO -Name $Name -Comment $Comment; Write-Host "  + GPO $Name" }
    else         { Write-Host "  = GPO $Name exists" }
    $G
}
function Add-GPOLink($GPO, $Target) {
    if (-not ((Get-GPInheritance -Target $Target).GpoLinks | Where-Object DisplayName -eq $GPO.DisplayName)) {
        New-GPLink -Guid $GPO.Id -Target $Target | Out-Null
        Write-Host "    link -> $Target"
    }
}
# A GPO only gets processed by a client-side extension (CSE) listed in gPCMachineExtensionNames.
# Cmdlets like Set-AppLockerPolicy write the settings but not always the CSE: we add it ourselves.
function Add-GPOExtension($GPO, [string]$Cse) {
    $Obj    = Get-ADObject -Identity $GPO.Path -Properties gPCMachineExtensionNames
    $Blocks = @([regex]::Matches("$($Obj.gPCMachineExtensionNames)", '\[[^\]]+\]') | ForEach-Object Value)
    $Sorted = @($Blocks + $Cse) | Sort-Object -Unique     # must stay sorted by GUID, or the client skips some
    Set-ADObject -Identity $GPO.Path -Replace @{ gPCMachineExtensionNames = -join $Sorted }
}
# Bumps the computer version (AD + GPT.INI) so clients see the GPO changed.
function Update-GPOVersion($GPO) {
    $Base    = "\\$FQDN\SYSVOL\$FQDN\Policies\$($GPO.Id.ToString('B').ToUpper())"
    $Version = [int](Get-ADObject -Identity $GPO.Path -Properties versionNumber).versionNumber + 1
    Set-ADObject -Identity $GPO.Path -Replace @{ versionNumber = $Version }
    Set-Content -Path "$Base\GPT.INI" -Value "[General]`r`nVersion=$Version" -Encoding ASCII
}
# Security settings (user rights, services) are not registry values: they live in GptTmpl.inf in SYSVOL.
function Set-GPOSecurityTemplate($GPO, [string[]]$Lines) {
    $Folder = "\\$FQDN\SYSVOL\$FQDN\Policies\$($GPO.Id.ToString('B').ToUpper())\Machine\Microsoft\Windows NT\SecEdit"
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $Header = '[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1'
    Set-Content -Path "$Folder\GptTmpl.inf" -Value ($Header + $Lines) -Encoding Unicode
    Add-GPOExtension $GPO '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'   # Security
    Update-GPOVersion $GPO
}

# 1. Lock the session after 10 min idle (users: password-protected screensaver, machine: lock)
Step "1. GPO session lock"
$G = Get-OrNewGPO 'GPO-P03-Verrouillage-Session' 'Password-protected screensaver after 10 min (6.2.2)'
$K = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ScreenSaveActive'    -Type String -Value '1'            | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ScreenSaverIsSecure' -Type String -Value '1'            | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ScreenSaveTimeOut'   -Type String -Value '600'          | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'SCRNSAVE.EXE'        -Type String -Value 'scrnsave.scr' | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System' `
    -ValueName 'InactivityTimeoutSecs' -Type DWord -Value 600 | Out-Null
Add-GPOLink $G $Root

# 2. Deny RDP to local admin accounts (S-1-5-114): blocks lateral movement with a reused local password
Step "2. GPO deny RDP to local accounts"
$G = Get-OrNewGPO 'GPO-P03-Refus-RDP-Comptes-Locaux' 'No Remote Desktop for local admins (6.2.2)'
Set-GPOSecurityTemplate $G @('[Privilege Rights]', 'SeDenyRemoteInteractiveLogonRight = *S-1-5-114')
Add-GPOLink $G $OUComputers

# 3. AppLocker on user workstations: programs run only from Windows and Program Files.
#     Admins run anything. Not on the admin workstation (it needs its tools).
#     Needs the Application Identity service (AppIDSvc), set to automatic by the same GPO.
#     Limit: a few folders under C:\Windows are user-writable; next step would be App Control for Business.
Step "3. GPO AppLocker user workstations"
$G = Get-OrNewGPO 'GPO-P03-AppLocker-Postes-Utilisateurs' 'AppLocker: only Windows and Program Files can run (6.2.2)'
$Rules = @'
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="921cc481-6e17-4653-8f75-050b80acca20" Name="Program Files" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%PROGRAMFILES%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="a61c8b2c-a319-4cd0-9690-d2177cad7b51" Name="Windows" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="fd686d83-a829-4351-8ff4-27c7de5755d2" Name="Administrators" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Msi" EnforcementMode="Enabled">
    <FilePathRule Id="5b290184-345a-4453-b184-45305f6d9a54" Name="Windows Installer" Description="" UserOrGroupSid="S-1-1-0" Action="Allow">
      <Conditions><FilePathCondition Path="%WINDIR%\Installer\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="64ad46ff-0d71-4fa0-a30b-3f3d30c5433d" Name="Administrators" Description="" UserOrGroupSid="S-1-5-32-544" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
'@                                                       # Microsoft default rules (same IDs)
$Xml = Join-Path $env:TEMP 'applocker.xml'
Set-Content -Path $Xml -Value $Rules -Encoding UTF8
Set-AppLockerPolicy -XmlPolicy $Xml -Ldap "LDAP://$($G.Path)"
Remove-Item $Xml
Add-GPOExtension $G '[{F312195E-3D9D-447A-A3F5-08DFFA24735E}{D02B1F72-3407-48AE-BA88-E8213C6761F1}]'   # AppLocker
Set-GPOSecurityTemplate $G @('[Service General Setting]', '"AppIDSvc",2,""')   # 2 = automatic
Add-GPOLink $G $OUUserPCs

# 4. Windows LAPS: unique random local admin password per PC, rotated every 30 days,
#     encrypted in AD, readable by Domain Admins only.
Step "4. Windows LAPS"
Update-LapsADSchema -Confirm:$false
Set-LapsADComputerSelfPermission -Identity $OUComputers | Out-Null   # PCs write their own password
$G = Get-OrNewGPO 'GPO-P03-LAPS' 'Windows LAPS: unique local admin password per PC'
$K = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'BackupDirectory'             -Type DWord -Value 2  | Out-Null  # 2 = AD
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'PasswordComplexity'          -Type DWord -Value 4  | Out-Null  # upper, lower, digits, symbols
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'PasswordLength'              -Type DWord -Value 20 | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'PasswordAgeDays'             -Type DWord -Value 30 | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ADPasswordEncryptionEnabled' -Type DWord -Value 1  | Out-Null
Add-GPOLink $G $OUComputers

# --- Summary -----------------------------------------------------------------------------
Step "Summary"
foreach ($OU in $Root, $OUComputers, $OUAdminPCs, $OUUserPCs) {
    $Links = (Get-GPInheritance -Target $OU).GpoLinks.DisplayName -join ', '
    Write-Host ("  {0,-60} {1}" -f $OU, $Links)
}
Write-Host "`nDone. On each PC: gpupdate /force, then reboot (AppLocker, LAPS)." -ForegroundColor Green
