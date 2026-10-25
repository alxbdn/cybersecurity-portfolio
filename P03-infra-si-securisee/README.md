# P03 · Sécuriser l'infrastructure SI d'une entreprise

> **Le besoin** : à partir de la demande d'un client, proposer et monter une architecture SI sécurisée, avec au moins une mesure recommandée par l'ANSSI.

## En bref

J'ai monté l'infrastructure d'une petite entreprise dans un lab VMware : un pare-feu central, un réseau découpé en zones, un serveur web exposé sur Internet, un domaine Active Directory et deux postes de travail. Chaque mesure est choisie en fonction du risque (principe de proportionnalité), justifiée et prouvée par un test. Tout est déployé par des scripts idempotents, qu'on peut relancer sans risque.

## Architecture

```
                         Internet
                            │
                     VMnet8 (NAT) · 192.168.93.0/24
                            │
                    ┌───────┴───────┐
                    │     fw01      │  routeur + pare-feu (nftables)
                    │  .254 partout │  politique drop par défaut
                    └─┬───┬───┬───┬─┘
          ┌───────────┘   │   │   └────────────┐
          │               │   │                │
   DMZ 10.0.10.0/24  Serveurs 10.0.20.0/24  Admin 10.0.30.0/24  Users 10.0.40.0/24
       web01             ad01                  win01               win02
   Apache, HTTPS     AD DS + DNS           poste admin         poste utilisateur
                     p03.lan               RSAT, clé SSH       AppLocker
```

| Zone | VMnet | Réseau | Machine | Rôle |
|---|---|---|---|---|
| WAN | VMnet8 (NAT) | 192.168.93.0/24 | `fw01` (`.10`) | Sortie Internet |
| DMZ | VMnet11 | 10.0.10.0/24 | `web01` (`.10`) | Site public `alxbdn.duckdns.org` |
| Serveurs | VMnet12 | 10.0.20.0/24 | `ad01` (`.10`) | Windows Server 2025 Standard, AD / DNS |
| Admin | VMnet13 | 10.0.30.0/24 | `win01` (`.10`) | Windows 11 + RSAT, seul point d'administration |
| Users | VMnet14 | 10.0.40.0/24 | `win02` (`.10`) | Windows 11, poste utilisateur |

`fw01` est la passerelle (`.254`) de chaque zone. Le PC hôte n'est branché que sur la zone Admin.

## Les choix et leur raison

| Choix | Pourquoi | Référence |
|---|---|---|
| Réseau découpé en 5 zones de confiance | Une machine compromise ne voit que sa zone | ANSSI administration sécurisée |
| Filtrage centralisé sur `fw01`, politique `drop` par défaut, refus journalisés | Un seul point de contrôle, simple à auditer ; seul ce qui est utile passe | ANSSI filtrage réseau |
| Administration uniquement depuis la zone Admin (`win01`) | Les ports d'admin (SSH, RDP, WinRM, RSAT) ne sont joignables que depuis le poste dédié | ANSSI administration sécurisée |
| Deux barrières pour le DC : `fw01` **et** le pare-feu Windows d'`ad01` | Si une règle de `fw01` saute, un poste utilisateur ne peut toujours pas administrer le DC | Défense en profondeur |
| `web01` n'utilise pas le DNS de l'AD | Aucun flux DMZ → Serveurs : la machine la plus exposée n'atteint jamais le contrôleur de domaine | ANSSI admin. sécurisée R16 |
| SSH par clé ECDSA uniquement, un compte dédié par serveur (`webadmin`, `fwadmin`), root interdit | Un mot de passe volé ne sert à rien | ANSSI NT OpenSSH R9, R10, R17, R22 |
| Apache sans version, sans listing, TRACE coupé ; HTTPS Let's Encrypt, TLS 1.2 / 1.3, HSTS | Moins d'informations pour l'attaquant, échanges chiffrés | Guides ANSSI sites web et TLS |
| Deux comptes par admin : `alx-wrk` (quotidien) et `alx-org` (domaine) | Jamais de navigation ou de mail avec un compte à privilèges | ANSSI administration sécurisée |
| `alx-org` limité à `win01` / `ad01`, non délégable, Protected Users | Un mot de passe admin volé est inutilisable ailleurs, pas de NTLM ni de cache | ANSSI administration sécurisée |
| Deux politiques de mots de passe : 12 caractères (utilisateurs), 16 (admins) | Exigence plus forte là où l'impact est le plus grand | ANSSI mots de passe |
| Windows LAPS : admin local unique par poste, changé tous les 30 jours | Un poste compromis ne donne pas la clé des autres | |
| AppLocker sur les postes utilisateurs | Un utilisateur ne peut pas lancer un programme téléchargé | |
| Verrouillage de session 10 min, RDP interdit aux comptes locaux | Pas de session abandonnée, pas de rebond avec un mot de passe local | |
| Aucun secret dans les scripts (token DuckDNS demandé au lancement) | Le dépôt peut être public | |

