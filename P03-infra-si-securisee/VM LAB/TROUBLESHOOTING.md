# P03 · Commandes de vérification et de dépannage

Les commandes utiles par machine. Pour chacune : ce qu'elle vérifie, et ce qu'on doit voir quand tout va bien.

| Machine | IP | Accès |
|---|---|---|
| `fw01` | 192.168.93.10 (WAN) + 10.0.x.254 | console / SSH depuis la zone Admin |
| `web01` | 10.0.10.10 | `ssh web01` depuis `win01` (compte `webadmin`), console pour l'admin système |
| `ad01` | 10.0.20.10 | depuis `win01` en `alx-org` : `Enter-PSSession ad01` (par le nom, pas l'IP : Kerberos), RSAT, ou `mstsc /v:ad01.p03.lan` |
| `win01` | 10.0.30.10 | poste admin, `alx-org` |
| `win02` | 10.0.40.10 | poste utilisateur, `alx-wrk` (admin local : `.\Administrator` via LAPS) |

---

## Méthode : quand « ça marche pas »

Toujours remonter la chaîne dans cet ordre, un maillon à la fois :

1. **Carte / VMnet** : la VM est-elle sur le bon VMnet ? (`ip -br a` / `ipconfig`)
2. **Passerelle** : `ping 10.0.x.254` (fw01 répond ?)
3. **Routage / filtrage** : le flux passe-t-il fw01 ? (logs `fw01-fwd-drop`)
4. **DNS** : le nom se résout-il ? (`Resolve-DnsName` / `dig`)
5. **Port** : le service écoute-t-il ? (`Test-NetConnection -Port` / `ss -tlnp`)
6. **Service / politique** : logs du service, GPO reçues, etc.

---

## fw01 (Ubuntu, nftables)

### Interfaces et routage
```bash
ip -br a                         # 5 cartes UP : ens32 WAN, ens34 DMZ, ens35 Serveurs, ens36 Admin, ens37 Users
ip route                         # default via 192.168.93.2 dev ens32
sysctl net.ipv4.ip_forward       # = 1, sinon fw01 ne route rien
cat /proc/cmdline                # ipv6.disable=1 présent
resolvectl status                # DNS 192.168.93.2 sur ens32
```

### Règles nftables
```bash
sudo nft list ruleset                        # tout le jeu de règles
sudo nft list chain inet filter forward      # flux entre zones
sudo nft -c -f /etc/nftables.conf            # vérifie la syntaxe SANS appliquer
sudo systemctl reload nftables               # applique après vérification
sudo nft list ruleset -a                     # avec les numéros (handle) des règles
```

### Voir ce qui est bloqué
```bash
sudo journalctl -k -f | grep fw01-fwd-drop   # drops en direct (SRC, DST, DPT = port refusé)
sudo journalctl -k --since "10 min ago" | grep fw01-fwd-drop
```
Un drop donne `SRC=` (qui), `DST=` (vers qui) et `DPT=` (quel port) : c'est la règle à ajouter, ou le flux à ne pas autoriser.

### Tester un flux depuis fw01
```bash
ping -c2 10.0.20.10                          # ad01 joignable
nc -zv 10.0.20.10 389                        # port LDAP ouvert
sudo tcpdump -ni ens35 host 10.0.40.10       # voir si le trafic de win02 sort vers la zone Serveurs
```

### NAT / sortie Internet
```bash
sudo nft list table ip nat                   # masquerade sur ens32
curl -sI https://example.com | head -1       # sortie HTTPS depuis fw01
```

---

## web01 (Ubuntu, Apache)

### Réseau
```bash
ip -br a                                     # ens32 10.0.10.10/24
ip route                                     # default via 10.0.10.254
ping -c2 10.0.10.254                         # fw01
resolvectl status                            # DNS utilisé
```

### Apache
```bash
systemctl status apache2
sudo apache2ctl configtest                   # Syntax OK
sudo apache2ctl -S                           # VirtualHosts chargés (80 / 443)
sudo ss -tlnp | grep -E ':80|:443'           # Apache écoute
curl -sI http://127.0.0.1                    # en-tête "Server: Apache" sans version
curl -skI --resolve alxbdn.duckdns.org:443:127.0.0.1 https://alxbdn.duckdns.org   # HSTS présent
sudo tail -f /var/log/apache2/error.log
sudo tail -f /var/log/apache2/alxbdn.duckdns.org-error.log
```

### Certificat
```bash
sudo /root/.acme.sh/acme.sh --list                       # certificat, date de renouvellement
openssl s_client -connect 127.0.0.1:443 -servername alxbdn.duckdns.org </dev/null 2>/dev/null \
  | openssl x509 -noout -issuer -dates                  # émetteur Let's Encrypt, validité
sudo crontab -l | grep acme                             # renouvellement automatique
```

### SSH
```bash
sudo sshd -t                                             # config valide (rien = OK)
sudo sshd -T | grep -E 'passwordauth|permitroot|allowusers'   # no / no / webadmin
sudo journalctl -u ssh -f                                # tentatives de connexion en direct
ls -la /home/webadmin/.ssh                               # 700 / authorized_keys 600, propriétaire webadmin
```
Depuis `win01` : `ssh -v web01` montre quelle clé est proposée et pourquoi elle est refusée.

### Script de déploiement
```bash
sudo less /var/log/webadmin.log              # log complet du dernier lancement de webadmin.sh
```

### Système
```bash
apt list --upgradable                        # MAJ en attente
sudo apt update && sudo apt upgrade          # (depuis la console, compte setup)
```

---

## ad01 (Windows Server 2025, AD / DNS)

### Santé du contrôleur de domaine
```powershell
dcdiag /q                                    # rien = aucune erreur
Get-Service NTDS, DNS, Netlogon, KDC, W32Time | Format-Table Name, Status
Get-ADDomain | Select-Object DNSRoot, NetBIOSName, PDCEmulator
w32tm /query /status                         # heure : Kerberos tolère 5 min d'écart
```

### DNS
```powershell
Resolve-DnsName _ldap._tcp.dc._msdcs.p03.lan -Type SRV    # enregistrement SRV du DC
Get-DnsServerZone
Get-DnsServerResourceRecord -ZoneName p03.lan | Where-Object HostName -match 'win0|ad01'
Get-DnsServerForwarder                                    # résolution des noms Internet
```

### OU, comptes, ordinateurs
```powershell
Get-ADOrganizationalUnit -Filter * | Select-Object DistinguishedName
Get-ADComputer -Filter * | Select-Object Name, DistinguishedName     # win01 dans Postes-Admin, win02 dans Postes-Utilisateurs
Get-ADUser alx-org -Properties LogonWorkstations, MemberOf, AccountNotDelegated, LockedOut
Search-ADAccount -LockedOut                                         # comptes verrouillés
Unlock-ADAccount alx-wrk
Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object Name, MinPasswordLength, AppliesTo
Get-ADUserResultantPasswordPolicy alx-org                            # PSO qui s'applique vraiment
```

### GPO
```powershell
Get-GPO -All | Select-Object DisplayName, GpoStatus, ModificationTime
Get-GPInheritance -Target 'OU=Postes-Utilisateurs,OU=Ordinateurs,OU=P03,DC=p03,DC=lan'   # GPO liées et héritées
Get-GPOReport -Name 'GPO-P03-AppLocker-Postes-Utilisateurs' -ReportType Html -Path C:\gpo.html
Remove-GPO -Name '<nom>'                                             # supprimer une GPO (irréversible)
```

**Une GPO est reçue mais ses réglages ne s'appliquent pas ?** Vérifier que son extension (CSE) est enregistrée :
```powershell
(Get-ADObject (Get-GPO '<nom>').Path -Properties gPCMachineExtensionNames).gPCMachineExtensionNames
```
Doit contenir, **triés par GUID** :
- Registre : `{35378EAC-683F-11D2-A89A-00C04FBBCFA2}`
- Sécurité (droits, services) : `{827D319E-6EAC-11D2-A4EA-00C04F79F83A}`
- AppLocker : `{F312195E-3D9D-447A-A3F5-08DFFA24735E}`

### LAPS
```powershell
Get-LapsADPassword -Identity win02 -AsPlainText      # mot de passe admin local actuel + date d'expiration
Reset-LapsPassword                                   # (sur le poste) forcer une rotation
```

### Réplication SYSVOL (GPO sur disque)
```powershell
Get-ChildItem \\p03.lan\SYSVOL\p03.lan\Policies      # un dossier {GUID} par GPO
Get-SmbShare | Where-Object Name -in 'SYSVOL','NETLOGON'
```

---

## win01 (poste admin) et win02 (poste utilisateur)

### Réseau et lien avec le domaine
```powershell
ipconfig /all                                        # IP, passerelle .254, DNS 10.0.20.10 UNIQUEMENT
Test-Connection 10.0.30.254 -Count 2                 # fw01 (10.0.40.254 sur win02)
Resolve-DnsName _ldap._tcp.dc._msdcs.p03.lan -Type SRV
Test-NetConnection 10.0.20.10 -Port 389              # LDAP (aussi : 88 Kerberos, 445 SMB, 135 RPC)
Test-ComputerSecureChannel                           # True = relation de confiance OK
Test-ComputerSecureChannel -Repair -Credential P03\Administrator   # si False
nltest /dsgetdc:p03.lan                              # quel DC le poste utilise
klist                                                # tickets Kerberos de la session
```

### GPO reçues
```powershell
gpupdate /force                                      # recharge les GPO (reboot si demandé)
gpresult /r /scope computer                          # GPO appliquées / filtrées (session domaine)
gpresult /h C:\gpresult.html                         # rapport complet
```
Depuis un compte local (gpresult échoue), lire l'état dans le registre :
```powershell
$S = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine'
(Get-ItemProperty $S).'Distinguished-Name'           # OU du poste
Get-ChildItem "$S\GPO-List" | ForEach-Object { (Get-ItemProperty $_.PSPath).DisplayName }
```
Erreurs de traitement des GPO :
```powershell
Get-WinEvent -LogName 'Microsoft-Windows-GroupPolicy/Operational' -MaxEvents 30 | Where-Object LevelDisplayName -ne 'Information'
```

### Réglages précis
```powershell
Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System' InactivityTimeoutSecs   # 600
secedit /export /areas USER_RIGHTS /cfg $env:TEMP\r.inf; Select-String SeDenyRemoteInteractive $env:TEMP\r.inf   # *S-1-5-114
```

### AppLocker (win02)
```powershell
Get-Service AppIDSvc                                                  # Running
Get-AppLockerPolicy -Effective -Xml                                   # règles reçues (vide = rien d'appliqué)
Get-AppLockerPolicy -Effective | Test-AppLockerPolicy -Path "$HOME\Desktop\whoami.exe" -User P03\alx-wrk   # Denied attendu
Get-WinEvent -LogName 'Microsoft-Windows-AppLocker/EXE and DLL' -MaxEvents 20 | Format-Table TimeCreated, Id, Message -Wrap
```
Events AppLocker : **8002** autorisé, **8004** bloqué. Test réel : copier `C:\Windows\System32\whoami.exe` sur le Bureau de `alx-wrk` et le lancer : « This app has been blocked by your system administrator ».

### LAPS (sur le poste)
```powershell
Get-LocalUser | Where-Object { $_.SID -like '*-500' }                 # Administrator activé
Invoke-LapsPolicyProcessing                                           # force le traitement LAPS
Get-WinEvent -LogName 'Microsoft-Windows-LAPS/Operational' -MaxEvents 20 | Format-Table TimeCreated, Id, Message -Wrap
```
Event **10020** = mot de passe envoyé dans l'AD.

### Comptes et profils locaux
```powershell
Get-LocalUser | Format-Table Name, Enabled, LastLogon
Get-CimInstance Win32_UserProfile | Select-Object LocalPath, Loaded   # Loaded = True : impossible à supprimer, redémarrer
whoami /groups                                                       # groupes de la session (admin ? Protected Users ?)
```

### Scripts du projet
```powershell
.\workstation-check.ps1           # vérifie OU, GPO, verrouillage, refus RDP, AppLocker, LAPS
```

### win01 seulement : outils d'admin
```powershell
Get-WindowsCapability -Online -Name Rsat* | Where-Object State -eq Installed
ssh -v web01                                                          # détail de l'authentification par clé
icacls $HOME\.ssh\webadmin                                            # seulement alx-org + SYSTEM
```

---

## Pièges déjà rencontrés

| Symptôme | Cause | Correctif |
|---|---|---|
| GPO listée par `gpresult` mais réglages absents | Extension (CSE) absente de `gPCMachineExtensionNames` ou liste non triée | Ajouter le GUID, trier (voir ad01 > GPO) |
| SRP sans effet sur Windows 11 | SRP n'est plus appliquée par les Windows récents | AppLocker |
| `ssh web01` demande un mot de passe | Durcissement de web01 perdu, clé absente côté serveur | Relancer `webadmin.sh` |
| Ancienne `Apache/2.4.x (Ubuntu)` dans l'en-tête | `security.conf` lu après `hardening.conf` | `a2disconf security` |
| Clone Ubuntu : `Cannot find unique matching interface` | Netplan du template avec la MAC d'origine | Déplacer `00-installer-config.yaml` |
| `Remove-CimInstance` profil : « used by another process » | Profil encore chargé | Redémarrer puis relancer |
| `$env:USERNAME` faux dans une fenêtre élevée par UAC | Garde le nom de la session, pas du compte élevé | `[Security.Principal.WindowsIdentity]::GetCurrent().Name` |
