# win01 / win02 · Postes de travail

Deux clones d'un template Windows 11 Entreprise, joints au domaine `p03.lan` directement dans leur OU.

| | win01 (poste admin) | win02 (poste utilisateur) |
|---|---|---|
| Zone | Admin, VMnet13 | Users, VMnet14 |
| IP | `10.0.30.10/24`, passerelle `.254` | `10.0.40.10/24`, passerelle `.254` |
| DNS | `10.0.20.10` (ad01) **uniquement** | idem |
| OU | `Postes-Admin` | `Postes-Utilisateurs` |
| Compte de travail | `P03\alx-org` | `P03\alx-wrk` |
| En plus | RSAT, clé SSH vers web01 | AppLocker |

Prérequis : [ad01](../ad01/README.md) jusqu'à l'étape 4 (OU et GPO en place), [fw01](../fw01/README.md) qui laisse passer win01 et win02 vers ad01.

## Les scripts

| Script | Rôle |
|---|---|
| [`workstation-join.ps1`](scripts/workstation-join.ps1) | IP fixe, DNS = ad01, test de chaque maillon réseau, puis renommage + jonction dans la bonne OU |
| [`workstation-check.ps1`](scripts/workstation-check.ps1) | Vérifie OU, GPO, verrouillage, refus RDP, AppLocker, LAPS. `-Cleanup` supprime le compte local provisoire |
| [`win01-admin-tools.ps1`](scripts/win01-admin-tools.ps1) | win01 seulement : `-RSAT` (consoles d'admin), `-SSHKey` (clé `webadmin`, clé `fwadmin-win01` générée sur place, `.ssh\config` durci pour web01 et fw01) |

Tous se lancent en PowerShell **admin**, dans Windows PowerShell 5.1 :
`powershell -ExecutionPolicy Bypass -File .\<script>.ps1`

## Un seul compte local provisoire

Le poste a besoin d'un admin local le temps de la jonction. On n'en crée **qu'un**, `setup`, à l'OOBE du clone. Après la jonction, c'est l'`Administrator` intégré, géré par LAPS, qui prend le relais, et `setup` est supprimé.

Pour que l'OOBE accepte le nom `setup`, le template ne doit contenir aucun compte local à part l'`Administrator` intégré : on le prépare en **mode audit** (`Ctrl+Maj+F3` à l'OOBE), puis `sysprep /generalize /oobe /shutdown`.

## Déploiement, pas à pas

| # | Étape | win01 | win02 |
|---|---|---|---|
| 1 | Cloner le template, encore en **NAT**. OOBE : compte local `setup`. Installer les VMware Tools (copier-coller, glisser-déposer) | ✔ | ✔ |
| 2 | `win01-admin-tools.ps1 -RSAT` tant que la VM a Internet (~40 min) | ✔ | |
| 3 | VM éteinte : carte réseau sur **VMnet13** / **VMnet14** | ✔ | ✔ |
| 4 | `workstation-join.ps1 -Name win01` (ou `win02`). Demande le mot de passe de `P03\Administrator`, redémarre | ✔ | ✔ |
| 5 | En `.\setup` : `workstation-check.ps1`. Tout doit être OK, il active l'`Administrator` LAPS | ✔ | ✔ |
| 6 | Lire le mot de passe LAPS (sur ad01, ou win01 en `alx-org`) : `Get-LapsADPassword -Identity win0X -AsPlainText` | ✔ | ✔ |
| 7 | Redémarrer, se connecter en `.\Administrator` avec ce mot de passe, puis `workstation-check.ps1 -Cleanup` | ✔ | ✔ |
| 8 | En `P03\alx-org` : déposer la clé privée `webadmin` sur le Bureau, `win01-admin-tools.ps1 -SSHKey`, puis `ssh web01`. Ajouter la clé publique affichée sur fw01 pour `ssh fw01` | ✔ | |
| 9 | En `P03\alx-wrk` : copier `C:\Windows\System32\whoami.exe` sur le Bureau et le lancer → bloqué | | ✔ |

L'étape 7 est aussi la preuve que LAPS fonctionne. Snapshot de chaque poste à la fin.

## Résultat

- win01 dans `Postes-Admin` avec 3 GPO, win02 dans `Postes-Utilisateurs` avec les 4 (AppLocker compris).
- Plus aucun compte local commun aux clones : seul l'`Administrator` LAPS reste, avec un mot de passe différent par poste.
- `ssh web01` par clé depuis win01, sans mot de passe.
- `whoami.exe` lancé depuis le Bureau de `alx-wrk` : « This app has been blocked by your system administrator » ([capture](captures/01_applocker-win02-whoami-bloque.png)).
- Preuves : [workstation-check OK](captures/02_win01-workstation-check-OK.png) · [mot de passe LAPS chiffré dans l'AD](captures/03_win01-laps-mot-de-passe-chiffre-AD.png) · [RSAT installé](captures/04_win01-rsat-installe.png) · [GPO win01](captures/05_win01-gpresult-gpo-appliquees.png) · [GPO + AppLocker win02](captures/06_win02-gpo-applocker-appliquees.png)

## Erreurs à éviter

| Piège | Ce qu'il faut faire |
|---|---|
| « Domain join instead » à l'OOBE | Ne joint rien à l'AD, crée juste un compte local. La vraie jonction, c'est `workstation-join.ps1` |
| L'OOBE refuse `setup` | Le compte existe déjà dans l'image : refaire le template en mode audit (voir plus haut). Les noms `admin`, `user`, `guest` sont aussi refusés |
| RSAT lancé après le passage en VMnet13 | La zone Admin n'a pas Internet : installer RSAT **avant**, en NAT |
| Jonction : ping KO | Mauvais VMnet |
| Jonction : DNS ou ports KO | Règles fw01, ou un 2e DNS (box, 8.8.8.8) configuré à côté d'ad01 |
| Renommer le PC à la main avant la jonction | Inutile : le script renomme et joint en un seul redémarrage |
| `-Cleanup` lancé avant la vérification | L'`Administrator` est encore désactivé : le script refuse désormais. Toujours étape 5, puis 7 |
| Profil `setup` : « used by another process » | Profil encore chargé : redémarrer, puis relancer `-Cleanup` |
| `gpresult` échoue en compte local | Normal : `workstation-check.ps1` lit l'état des GPO dans le registre |
| AppLocker reçu mais rien n'est bloqué | Le service `AppIDSvc` doit tourner : redémarrer le poste après `gpupdate /force` |
| Bloc-notes : `config.txt` au lieu de `config` | Laisser `-SSHKey` écrire `.ssh\config`, ou choisir « Tous les fichiers » |
| `ssh web01` demande un mot de passe | Vérifier `whoami` = `p03\alx-org` et que c'est la clé **privée** (pas `.pub`). Si la clé est bien proposée, c'est web01 qui a perdu son durcissement : relancer `webadmin.sh` |
| Dossier partagé VMware laissé actif | C'est une porte entre l'hôte et la zone : le désactiver après la copie des scripts |
| Administrer win02 depuis win01 avec `alx-org` | Non : un compte admin du domaine ne touche jamais un poste utilisateur (modèle en tiers). `alx-org` ne peut d'ailleurs se connecter que sur win01 et ad01 |

Commandes de diagnostic : [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#win01-poste-admin-et-win02-poste-utilisateur).
