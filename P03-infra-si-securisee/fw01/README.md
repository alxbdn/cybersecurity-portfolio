# fw01 · Routeur et pare-feu

Ubuntu Server + nftables. Passerelle (`.254`) de toutes les zones : tout ce qui passe d'une zone à l'autre traverse fw01. Les serveurs n'ont pas de pare-feu local, le filtrage est centralisé ici.

On le déploie en **deux étapes** :

1. **Routage + NAT** ([`nftables-01-null.conf`](config/nftables-01-null.conf)) : tout passe, le temps de monter web01, ad01, win01 et win02.
2. **Filtrage complet** ([`nftables-02-full.conf`](config/nftables-02-full.conf)) : politique `drop` par défaut, seuls les flux utiles passent.

## Cartes réseau

5 cartes. Vérifier la correspondance par MAC (`ip -br link` comparé aux réglages VMware) : l'ordre affiché par VMware n'est pas forcément celui de Linux.

| Carte | VMnet | Zone | IP |
|---|---|---|---|
| ens32 | VMnet8 (NAT) | WAN | `192.168.93.10/24`, passerelle et DNS `192.168.93.2` |
| ens34 | VMnet11 | DMZ | `10.0.10.254/24` |
| ens35 | VMnet12 | Serveurs | `10.0.20.254/24` |
| ens36 | VMnet13 | Admin | `10.0.30.254/24` |
| ens37 | VMnet14 | Users | `10.0.40.254/24` |

L'IP WAN est fixe et hors de la plage DHCP de VMware (`.128`–`.254`) : la redirection de port VMware (HTTPS vers web01) pointe dessus.

## 1. Base

```bash
sudo hostnamectl set-hostname fw01
echo 'preserve_hostname: true' | sudo tee /etc/cloud/cloud.cfg.d/99-hostname.cfg
# Clone du template : nouvelles clés d'hôte SSH
sudo rm /etc/ssh/ssh_host_* && sudo dpkg-reconfigure openssh-server
# IPv6 coupé (non utilisé dans le lab) : ajouter ipv6.disable=1 à GRUB_CMDLINE_LINUX_DEFAULT
sudo nano /etc/default/grub && sudo update-grub
```

## 2. Réseau

```bash
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
sudo mkdir -p /root/netplan.bak && sudo mv /etc/netplan/*.yaml /root/netplan.bak/
sudo tee /etc/netplan/01-fw01.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    ens32:
      dhcp4: false
      addresses: [192.168.93.10/24]
      routes:
        - to: default
          via: 192.168.93.2
      nameservers:
        addresses: [192.168.93.2]
    ens34: {dhcp4: false, addresses: [10.0.10.254/24]}
    ens35: {dhcp4: false, addresses: [10.0.20.254/24]}
    ens36: {dhcp4: false, addresses: [10.0.30.254/24]}
    ens37: {dhcp4: false, addresses: [10.0.40.254/24]}
EOF
sudo chmod 600 /etc/netplan/01-fw01.yaml
sudo netplan apply
sudo reboot
```

✅ `ip -br a` → 5 cartes UP · `cat /proc/cmdline` contient `ipv6.disable=1` · `curl -sI https://example.com` répond.

## 3. Accès SSH d'administration

Script [`fwadmin.sh`](scripts/fwadmin.sh), en 3 phases vérifiées :

