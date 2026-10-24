# P03 · Sécuriser l'infrastructure SI d'une entreprise

> **Le besoin** : à partir de la demande d'un client, proposer et monter une architecture SI sécurisée, avec au moins une mesure recommandée par l'ANSSI.

## En bref

J'ai monté l'infrastructure d'une petite entreprise dans un lab VMware : un pare-feu central, un réseau découpé en zones, un serveur web exposé sur Internet et un domaine Active Directory. Chaque mesure est choisie en fonction du risque (principe de proportionnalité), justifiée et prouvée par un test.

## Architecture

Le réseau est découpé en 5 zones. `fw01` est la passerelle de chacune (`.254`) et filtre tout ce qui passe d'une zone à l'autre.

| Zone | Réseau | Rôle | Machines |
|---|---|---|---|
| WAN | NAT | Sortie Internet | `fw01` |
| DMZ | 10.0.10.0/24 | Services exposés | `web01` (Apache) |
| Serveurs | 10.0.20.0/24 | Services internes | `DC` (Windows Server 2025, AD / DNS) |
| Admin | 10.0.30.0/24 | Administration uniquement | Poste admin (Windows 11 + RSAT) |
| Users | 10.0.40.0/24 | Postes de travail | Poste utilisateur (Windows 11) |

`fw01` fait à la fois **routeur et pare-feu** : tout le filtrage est centralisé chez lui, les serveurs n'ont pas de pare-feu local. C'est aussi lui qui n'autorise le SSH vers les serveurs que depuis la zone Admin. Sur les serveurs, l'accès se fait uniquement par clé.

## Composants

| Machine | Ce qui est fait | Dossier | État |
|---|---|---|---|
| `web01` | Serveur web Apache durci, déployé par un script | [web01/](web01/) | ✅ Terminé |
| `fw01` | Pare-feu, routage et NAT entre les zones | `fw01/` | 🚧 En cours |
| `DC` | Active Directory, GPO, politiques de mots de passe admin / utilisateurs | `ad/` | ⏳ À venir |

## web01 : le serveur web

Un seul script, [`webadmin.sh`](web01/scripts/webadmin.sh), installe et verrouille le serveur en 6 phases, en vérifiant chacune. On peut le relancer sans risque (idempotent).

| Mesure | Pourquoi | Référence |
|---|---|---|
| Compte dédié `webadmin` pour gérer le site, sans mot de passe | Ne pas administrer en root, moindre privilège | ANSSI NT OpenSSH R21 |
| SSH par clé uniquement (ECDSA P-256), compte `webadmin` seul, root interdit | Rendre le vol de mot de passe inutile | ANSSI NT OpenSSH R9, R10, R17, R22 |
| Apache n'affiche plus sa version, pas de listing de dossiers, méthode TRACE coupée | Donner le moins d'informations possible à un attaquant | Guide ANSSI sites web |
| Pas de pare-feu local : le filtrage est fait par `fw01` | Un seul point de contrôle, des règles plus simples à auditer et sans doublon | |
| HTTPS avec un vrai certificat Let's Encrypt, TLS 1.2 / 1.3, HSTS | Chiffrer les échanges, empêcher le retour en HTTP | Guide ANSSI TLS |
| Token DuckDNS demandé au lancement, jamais écrit sur disque | Aucun secret dans le code | |

### Preuves

| Test | Capture |
|---|---|
| Le script passe toutes ses phases | [01](web01/captures/01_webadmin-test_7-phases-OK.png) |
| Le compte `setup` est refusé en SSH, Apache ne montre pas sa version, HSTS présent | [02](web01/captures/02_ssh-setup-refuse_curl-Server-Apache-HSTS.png) |
| `webadmin` se connecte avec sa clé | [03](web01/captures/03_ssh-webadmin-cle-OK_mkdir-test.png) |
| Un dossier sans index renvoie 403 au lieu de lister les fichiers | [04](web01/captures/04_directory-listing-desactive-403.png) |
| Certificat Let's Encrypt valide | [05](web01/captures/05_certificat-LetsEncrypt-YE2.png) |
| Le site répond en HTTPS | [06](web01/captures/06_https-alxbdn-duckdns-org.png) |

### Ce que j'ai appris en route

La première version échouait à la phase 4 : Apache affichait encore sa version malgré `ServerTokens Prod` ([capture](web01/captures/00_bug_ServerTokens-ecrase-par-security-conf.png)). Le fichier `security.conf` d'Ubuntu était lu **après** le mien et écrasait le réglage. Je l'ai désactivé dans le script, et c'est justement la vérification automatique qui avait repéré le problème.

👉 Le pas-à-pas complet est dans le [tuto de déploiement](web01/docs/tuto-deploiement-web01.md).

## Outils

VMware Workstation · Ubuntu Server · Apache2 · OpenSSH · UFW · acme.sh · Windows Server 2025 · Active Directory
