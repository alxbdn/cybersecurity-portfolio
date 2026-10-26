# P03 · Recette

La recette prouve deux choses : **ce qui doit passer passe**, et **ce qui doit être bloqué est bloqué**. Chaque test donne une commande, le résultat attendu et la règle qu'il vérifie dans [`nftables-02-full.conf`](fw01/config/nftables-02-full.conf). Un test ✗ qui *passe* est aussi grave qu'un test ✓ qui échoue.

## Avant de commencer

1. `fw01` est en filtrage complet : `sudo fw01-nft-apply.sh`, choix **2**, puis snapshot `fw01-04-filtrage`.
2. **Cartes de l'hôte décochées** sur VMnet11, 12 et 14 (VMware → *Edit → Virtual Network Editor → Change Settings* → décocher *Connect a host virtual adapter to this network*). Seule VMnet13 reste cochée : le PC hôte devient un poste de la zone Admin (`10.0.30.1`). Sans ça, le PC touche directement la DMZ et les autres zones, et les tests passent à côté du pare-feu.
3. Sur `fw01`, une 2e fenêtre ouverte sur les journaux :
   ```bash
   tail -f /var/log/fw01-nftables.log | grep --line-buffered -E 'fwd-drop|in-drop'
   ```
   Chaque test ✗ doit y faire apparaître une ligne `fw01-fwd-drop` (ou `fw01-in-drop` si la cible est `fw01` lui-même). Les refus sont limités à 10 lignes par minute : espace les tests si une ligne manque.

**Lire les résultats**

| Outil | Autorisé (✓) | Bloqué (✗) |
|---|---|---|
| `nc -zv -w3 IP PORT` (Linux) | `succeeded` / `open` | `timed out` (le paquet est jeté, `drop`) |
| `Test-NetConnection IP -Port N` (Windows) | `TcpTestSucceeded : True` | `False` après ~20 s |
| `curl -sI URL \| head -1` | `HTTP/... 200` | rien, ou `Connection timed out` |

⚠ « Bloqué » veut dire *timeout*. Un `Connection refused` immédiat veut dire que le paquet **est passé** et que la machine d'en face n'écoute pas sur ce port : le pare-feu a laissé passer.

Pour chaque test, note ✅ (résultat conforme) ou ❌ dans la colonne Résultat.

---

## 1. Depuis Internet (PC hôte, carte VMnet8)

Le PC hôte est aussi sur le réseau WAN (`192.168.93.1`) : il joue le rôle d'un client sur Internet.

| # | Flux | Commande (PowerShell sur l'hôte) | Attendu | Résultat |
|---|---|---|---|---|
| I1 | Internet → site public (DNAT 443) | `curl.exe -kI https://192.168.93.10` | ✓ `HTTP/1.1 200 OK`, en-tête `Strict-Transport-Security` | |
| I2 | Internet → SSH de fw01 | `Test-NetConnection 192.168.93.10 -Port 22` | ✗ `False` | |
| I3 | Internet → web01 en 80 | `Test-NetConnection 192.168.93.10 -Port 80` | ✗ `False` (seul le 443 est redirigé) | |

## 2. Depuis la DMZ (web01)

`web01` est la machine la plus exposée : elle ne doit atteindre qu'Internet, et rien à l'intérieur.

| # | Flux | Commande (bash sur web01) | Attendu | Résultat |
|---|---|---|---|---|
| D1 | DMZ → Internet HTTPS | `curl -sI https://ubuntu.com \| head -1` | ✓ `HTTP/2 200` | |
| D2 | DMZ → DNS VMware | `dig +short ubuntu.com @192.168.93.2` | ✓ des adresses IP | |
| D3 | DMZ → heure (NTP) | `timedatectl show -p NTPSynchronized` | ✓ `NTPSynchronized=yes` | |
| D4 | DMZ → ad01 SMB | `nc -zv -w3 10.0.20.10 445` | ✗ timeout + `fw01-fwd-drop IN=ens34 OUT=ens35` | |
| D5 | DMZ → DNS de l'AD | `dig +time=3 +tries=1 p03.lan @10.0.20.10` | ✗ `no servers could be reached` | |
| D6 | DMZ → poste admin | `nc -zv -w3 10.0.30.10 3389` | ✗ timeout | |
| D7 | DMZ → poste utilisateur | `nc -zv -w3 10.0.40.10 3389` | ✗ timeout | |
| D8 | DMZ → SSH de fw01 | `nc -zv -w3 10.0.10.254 22` | ✗ timeout + `fw01-in-drop` | |
| D9 | DMZ → Internet en SSH | `nc -zv -w3 github.com 22` | ✗ timeout (seuls 53, 123, 80, 443 sortent) | |
| D10 | DMZ → passerelle (ping) | `ping -c2 10.0.10.254` | ✓ réponses | |

