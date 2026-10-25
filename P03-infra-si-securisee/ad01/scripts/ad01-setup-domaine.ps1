#Requires -RunAsAdministrator
<#
    ad01-setup-domaine.ps1
    Prépare le domaine p03.lan AVANT la jonction des postes :
      1. OU            P03 > Ordinateurs (Postes-Admin, Postes-Utilisateurs), Utilisateurs, Admins, Groupes
      2. Mots de passe deux politiques fines (PSO) : utilisateurs et administrateurs
      3. Comptes       un utilisateur standard + un compte administrateur séparé
      4. GPO           verrouillage de session 10 min, refus RDP aux comptes locaux, SRP, Windows LAPS

    À lancer sur ad01, connecté avec l'administrateur du domaine, dans Windows PowerShell 5.1 :
        powershell -ExecutionPolicy Bypass -File C:\Scripts\ad01-setup-domaine.ps1
    Idempotent : on peut le relancer, il ne recrée pas ce qui existe déjà.
#>
$CompteStandard = 'alx-wrk'     # utilisateur standard (OU Utilisateurs)
$CompteAdmin    = 'alx-org'     # administrateur du domaine (OU Admins), utilisé seulement depuis win01
$ErrorActionPreference = 'Stop'

function Etape($Texte) { Write-Host "`n=== $Texte ===" -ForegroundColor Cyan }

# --- Prérequis ------------------------------------------------------------------
Import-Module ActiveDirectory
if (-not (Get-Module -ListAvailable GroupPolicy)) {
    throw "Module GroupPolicy absent (console GPMC non installée sur ce Server Core). Voir la note en fin de tuto, puis relance."
}
Import-Module GroupPolicy

$Domaine = Get-ADDomain
$DN      = $Domaine.DistinguishedName          # DC=p03,DC=lan
$FQDN    = $Domaine.DNSRoot                    # p03.lan
$SID     = $Domaine.DomainSID.Value

# Groupes intégrés trouvés par leur SID : leur nom change selon la langue de Windows
# (Domain Users / Utilisateurs du domaine...), le SID non.
$GrpUtilisateursDomaine = Get-ADGroup -Identity "$SID-513"
$GrpAdminsDomaine       = Get-ADGroup -Identity "$SID-512"

$Racine        = "OU=P03,$DN"
$OUOrdinateurs = "OU=Ordinateurs,$Racine"
$OUPostesAdmin = "OU=Postes-Admin,$OUOrdinateurs"
$OUPostesUsers = "OU=Postes-Utilisateurs,$OUOrdinateurs"
$OUUsers       = "OU=Utilisateurs,$Racine"
$OUAdmins      = "OU=Admins,$Racine"

# --- 1. Unités d'organisation ---------------------------------------------------
# Sans OU, un poste joint arrive dans le conteneur "Computers", où aucune GPO ne peut être liée.
Etape "1. Unités d'organisation"
function New-OUSiAbsente($Nom, $Parent) {
    if (Get-ADOrganizationalUnit -Filter "Name -eq '$Nom'" -SearchBase $Parent -SearchScope OneLevel) {
        Write-Host "  = OU $Nom existe déjà"
    } else {
        New-ADOrganizationalUnit -Name $Nom -Path $Parent -ProtectedFromAccidentalDeletion $true
        Write-Host "  + OU $Nom"
    }
}
New-OUSiAbsente 'P03' $DN
'Ordinateurs', 'Utilisateurs', 'Admins', 'Groupes' | ForEach-Object { New-OUSiAbsente $_ $Racine }
'Postes-Admin', 'Postes-Utilisateurs'             | ForEach-Object { New-OUSiAbsente $_ $OUOrdinateurs }

