# web01 · Serveur web (DMZ)

Ubuntu Server + Apache, seul serveur exposé sur Internet. Déployé et durci par un seul script : [`webadmin.sh`](scripts/webadmin.sh).

| | |
|---|---|
| Zone | DMZ, VMnet11 |
| IP | `10.0.10.10/24`, passerelle `10.0.10.254` (fw01) |
| DNS | `192.168.93.2` (proxy DNS VMware, joint via fw01) |
| Accès admin | `ssh web01` depuis `win01`, compte `webadmin`, clé uniquement |
| Prérequis | [fw01](../fw01/README.md) en étape 1 (routage + NAT) : sans lui, pas d'apt ni de certificat |

## 1. Réseau

Une seule carte, sur VMnet11. Pas de copier-coller dans la console VMware : on pose une IP temporaire, puis on fait le reste en SSH.

**Console VMware** (compte `setup`) :

```bash
ip -br a                                   # nom de la carte (ens32)
sudo ip addr add 10.0.10.10/24 dev ens32   # IP temporaire, perdue au reboot
```

**En SSH** (`ssh setup@10.0.10.10`) : IP fixe avec Netplan.

```bash
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
sudo mkdir -p /root/netplan.bak && sudo mv /etc/netplan/*.yaml /root/netplan.bak/
sudo tee /etc/netplan/01-web01.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    ens32:
      dhcp4: false
      link-local: []
      addresses: [10.0.10.10/24]
      routes:
        - to: default
          via: 10.0.10.254
      nameservers:
        addresses: [192.168.93.2]
EOF
sudo chmod 600 /etc/netplan/01-web01.yaml
sudo netplan apply
```

✅ `ip route` → `default via 10.0.10.254` · `ping -c2 10.0.10.254` répond.

> **Pourquoi pas le DNS de l'AD ?** web01 est la machine la plus exposée. Lui donner `ad01` comme DNS ouvrirait un flux DMZ → Serveurs vers le contrôleur de domaine, alors qu'il n'est pas dans le domaine et ne résout que des noms publics. ANSSI administration sécurisée, R16.

## 2. Déployer

```powershell
# Depuis le PC, AVANT le script (après lui, setup n'a plus accès en SSH, donc plus de scp)
scp webadmin.sh setup@10.0.10.10:~
```

```bash
# Sur web01
sudo install -m 700 ~/webadmin.sh /usr/local/sbin/ && rm ~/webadmin.sh
tmux                 # optionnel : le script continue si le SSH saute
sudo webadmin.sh     # demande le token DuckDNS (saisie masquée)
```

6 phases, chacune vérifiée : Apache · compte `webadmin` · droits · durcissement Apache · SSH par clé · HTTPS Let's Encrypt. Attendu : 6 ✓ puis `web01 ready.` Le script est idempotent : en cas de ✗, on corrige et on relance.

## 3. Vérifier

| Test | Attendu | Preuve |
|---|---|---|
| `ssh web01` depuis `win01` (alx-org) | connexion sans mot de passe | [03](captures/03_ssh-webadmin-cle-OK_mkdir-test.png) |
| `ssh setup@10.0.10.10` | `Permission denied (publickey)` | [02](captures/02_ssh-setup-refuse_curl-Server-Apache-HSTS.png) |
| `curl.exe -I https://alxbdn.duckdns.org` | `Server: Apache` sans version + `Strict-Transport-Security` | [02](captures/02_ssh-setup-refuse_curl-Server-Apache-HSTS.png) |
| `mkdir /var/www/html/test` puis ouvrir `/test/` | `403 Forbidden` | [04](captures/04_directory-listing-desactive-403.png) |
| Certificat dans le navigateur | Let's Encrypt, valide | [05](captures/05_certificat-LetsEncrypt-YE2.png) · [06](captures/06_https-alxbdn-duckdns-org.png) |

Puis snapshot **web01 OK**.

## Erreurs à éviter

| Piège | Ce qu'il faut faire |
|---|---|
| `{config:disabled}` sans espace | L'espace après `:` est obligatoire, sinon cloud-init réécrit le réseau |
| `sudo cat > fichier` | La redirection n'est pas root : utiliser `sudo tee` |
| Clone du template : `Cannot find unique matching interface` | Le Netplan du template vise l'ancienne MAC : le déplacer dans `/root/` (fait ci-dessus) |
| Clone du template : mêmes clés d'hôte SSH que le template | `sudo rm /etc/ssh/ssh_host_*` puis `sudo dpkg-reconfigure openssh-server` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Normal après une réinstall : `ssh-keygen -R 10.0.10.10` |
| Apache affiche encore sa version | `security.conf` d'Ubuntu écrase `ServerTokens` : le script le désactive ([capture du bug](captures/00_bug_ServerTokens-ecrase-par-security-conf.png)) |
| Relancer en boucle après un échec HTTPS | Quota Let's Encrypt : 5 certificats / semaine. Lire `sudo tail -30 /var/log/webadmin.log` d'abord, tester avec `ACME_SERVER=letsencrypt_test` |
| `curl: (3)` en phase 6 | Token DuckDNS vide ou collé avec un espace : relancer et coller une seule fois |
| `ssh web01` demande un mot de passe | Le durcissement a été perdu (snapshot restauré) : relancer `sudo webadmin.sh` |
| Mises à jour système | `webadmin` n'a pas sudo, c'est voulu : `sudo apt upgrade` depuis la console en `setup` |

Pas-à-pas détaillé (script de test, version finale) : [tuto de déploiement](docs/tuto-deploiement-web01.md).
