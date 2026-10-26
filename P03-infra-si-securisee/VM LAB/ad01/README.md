# ad01 · Contrôleur de domaine

Windows Server 2025 Standard (Desktop Experience), AD DS + DNS, domaine `p03.lan` (NetBIOS `P03`). Une fois en place, il s'administre **depuis win01** (RSAT, `Enter-PSSession ad01`) : personne n'ouvre de session sur le DC pour l'admin courante.

| | |
|---|---|
| Zone | Serveurs, VMnet12 |
| IP | `10.0.20.10/24`, passerelle `10.0.20.254` (fw01) |
| DNS | lui-même (`127.0.0.1`), redirecteur `192.168.93.2` pour Internet |
| Prérequis | [fw01](../fw01/README.md) en étape 1 (routage + NAT) |

## Les scripts, dans l'ordre

| # | Script | Quand | Ce qu'il fait |
|---|---|---|---|
| 1 | [`ad01-setup-domain.ps1`](scripts/ad01-setup-domain.ps1) | Après la promotion | OU, 2 politiques de mots de passe (PSO), comptes `alx-wrk` / `alx-org` |
| 2 | [`ad01-setup-gpo.ps1`](scripts/ad01-setup-gpo.ps1) | Juste après | GPO : verrouillage 10 min, refus RDP aux comptes locaux, AppLocker, Windows LAPS |
| 3 | [`ad01-harden-ports.ps1`](scripts/ad01-harden-ports.ps1) | **En dernier**, une fois win01 joint | SSH coupé, RDP / WinRM / ADWS limités à la zone Admin, NLA |

Les trois sont idempotents : on peut les relancer sans risque.

## 1. Préparer la VM

Clone du template `winsrv2025` (passé au sysprep), carte sur **VMnet12**, 8 Go / 4 vCPU. Puis, en PowerShell admin :

```powershell
$NIC = (Get-NetAdapter | Where-Object Status -eq 'Up').ifIndex
New-NetIPAddress -InterfaceIndex $NIC -IPAddress 10.0.20.10 -PrefixLength 24 -DefaultGateway 10.0.20.254
Set-DnsClientServerAddress -InterfaceIndex $NIC -ServerAddresses 127.0.0.1
Rename-Computer ad01 -Restart
```

## 2. Créer la forêt

```powershell
Install-WindowsFeature AD-Domain-Services -IncludeManagementTools
Install-ADDSForest -DomainName p03.lan -DomainNetbiosName P03 -InstallDns   # demande le mot de passe DSRM, redémarre
```

Après le redémarrage, connexion en `P03\Administrator`, puis :

```powershell
Add-DnsServerForwarder -IPAddress 192.168.93.2     # résolution des noms Internet via le proxy DNS VMware
dcdiag /q                                          # rien = aucune erreur
```

## 3. Structure du domaine

Copier les scripts sur ad01 (glisser-déposer avec les VMware Tools), puis dans **Windows PowerShell 5.1** en admin :

```powershell
powershell -ExecutionPolicy Bypass -File .\ad01-setup-domain.ps1
```

Il demande le mot de passe de `alx-wrk` (12 caractères mini) et de `alx-org` (16 mini). Ensuite, **changer le mot de passe de `P03\Administrator`** pour qu'il respecte la PSO admin (16 caractères) : il devient le compte de secours, à ne plus utiliser au quotidien.

✅ `Get-ADUserResultantPasswordPolicy alx-org` → `PSO-Admins`. Postes rangés dans leur OU : [capture](captures/03_ad01-ordinateurs-dans-leur-OU.png).

## 4. GPO

```powershell
powershell -ExecutionPolicy Bypass -File .\ad01-setup-gpo.ps1
```

| GPO | Liée à | Effet |
|---|---|---|
| Verrouillage de session | Toute l'OU P03 | Écran verrouillé après 10 min |
| Refus RDP aux comptes locaux | Tous les postes | Pas de rebond avec un mot de passe local |
| AppLocker | Postes-Utilisateurs | Seuls Windows et Program Files s'exécutent, les admins gardent la main |
| Windows LAPS | Tous les postes | Mot de passe admin local unique par poste, changé tous les 30 jours |

✅ `Get-GPO -All | Select DisplayName` liste les 4 GPO `GPO-P03-*`. Les postes peuvent maintenant être joints : voir [win01 / win02](../win0x/README.md).

## 5. Fermer les ports d'administration

**Une fois win01 joint et fonctionnel**, depuis win01 en `alx-org` :

```powershell
Invoke-Command -ComputerName ad01 -FilePath .\ad01-harden-ports.ps1
```

✅ Depuis win01 : `Enter-PSSession ad01` fonctionne. Depuis win02 : `Test-NetConnection ad01 -Port 5985` échoue alors que le port 389 répond, même avec fw01 encore ouvert ([capture](captures/02_win02-winrm-refuse-ldap-ok.png)). Rapport des ports : [capture](captures/01_ad01-harden-ports.png).

RDP depuis win01 en `alx-org` : [capture](captures/04_ad01-rdp-depuis-win01-alx-org.png) · double saut refusé (`alx-org` non délégable) : [capture](captures/05_ad01-double-saut-refuse-non-delegable.png).

## Erreurs à éviter

| Piège | Ce qu'il faut faire |
|---|---|
| Lancer les scripts dans PowerShell 7 (`pwsh`) | Utiliser **Windows PowerShell 5.1** : le module GroupPolicy n'est pas fiable sous 7 |
| `ad01-harden-ports.ps1` lancé trop tôt | RDP et WinRM ne répondent plus qu'à la zone Admin : depuis l'hôte sur VMnet12, on perd la main. Le lancer en dernier, depuis win01 |
| `mstsc /v:10.0.20.10` refusé avec `alx-org` | `alx-org` est dans Protected Users (Kerberos seul, pas de NTLM) : se connecter **par le nom**, `ad01.p03.lan` |
| GPO listée par `gpresult` mais sans effet | Son extension (CSE) manque dans `gPCMachineExtensionNames`, ou la liste n'est pas triée par GUID. Le script l'ajoute pour AppLocker (`Add-GPOExtension`) |
| Restriction logicielle (SRP) sans effet sur Windows 11 | Les Windows récents n'appliquent plus SRP : c'est pour ça qu'on utilise AppLocker |
| Noms de groupes en dur (`Domain Admins`…) | Ils changent avec la langue de Windows : les scripts passent par les SID (`-512`, `-513`, `-525`) |
| Nouvelle PSO « qui ne marche pas » | Elle s'applique au **prochain changement** de mot de passe |
| Kerberos refuse les connexions | Plus de 5 min d'écart d'horloge : `w32tm /query /status` sur ad01 et le poste |
| Poste joint dans `Computers` | Aucune GPO ne peut y être liée : les OU doivent exister **avant** la jonction (étape 3) |

Commandes de diagnostic : [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#ad01-windows-server-2025-ad--dns).