# --- 2. Politiques de mots de passe (PSO) ---------------------------------------
# Deux politiques "fines" (Fine-Grained Password Policies), appliquées à des groupes :
#   - PSO-Utilisateurs -> tous les comptes du domaine (groupe Utilisateurs du domaine)
#   - PSO-Admins       -> Admins du domaine, plus stricte. Precedence plus petite = prioritaire.
# Avantage par rapport à la Default Domain Policy : deux niveaux différents dans un seul domaine.
# Valeurs à justifier dans la doc avec le guide ANSSI sur les mots de passe (longueur avant
# complexité, renouvellement pas trop fréquent pour éviter les mots de passe "Password1, Password2...").
# Une PSO s'applique au PROCHAIN changement de mot de passe.
Etape "2. Politiques de mots de passe"
function Set-PSO($Nom, $Parametres, $Sujet) {
    if (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$Nom'") {
        Set-ADFineGrainedPasswordPolicy -Identity $Nom @Parametres
        Write-Host "  = $Nom mise à jour"
    } else {
        New-ADFineGrainedPasswordPolicy -Name $Nom @Parametres
        Write-Host "  + $Nom"
    }
    Add-ADFineGrainedPasswordPolicySubject -Identity $Nom -Subjects $Sujet
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
} $GrpUtilisateursDomaine
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
} $GrpAdminsDomaine