1. compte `fwadmin` dans les groupes `sudo` (mot de passe demandé au lancement, il ne sert qu'à sudo) et `adm` (lecture des journaux sans sudo) ;
2. clé publique ECDSA P-256 dédiée à fw01 dans `authorized_keys` ;
3. `sshd` durci : clé uniquement, root interdit, `AllowUsers fwadmin`, pas de X11 ni d'agent (`AllowTcpForwarding local` garde VS Code Remote-SSH).

```bash
# Depuis le PC (zone Admin), AVANT le script : après lui, setup n'a plus accès en SSH
scp fwadmin.sh setup@10.0.30.254:~
# Sur fw01
sudo install -m 700 ~/fwadmin.sh /usr/local/sbin/ && rm ~/fwadmin.sh
sudo fwadmin.sh
```

**Garder la session ouverte**, tester `ssh fw01` dans une 2e fenêtre, puis seulement supprimer `setup` : `sudo deluser --remove-home setup`. Côté poste admin, `win01-admin-tools.ps1 -SSHKey` ([win0x](../win0x/README.md)) génère la clé `fwadmin-win01` et écrit un `~/.ssh/config` durci (algorithmes modernes, pas de transfert d'agent) : sa clé publique est à ajouter dans `~fwadmin/.ssh/authorized_keys`.

**Filtrage réseau du SSH : nftables.** sshd ne regarde que le compte et la clé ; c'est la chaîne `input` de [`nftables-02-full.conf`](config/nftables-02-full.conf) qui n'accepte le port 22 que depuis la zone Admin.

## 4. Le script d'application

Les deux étapes passent par le même script, [`fw01-nft-apply.sh`](scripts/fw01-nft-apply.sh), qui fonctionne comme `netplan try` :

| Phase | Ce qu'il fait |
|---|---|
| 1. Vérification | `nft -c` sur la politique, avant de toucher à quoi que ce soit |
| 2. Noyau | `/etc/sysctl.d/90-fw01.conf` : routage, anti-usurpation strict (`rp_filter = 1`), pas de redirections ICMP ni de routage par la source, paquets martiens journalisés |
| 3. Journaux | `/etc/rsyslog.d/10-fw01-nftables.conf` range les lignes `fw01-*` dans `/var/log/fw01-nftables.log`, `/etc/logrotate.d/fw01-nftables` les garde 90 jours |
| 4. Sauvegarde | politique en cours + copie de `/etc/nftables.conf` |
| 5. Application | charge la nouvelle politique et programme un retour arrière dans 120 s (timer systemd, qui joue même si la session SSH est coupée) |
| 6. Validation | si on tape `ok` après avoir testé depuis une 2e fenêtre : retour arrière annulé, `/etc/nftables.conf` installé, nftables actif au démarrage |

Une règle qui coupe l'accès à fw01 ne peut donc pas bloquer l'admin : 2 minutes plus tard, l'ancienne politique revient.

Sans argument, il propose un menu : **1** = `nftables-01-null.conf`, **2** = `nftables-02-full.conf`, cherchés dans le dossier perso de l'admin. Les fichiers sysctl, rsyslog et logrotate sont générés par le script : il n'y a rien d'autre à copier.

```bash
# Depuis le PC : copier le script et les deux politiques
scp fw01-nft-apply.sh nftables-01-null.conf nftables-02-full.conf fw01:~
# Sur fw01
sudo install -m 700 ~/fw01-nft-apply.sh /usr/local/sbin/
```

## 5. Étape 1 : routage + NAT

```bash
sudo fw01-nft-apply.sh      # choix 1 : nftables-01-null.conf
```

Pas de filtrage, mais chaque nouvelle connexion qui traverse fw01 est tracée (`fw01-fwd-new`) : on voit déjà quels flux existent avant d'écrire la matrice.

✅ `sysctl net.ipv4.ip_forward` → `1` · depuis web01 : `ping 10.0.10.254` puis `curl -sI https://example.com` répondent · `sudo tail -f /var/log/fw01-nftables.log` montre les passages.

À ce stade, toutes les zones se voient et sortent sur Internet. C'est voulu pendant le montage, **pas** pour la recette. Snapshot **fw01 routage OK**.

## 6. Étape 2 : filtrage complet

Une fois web01, ad01, win01 et win02 en place :

```bash
sudo fw01-nft-apply.sh      # choix 2 : nftables-02-full.conf
```

La matrice de flux appliquée :

| Depuis → Vers | Autorisé | Pourquoi |
|---|---|---|
| Internet → web01 | 443 (DNAT) | Le site public |
| web01 → Internet | DNS, NTP, 80/443 | apt, renouvellement du certificat |
| Admin → web01 | 22, 443 | Administration par clé depuis win01 uniquement |
| Admin + Users → ad01 | DNS, Kerberos, NTP, RPC, LDAP(S), SMB, catalogue global | Ce qu'un membre du domaine doit joindre |
| Admin → ad01 | 3389, 5985, 9389 | RDP, WinRM, RSAT : l'administration du DC reste dans la zone Admin |
| ad01 → Internet | DNS, NTP, 80/443 | Redirecteurs DNS, heure, Windows Update |
| Users → Internet | 80, 443 | Navigation web, le DNS passe par ad01 |
| Users → web01 | 443 | Le site de l'entreprise |
| Admin → Users | 3389, 5985, ping | Support des postes utilisateurs |
| Admin → fw01 | 22 | Administration de fw01 (journalisée `fw01-ssh-in`) |
| **Tout le reste** | **refusé et journalisé** | DMZ → Serveurs, Users → Admin, Users → ports d'admin d'ad01, DNS direct… |

✅ Depuis win02 : `Test-NetConnection ad01 -Port 389` OK, `-Port 5985` échoue. Depuis win01 : `ssh web01` OK. Sur fw01 : `grep fw01-fwd-drop /var/log/fw01-nftables.log` montre les refus.

## Erreurs à éviter

| Piège | Ce qu'il faut faire |
|---|---|
| fw01 ne route rien | `ip_forward` vaut 0 : relancer `fw01-nft-apply.sh`, il réécrit `90-fw01.conf` et le vérifie |
| Cartes inversées (DMZ sur l'IP Serveurs…) | Toujours faire la correspondance par MAC avant d'écrire le Netplan |
| Clone : `Cannot find unique matching interface` | Le Netplan du template vise l'ancienne MAC : le déplacer dans `/root/` (fait ci-dessus) |
| Pas de DNS vers 1.1.1.1 depuis le lab | Le VPN de l'hôte bloque le DNS direct : utiliser le proxy DNS VMware `192.168.93.2` |
| Se couper l'accès SSH | Lancer `fwadmin.sh` depuis la zone Admin, garder la session ouverte, tester dans une 2e fenêtre avant de supprimer `setup`. Secours : console VMware |
| Une règle cassée coupe tout le réseau | Passer par `fw01-nft-apply.sh` (retour arrière automatique) plutôt que `cp` + `reload`, et garder la console VMware ouverte |
| Rester sur l'étape 1 « parce que ça marche » | Un fw01 ouvert contredit la politique `drop` par défaut : passer à l'étape 2 avant la recette |
| Un flux légitime est bloqué | `tail -f /var/log/fw01-nftables.log \| grep fw01-fwd-drop` donne SRC, DST et DPT : c'est la règle à ajouter, ou le flux à ne pas autoriser |

Commandes de diagnostic : [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#fw01-ubuntu-nftables).
