# fw01 · Routeur et pare-feu

Ubuntu Server + nftables. Passerelle (`.254`) de toutes les zones : tout ce qui passe d'une zone à l'autre traverse fw01. Les serveurs n'ont pas de pare-feu local, le filtrage est centralisé ici.

On le déploie en **deux étapes** :

1. **Routage + NAT** ([`nftables-01-routing.conf`](config/nftables-01-routing.conf)) : tout passe, le temps de monter web01, ad01 et les postes.
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

## 3. Étape 1 : routage + NAT

```bash
# Autoriser fw01 à router entre ses cartes
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-fw01.conf
sudo sysctl --system

# NAT seul : copier nftables-01-routing.conf sur fw01, puis
sudo cp nftables-01-routing.conf /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf          # vérifie la syntaxe sans appliquer
sudo systemctl enable --now nftables
sudo systemctl reload nftables
```

✅ `sysctl net.ipv4.ip_forward` → `1` · depuis web01 : `ping 10.0.10.254` puis `curl -sI https://example.com` répondent.

À ce stade, toutes les zones se voient et sortent sur Internet. C'est voulu pendant le montage, **pas** pour la recette. Snapshot **fw01 routage OK**.

## 4. Étape 2 : filtrage complet

Une fois web01, ad01, win01 et win02 en place :

```bash
sudo cp nftables-02-full.conf /etc/nftables.conf
sudo nft -c -f /etc/nftables.conf && sudo systemctl reload nftables
sudo nft list chain inet filter forward
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
| Admin → fw01 | 22 | Administration de fw01 |
| **Tout le reste** | **refusé et journalisé** | DMZ → Serveurs, Users → Admin, Users → Internet… |

✅ Depuis win02 : `Test-NetConnection ad01 -Port 389` OK, `-Port 5985` échoue. Depuis win01 : `ssh web01` OK. Sur fw01 : `sudo journalctl -k | grep fw01-fwd-drop` montre les refus.

## Erreurs à éviter

| Piège | Ce qu'il faut faire |
|---|---|
| fw01 ne route rien | `ip_forward` vaut 0 : le fichier sysctl manque ou `sysctl --system` n'a pas été lancé |
| Cartes inversées (DMZ sur l'IP Serveurs…) | Toujours faire la correspondance par MAC avant d'écrire le Netplan |
| Clone : `Cannot find unique matching interface` | Le Netplan du template vise l'ancienne MAC : le déplacer dans `/root/` (fait ci-dessus) |
| Pas de DNS vers 1.1.1.1 depuis le lab | Le VPN de l'hôte bloque le DNS direct : utiliser le proxy DNS VMware `192.168.93.2` |
| Une règle cassée coupe tout le réseau | Toujours `nft -c -f` avant `reload`, et garder la console VMware ouverte |
| Rester sur l'étape 1 « parce que ça marche » | Un fw01 ouvert contredit la politique `drop` par défaut : passer à l'étape 2 avant la recette |
| Un flux légitime est bloqué | `journalctl -k -f \| grep fw01-fwd-drop` donne SRC, DST et DPT : c'est la règle à ajouter, ou le flux à ne pas autoriser |

Commandes de diagnostic : [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#fw01-ubuntu-nftables).