**Proportionnalité** : pas de SIEM, de bastion ni de PKI interne pour une entreprise de cette taille. Évolutions possibles : `ad01` en Server Core, un compte dédié au support des postes.

## Ordre de déploiement

| # | Machine | Étape | Guide |
|---|---|---|---|
| 1 | `fw01` | Réseau 5 cartes, SSH par clé (`fwadmin.sh`), **routage + NAT seulement** (tout passe, mais journalisé) | [fw01](fw01/README.md) |
| 2 | `web01` | Réseau DMZ, `webadmin.sh` | [web01](web01/README.md) |
| 3 | `ad01` | Promotion `p03.lan`, puis `ad01-setup-domain.ps1` et `ad01-setup-gpo.ps1` | [ad01](ad01/README.md) |
| 4 | `win01` | RSAT (en NAT), jonction, vérif LAPS / GPO, clé SSH vers web01 | [win0x](win0x/README.md) |
| 5 | `win02` | Jonction, vérif LAPS / GPO, test AppLocker | [win0x](win0x/README.md) |
| 6 | `ad01` | `ad01-harden-ports.ps1` lancé depuis `win01` | [ad01](ad01/README.md#5-fermer-les-ports-dadministration) |
| 7 | `fw01` | **Filtrage complet** : matrice ci-dessous | [fw01](fw01/README.md#6-étape-2--filtrage-complet) |
| 8 | Lab | Décocher la carte de l'hôte sur VMnet11 / 12 / 14 | |

Pourquoi le filtrage en dernier : pendant le montage, un flux bloqué ressemble à une panne. On valide chaque machine d'abord, puis on ferme, et chaque flux qui manque apparaît dans les logs `fw01-fwd-drop`.

## Matrice des flux

Appliquée par [`nftables-02-full.conf`](fw01/config/nftables-02-full.conf). Tout ce qui n'est pas listé est refusé et journalisé.

| Depuis | Vers | Ports | Usage |
|---|---|---|---|
| Internet | `web01` | 443 (DNAT) | Site public |
| `web01` | Internet | 53, 123, 80, 443 | DNS, heure, apt, certificat |
| Admin | `web01` | 22, 443 | Admin par clé, test du site |
| Admin + Users | `ad01` | 53, 88, 123, 135, 389, 445, 464, 636, 3268-3269, 49152-65535 | Ce qu'un membre du domaine doit joindre |
| Admin | `ad01` | 3389, 5985, 9389 | RDP, WinRM, RSAT |
| `ad01` | Internet | 53, 123, 80, 443 | Redirecteur DNS, heure, Windows Update |
| Users | Internet | 80, 443 | Navigation web (le DNS passe par `ad01`, jamais en direct) |
| Users | `web01` | 443 | Le site de l'entreprise |
| Admin | Users | 3389, 5985, ping | Support des postes utilisateurs depuis la zone Admin |
| Admin | `fw01` | 22 | Admin du pare-feu (connexions journalisées) |
| DMZ | Serveurs | ✗ | `web01` ne parle jamais au DC |
| Users | Admin, ports d'admin d'`ad01`, DNS direct | ✗ | Un poste utilisateur n'administre rien |

## Machines

| Machine | Ce qui est fait | Guide | État |
|---|---|---|---|
| `fw01` | Routage, NAT, filtrage entre zones | [fw01/](fw01/README.md) | 🚧 Filtrage complet à appliquer |
| `web01` | Apache durci, SSH par clé, HTTPS | [web01/](web01/README.md) | ✅ |
| `ad01` | Domaine `p03.lan` : OU, comptes séparés, PSO, GPO, AppLocker, LAPS, ports d'admin fermés | [ad01/](ad01/README.md) | ✅ |
| `win01` / `win02` | Joints dans leur OU, GPO et LAPS vérifiés, AppLocker testé | [win0x/](win0x/README.md) | ✅ |

Commandes de vérification et de dépannage : [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Ce que j'ai appris en route

- **Une vérification automatique trouve les vrais bugs.** `webadmin.sh` échouait à la phase 4 : `security.conf` d'Ubuntu était lu après mon réglage et rendait sa version à Apache ([capture](web01/captures/00_bug_ServerTokens-ecrase-par-security-conf.png)).
- **Une GPO reçue n'est pas une GPO appliquée.** La restriction logicielle (SRP) est ignorée par Windows 11, d'où AppLocker. Et AppLocker lui-même ne s'appliquait pas tant que son extension n'était pas déclarée sur la GPO : le script l'ajoute maintenant ([preuve](win0x/captures/01_applocker-win02-whoami-bloque.png)).
- **Deux barrières valent mieux qu'une.** Depuis `win02`, WinRM vers `ad01` est refusé alors que LDAP répond, même avec `fw01` encore ouvert ([capture](ad01/captures/02_win02-winrm-refuse-ldap-ok.png)).

## Outils

VMware Workstation · Ubuntu Server · nftables · Apache2 · OpenSSH · acme.sh · Windows Server 2025 · Active Directory · PowerShell · GPO · AppLocker · Windows LAPS