## 3. Depuis la zone Admin (win01, ou l'hôte en 10.0.30.1)

Le seul endroit d'où l'on administre. À lancer en session `P03\alx-org`.

| # | Flux | Commande (PowerShell sur win01) | Attendu | Résultat |
|---|---|---|---|---|
| A1 | Admin → SSH fw01 | `ssh fw01` | ✓ session `fwadmin` + ligne `fw01-ssh-in` | |
| A2 | Admin → SSH web01 | `ssh web01` | ✓ session `webadmin` | |
| A3 | Admin → site web01 | `curl.exe -I https://alxbdn.duckdns.org` | ✓ `HTTP/1.1 200 OK` | |
| A4 | Admin → ad01 RDP | `Test-NetConnection ad01.p03.lan -Port 3389` | ✓ `True` | |
| A5 | Admin → ad01 WinRM | `Enter-PSSession ad01` | ✓ invite `[ad01]: PS>` | |
| A6 | Admin → ad01 LDAP | `Test-NetConnection ad01.p03.lan -Port 389` | ✓ `True` | |
| A7 | Admin → DNS de l'AD | `Resolve-DnsName ad01.p03.lan` | ✓ `10.0.20.10` | |
| A8 | Admin → win02 RDP | `Test-NetConnection 10.0.40.10 -Port 3389` | ✓ `True` si RDP est activé sur win02, sinon `False` sans ligne `fwd-drop` (c'est win02 qui refuse) | |
| A9 | Admin → win02 ping | `ping -n 2 10.0.40.10` | ✓ réponses si le pare-feu Windows de win02 autorise l'ICMP | |
| A10 | Admin → Internet | `Test-NetConnection ubuntu.com -Port 443` | ✗ `False` (choix assumé : poste d'admin sans Internet, voir [README](../README.md#les-choix-et-leur-raison)) | |
| A11 | Admin → web01 en ping | `ping -n 2 10.0.10.10` | ✗ délai dépassé (seuls 22 et 443 sont ouverts) | |

Mot de passe SSH refusé, même depuis la bonne zone :

| # | Test | Commande | Attendu | Résultat |
|---|---|---|---|---|
| A12 | fw01 sans clé | `ssh -o PubkeyAuthentication=no fwadmin@10.0.30.254` | ✗ `Permission denied (publickey)` | |
| A13 | root sur fw01 | `ssh -i $HOME\.ssh\fwadmin-win01 root@10.0.30.254` | ✗ `Permission denied` | |

## 4. Depuis la zone Users (win02)

Un poste utilisateur navigue et utilise le domaine, mais n'administre rien. À lancer en session `alx-wrk`.

| # | Flux | Commande (PowerShell sur win02) | Attendu | Résultat |
|---|---|---|---|---|
| U1 | Users → Internet HTTPS | `curl.exe -sI https://ubuntu.com` | ✓ `HTTP/... 200` | |
| U2 | Users → DNS via l'AD | `Resolve-DnsName ubuntu.com` | ✓ des adresses (résolu par ad01) | |
| U3 | Users → site de l'entreprise | `curl.exe -I https://alxbdn.duckdns.org` | ✓ `HTTP/1.1 200 OK` | |
| U4 | Users → ad01 Kerberos / LDAP | `Test-NetConnection ad01.p03.lan -Port 88` puis `-Port 389` | ✓ `True` | |
| U5 | Users → GPO | `gpupdate /force` | ✓ « La mise à jour de la stratégie … s'est terminée sans erreur » | |
| U6 | Users → DNS direct sur Internet | `Resolve-DnsName ubuntu.com -Server 192.168.93.2 -QuickTimeout` | ✗ délai dépassé (le DNS passe par ad01) | |
| U7 | Users → ad01 RDP | `Test-NetConnection ad01.p03.lan -Port 3389` | ✗ `False` + `fw01-fwd-drop IN=ens37 OUT=ens35` | |
| U8 | Users → ad01 WinRM | `Test-NetConnection ad01.p03.lan -Port 5985` | ✗ `False` (bloqué par fw01 **et** par le pare-feu d'ad01) | |
| U9 | Users → poste admin | `Test-NetConnection 10.0.30.10 -Port 3389` | ✗ `False` | |
| U10 | Users → SSH web01 | `Test-NetConnection 10.0.10.10 -Port 22` | ✗ `False` | |
| U11 | Users → SSH fw01 | `Test-NetConnection 10.0.40.254 -Port 22` | ✗ `False` + `fw01-in-drop` | |
| U12 | Users → Internet hors web | `Test-NetConnection github.com -Port 22` | ✗ `False` (seuls 80 et 443 sortent) | |

## 5. Depuis la zone Serveurs (ad01)

| # | Flux | Commande (PowerShell sur ad01, via `Enter-PSSession ad01` depuis win01) | Attendu | Résultat |
|---|---|---|---|---|
| S1 | ad01 → redirecteur DNS | `Resolve-DnsName ubuntu.com` | ✓ des adresses | |
| S2 | ad01 → Internet HTTPS | `Test-NetConnection ubuntu.com -Port 443` | ✓ `True` (Windows Update) | |
| S3 | ad01 → web01 | `Test-NetConnection 10.0.10.10 -Port 443` | ✗ `False` (pas de flux Serveurs → DMZ) | |
| S4 | ad01 → poste utilisateur | `Test-NetConnection 10.0.40.10 -Port 445` | ✗ `False` (le DC ne contacte pas les postes, ce sont eux qui viennent à lui) | |

## 6. Le pare-feu lui-même (fw01)

| # | Test | Commande (bash sur fw01) | Attendu | Résultat |
|---|---|---|---|---|
| F1 | Politique par défaut | `sudo nft list ruleset \| grep policy` | ✓ `input` et `forward` en `policy drop` | |
| F2 | Persistance au redémarrage | `sudo reboot`, puis F1 et D1 à nouveau | ✓ même résultat sans relancer de script | |
| F3 | Routage et durcissement noyau | `sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_redirects` | ✓ `1`, `1`, `0` | |
| F4 | IPv6 désactivé | `ip -6 a` | ✓ aucune sortie | |
| F5 | Journaux des refus | `grep -c fw01-fwd-drop /var/log/fw01-nftables.log` | ✓ un compteur non nul après les tests ✗ | |
| F6 | Rotation des journaux | `sudo logrotate -d /etc/logrotate.d/fw01-nftables` | ✓ aucune ligne `error` | |
| F7 | SSH : clé seule, fwadmin seul | `sudo sshd -T \| grep -E 'passwordauthentication\|permitrootlogin\|allowusers'` | ✓ `no`, `no`, `fwadmin` | |
| F8 | Ports en écoute | `sudo ss -tlnp` | ✓ `0.0.0.0:22` (sshd), plus le résolveur local `127.0.0.53` / `127.0.0.54` : rien d'autre ouvert vers le réseau | |

---

## Preuves à garder

Une capture par famille suffit, rangée dans `fw01/captures/` :

1. **Le blocage** : D4 côté web01 (timeout) et la ligne `fw01-fwd-drop` correspondante sur fw01.
2. **Le site public** : I1 (200 et HSTS depuis le WAN).
3. **L'administration cloisonnée** : A1 qui marche depuis win01, U11 qui échoue depuis win02.
4. **La défense en profondeur** : U8 (WinRM refusé depuis Users).
5. **La politique** : F1 (`policy drop`).

**Déjà obtenues pendant le montage**

| Preuve | Capture |
|---|---|
| Filtrage appliqué, 6 phases vertes | [fw01/captures/01](fw01/captures/01_fw01-nft-apply_6-phases-OK.png) |
| D1 + D4 : web01 sort sur Internet, SMB vers ad01 bloqué | [fw01/captures/02](fw01/captures/02_web01-internet-OK_smb-ad01-bloque.png) |
| D4 : la ligne `fw01-fwd-drop` correspondante | [fw01/captures/03](fw01/captures/03_fw01-fwd-drop_dmz-vers-serveurs.png) |
| Site servi en HTTPS avec HSTS | [fw01/captures/04](fw01/captures/04_fw01-curl-web01-HSTS.png) |
| A4 : RDP vers ad01 depuis win01 en `alx-org` | [ad01/captures/04](ad01/captures/04_ad01-rdp-depuis-win01-alx-org.png) |
| `alx-org` non délégable : double saut refusé | [ad01/captures/05](ad01/captures/05_ad01-double-saut-refuse-non-delegable.png) |
| U8 : WinRM refusé depuis win02, LDAP OK | [ad01/captures/02](ad01/captures/02_win02-winrm-refuse-ldap-ok.png) |

## Si un test ne donne pas le bon résultat

- **Un ✓ bloqué** : cherche la ligne `fw01-fwd-drop` du test. `IN=`, `OUT=`, `SRC=`, `DST=` et `DPT=` disent exactement quelle règle manque. Ajoute-la dans `nftables-02-full.conf`, puis relance `sudo fw01-nft-apply.sh ~/nftables-02-full.conf` (retour arrière automatique si tu te coupes l'accès).
- **Un ✗ qui passe** : vérifie d'abord que la carte de l'hôte est bien décochée sur ce VMnet (sinon le flux ne traverse pas fw01), puis cherche la règle trop large avec `sudo nft list ruleset`.
- Méthode complète : [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