# --- 3. Comptes -------------------------------------------------------------------
# Séparation des usages : l'admin a DEUX comptes. "alx-wrk" pour le quotidien (mail, web),
# "alx-org" uniquement pour administrer, depuis le poste admin win01.
Etape "3. Comptes"
function New-CompteSiAbsent($Sam, $OU, $Description) {
    if (Get-ADUser -Filter "SamAccountName -eq '$Sam'") {
        Write-Host "  = $Sam existe déjà"
        return
    }
    $Mdp = Read-Host -AsSecureString "  Mot de passe pour $Sam"
    New-ADUser -Name $Sam -SamAccountName $Sam -UserPrincipalName "$Sam@$FQDN" `
        -Path $OU -Description $Description -AccountPassword $Mdp -Enabled $true
    Write-Host "  + $Sam"
}
New-CompteSiAbsent $CompteStandard $OUUsers  'Utilisateur standard'
New-CompteSiAbsent $CompteAdmin    $OUAdmins 'Administrateur du domaine (depuis win01 uniquement)'
Add-ADGroupMember -Identity $GrpAdminsDomaine -Members $CompteAdmin   # sans effet s'il est déjà membre

# 3b. Durcissement du compte admin (ANSSI : protéger les comptes à privilèges)
#     - LogonWorkstations : alx-org ne peut ouvrir de session que sur win01 (poste admin) et ad01 (RDP).
#       Un mot de passe volé ne sert à rien depuis win02.
#     - AccountNotDelegated : aucun service ne peut réutiliser son identité (délégation Kerberos).
#     - Protected Users : pas de NTLM, pas d'identifiants en cache, Kerberos AES uniquement.
#       Conséquence : RDP vers ad01 par son nom (ad01.p03.lan), pas par son IP (l'IP force NTLM).
Etape "3b. Durcissement de $CompteAdmin"
Set-ADUser -Identity $CompteAdmin -LogonWorkstations 'win01,ad01' -AccountNotDelegated $true
Add-ADGroupMember -Identity (Get-ADGroup -Identity "$SID-525") -Members $CompteAdmin   # 525 = Protected Users
Write-Host "  = $CompteAdmin : connexion limitée à win01 / ad01, non délégable, membre de Protected Users"

# --- 4. GPO ---------------------------------------------------------------------------
function Get-GPOOuCree($Nom, $Commentaire) {
    $G = Get-GPO -Name $Nom -ErrorAction SilentlyContinue
    if (-not $G) { $G = New-GPO -Name $Nom -Comment $Commentaire; Write-Host "  + GPO $Nom" }
    else         { Write-Host "  = GPO $Nom existe déjà" }
    $G
}
function Add-LienGPO($GPO, $Cible) {
    if (-not ((Get-GPInheritance -Target $Cible).GpoLinks | Where-Object DisplayName -eq $GPO.DisplayName)) {
        New-GPLink -Guid $GPO.Id -Target $Cible | Out-Null
        Write-Host "    lien -> $Cible"
    }
}

# 4a. Verrouillage de session après 10 min d'inactivité (exigence 6.2.2)
#     Côté utilisateur : écran de veille protégé par mot de passe, 600 s, non modifiable.
#     Côté machine : verrouillage à 600 s même si l'écran de veille est contourné.
#     Liée à OU=P03 : couvre les comptes (Utilisateurs, Admins) et les postes.
Etape "4a. GPO verrouillage de session"
$G = Get-GPOOuCree 'GPO-P03-Verrouillage-Session' 'Écran de veille avec mot de passe après 10 min (mission 6.2.2)'
$K = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ScreenSaveActive'    -Type String -Value '1'            | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ScreenSaverIsSecure' -Type String -Value '1'            | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ScreenSaveTimeOut'   -Type String -Value '600'          | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'SCRNSAVE.EXE'        -Type String -Value 'scrnsave.scr' | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\System' `
    -ValueName 'InactivityTimeoutSecs' -Type DWord -Value 600 | Out-Null
Add-LienGPO $G $Racine

# 4b. Interdire le Bureau à distance aux comptes administrateurs locaux (exigence 6.2.2)
#     Droit "Interdire l'ouverture de session par les services Bureau à distance" pour le SID
#     S-1-5-114 = "Compte local et membre du groupe Administrateurs". Bloque aussi les
#     mouvements latéraux avec un mot de passe admin local réutilisé.
#     C'est un paramètre de sécurité (GptTmpl.inf), pas une clé de registre : on écrit le fichier
#     dans SYSVOL, on déclare l'extension "Sécurité" sur la GPO et on incrémente sa version.
Etape "4b. GPO refus RDP aux comptes locaux"
function Set-ModeleSecuriteGPO($GPO, [string[]]$Lignes) {
    $Base = "\\$FQDN\SYSVOL\$FQDN\Policies\$($GPO.Id.ToString('B').ToUpper())"
    $Dossier = "$Base\Machine\Microsoft\Windows NT\SecEdit"
    New-Item -ItemType Directory -Path $Dossier -Force | Out-Null
    $Entete = '[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1'
    Set-Content -Path "$Dossier\GptTmpl.inf" -Value ($Entete + $Lignes) -Encoding Unicode
    $Obj = Get-ADObject -Identity $GPO.Path -Properties gPCMachineExtensionNames, versionNumber
    $CSESecurite = '[{827D319E-6EAC-11D2-A4EA-00C04F79F83A}{803E14A0-B4FB-11D0-A0D0-00A0C90F574B}]'
    if ("$($Obj.gPCMachineExtensionNames)" -notlike '*827D319E*') {
        Set-ADObject -Identity $GPO.Path -Replace @{ gPCMachineExtensionNames = "$($Obj.gPCMachineExtensionNames)$CSESecurite" }
    }
    $Version = [int]$Obj.versionNumber + 1      # +1 = partie "ordinateur" de la version
    Set-ADObject -Identity $GPO.Path -Replace @{ versionNumber = $Version }
    Set-Content -Path "$Base\GPT.INI" -Value "[General]`r`nVersion=$Version" -Encoding ASCII
}
$G = Get-GPOOuCree 'GPO-P03-Refus-RDP-Comptes-Locaux' 'Pas de session Bureau à distance pour les admins locaux (mission 6.2.2)'
Set-ModeleSecuriteGPO $G @('[Privilege Rights]', 'SeDenyRemoteInteractiveLogonRight = *S-1-5-114')
Add-LienGPO $G $OUOrdinateurs

# 4c. Stratégie de restriction logicielle (SRP) sur les postes utilisateurs (exigence 6.2.2)
#     Par défaut : "Non autorisé". Exceptions : %SystemRoot% (C:\Windows) et Program Files (x64 et x86).
#     Un utilisateur ne peut donc pas lancer un .exe téléchargé dans son profil.
#     LNK retiré des types surveillés, sinon les raccourcis du Bureau sont bloqués.
#     Pas sur le poste admin : il doit pouvoir lancer ses outils.
#     Limite à citer : SRP n'évolue plus chez Microsoft, AppLocker / App Control sont les successeurs.
Etape "4c. GPO SRP postes utilisateurs"
$G = Get-GPOOuCree 'GPO-P03-SRP-Postes-Utilisateurs' 'Seuls Windows et Program Files sont autorisés (mission 6.2.2)'
$K = 'HKLM\Software\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'DefaultLevel'        -Type DWord -Value 0 | Out-Null   # 0 = Non autorisé
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'TransparentEnabled'  -Type DWord -Value 1 | Out-Null   # tous les fichiers sauf DLL
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'PolicyScope'         -Type DWord -Value 0 | Out-Null   # admins compris
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'AuthenticodeEnabled' -Type DWord -Value 0 | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ExecutableTypes' -Type MultiString -Value @(
    'ADE','ADP','BAS','BAT','CHM','CMD','COM','CPL','CRT','EXE','HLP','HTA','INF','INS','ISP',
    'MDB','MDE','MSC','MSI','MSP','MST','OCX','PCD','PIF','REG','SCR','SHS','URL','VB','WSC') | Out-Null
$Chemins = @{   # GUID fixes pour que le script reste idempotent
    '{191cd7fa-f240-4a17-8986-94d480a6c8ca}' = '%HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRoot%'
    '{d2c34ab2-529a-46b2-b293-fc853fce72ea}' = '%HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\ProgramFilesDir%'
    '{7f4b1a3e-8c2d-4e5f-9a6b-1c2d3e4f5a6b}' = '%HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\ProgramFilesDir (x86)%'
}
foreach ($Id in $Chemins.Keys) {
    $KC = "$K\262144\Paths\$Id"                                        # 262144 = Non restreint
    Set-GPRegistryValue -Guid $G.Id -Key $KC -ValueName 'ItemData'   -Type ExpandString -Value $Chemins[$Id] | Out-Null
    Set-GPRegistryValue -Guid $G.Id -Key $KC -ValueName 'SaferFlags' -Type DWord -Value 0 | Out-Null
}
Add-LienGPO $G $OUPostesUsers

# 4d. Windows LAPS : mot de passe unique et aléatoire pour l'Administrateur local de chaque poste,
#     changé tous les 30 jours, chiffré dans l'AD, lisible seulement par les Admins du domaine.
#     Remplace le compte local "setup" commun à tous les postes clonés.
Etape "4d. Windows LAPS"
Update-LapsADSchema -Confirm:$false                                   # ajoute les attributs LAPS au schéma
Set-LapsADComputerSelfPermission -Identity $OUOrdinateurs | Out-Null  # les postes écrivent leur propre mot de passe
$G = Get-GPOOuCree 'GPO-P03-LAPS' 'Windows LAPS : mot de passe admin local unique par poste'
$K = 'HKLM\Software\Microsoft\Windows\CurrentVersion\Policies\LAPS'
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'BackupDirectory'              -Type DWord -Value 2  | Out-Null  # 2 = Active Directory
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'PasswordComplexity'           -Type DWord -Value 4  | Out-Null  # maj + min + chiffres + spéciaux
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'PasswordLength'               -Type DWord -Value 20 | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'PasswordAgeDays'              -Type DWord -Value 30 | Out-Null
Set-GPRegistryValue -Guid $G.Id -Key $K -ValueName 'ADPasswordEncryptionEnabled'  -Type DWord -Value 1  | Out-Null
Add-LienGPO $G $OUOrdinateurs

# --- Récap -------------------------------------------------------------------------
Etape "Récap"
foreach ($OU in $Racine, $OUOrdinateurs, $OUPostesAdmin, $OUPostesUsers) {
    $Liens = (Get-GPInheritance -Target $OU).GpoLinks.DisplayName -join ', '
    Write-Host ("  {0,-60} {1}" -f $OU, $Liens)
}
Get-ADFineGrainedPasswordPolicy -Filter * | Format-Table Name, Precedence, MinPasswordLength, MaxPasswordAge, AppliesTo -AutoSize
Write-Host "`nTerminé. Pense à changer le mot de passe de l'administrateur du domaine (PSO-Admins : 16 caractères)." -ForegroundColor Green
