# Tuto : déployer web01 avec webadmin.sh

> Résumé : réseau → SSH en `setup` → copie du script → lancement → tests → snapshot.
> Le script est le **verrou final** : après lui, seul `webadmin` passe en SSH, et uniquement par clé. Le filtrage par IP (zone Admin) est fait par fw01.

## 0. Avant de commencer (sur le PC)

| Quoi | Où |
|---|---|
| Script de test (certificat de test) | `webadmin-test.sh` : copie de [`webadmin.sh`](../scripts/webadmin.sh) avec `ACME_SERVER=letsencrypt_test` |
| Script final (vrai certificat) | [`webadmin.sh`](../scripts/webadmin.sh) |
| Clé privée SSH | `C:\Users\alxbdn\.ssh\webadmin` (ne bouge jamais d'ici) |
| Token DuckDNS | gestionnaire de mots de passe (jamais dans un fichier) |

## 1. Réseau (seulement si la VM n'a pas encore son IP)

Pas de copier-coller dans la console VMware (Ubuntu Server = pas d'interface graphique).
Astuce : une IP temporaire tapée à la main, puis tout le reste en SSH depuis le PC.

**Console VMware** (en `setup`) :

```bash
ip -br a                                   # nom de la carte DMZ (ens32 ou ens34 selon les cartes présentes)
sudo ip addr add 10.0.10.10/24 dev ens32   # IP temporaire, disparaît au reboot
```

**Depuis le PC** : `ssh setup@10.0.10.10`, puis :

```bash
echo 'network: {config: disabled}' | sudo tee /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
sudo mkdir -p /root/netplan.bak && sudo mv /etc/netplan/*.yaml /root/netplan.bak/
sudo tee /etc/netplan/01-web01.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    ens32:
      dhcp4: false
      link-local: []          # pas d'IPv6 link-local
      addresses: [10.0.10.10/24]
      routes:
        - to: default
          via: 10.0.10.254
      nameservers:
        addresses: [192.168.93.2]   # proxy DNS VMware (1.1.1.1 bloqué par NordVPN sur l'hôte)
EOF
sudo chmod 600 /etc/netplan/01-web01.yaml
sudo netplan apply
```

> ⚠️ `{config: disabled}` : l'espace après les `:` est obligatoire, sinon cloud-init n'est pas désactivé.
> ⚠️ `sudo cat > fichier` ne marche pas (la redirection n'est pas root) : utiliser `sudo tee`.

✅ Vérif : `ip -br a` → `10.0.10.10/24` UP ; `ip route` → `default via 10.0.10.254`.

> **Pourquoi un DNS externe et pas celui de l'AD (10.0.20.10) ?**
> web01 est en DMZ : c'est la machine la plus exposée, donc la plus susceptible d'être compromise. Lui faire utiliser le DNS de l'AD obligerait à ouvrir un flux **DMZ → Serveurs** vers ad01, c'est-à-dire un accès direct au contrôleur de domaine depuis la zone la moins sûre. Or web01 n'en a aucun besoin : il n'est pas membre du domaine `p03.lan` et ne résout que des noms publics (Let's Encrypt, DuckDNS, dépôts apt).
> → web01 garde un résolveur externe, joint via fw01 en NAT. Matrice de flux : DMZ → WAN autorisé (DNS, HTTPS), **DMZ → Serveurs interdit**. Principe de cloisonnement entre zones de confiance (ANSSI, guide d'administration sécurisée v3.0, R16).

> Sans la carte NAT, web01 sort sur Internet **via fw01** (route, NAT, ports 53/123/80/443).
> Tant que fw01 n'est pas prêt, `webadmin.sh` ne pourra pas faire apt ni le certificat.

## 2. Connexion SSH depuis le PC (PowerShell)

```powershell
ssh setup@10.0.10.10
```

> ⚠️ Si tu vois `REMOTE HOST IDENTIFICATION HAS CHANGED` (après un rollback ou une réinstall), c'est normal :
> `ssh-keygen -R 10.0.10.10` puis reconnecte-toi.

## 3. Copier le script sur la VM (PowerShell, 2e fenêtre)

```powershell
scp webadmin-test.sh setup@10.0.10.10:~
```

> À faire **avant** de lancer le script : après lui, `setup` n'a plus accès en SSH, donc plus de scp non plus.

## 4. L'installer au chemin standard (sur la VM)

```bash
sudo install -m 700 ~/webadmin-test.sh /usr/local/sbin/
rm ~/webadmin-test.sh
```

`install -m 700` : copie + propriétaire root + exécutable par root seulement.

## 5. Lancer le script

```bash
tmux                      # optionnel : le script continue même si le SSH saute
sudo webadmin-test.sh
```

1. Mot de passe sudo de `setup`
2. `Token DuckDNS :` → colle le token (rien ne s'affiche, c'est normal), Entrée
3. Il déroule les 6 phases. La phase 6 (certificat) prend ~1 min.

Résultat attendu : 6 phases en ✓ puis `web01 prêt.`

## 6. Tests de preuve (PC, **2e terminal**, garde le 1er ouvert)

| # | Commande | Attendu |
|---|---|---|
| 1 | `ssh -i $HOME\.ssh\webadmin webadmin@10.0.10.10` | connexion OK |
| 2 | `ssh setup@10.0.10.10` | `Permission denied (publickey)` |
| 3 | `curl.exe -I https://alxbdn.duckdns.org` | `Server: Apache` (sans version) + `Strict-Transport-Security` |
| 4 | en webadmin : `mkdir /var/www/html/test`, puis ouvrir `https://alxbdn.duckdns.org/test/` | `403 Forbidden` |

> Avec le **script de test**, le certificat n'est pas reconnu : Chrome bloque (HSTS).
> Utilise `curl.exe -kI ...` ou tape `thisisunsafe` sur la page d'erreur.

📸 Une capture par test, puis **snapshot "web01 OK"**.

## 7. Version finale

Même procédure, avec `webadmin.sh` au lieu de `webadmin-test.sh` (seule différence : le vrai certificat Let's Encrypt), et les étapes 2 à 6 faites **depuis le poste admin**.
La clé privée doit alors être sur le poste admin (même clé, déplacée).

## Dépannage

| Problème | Solution |
|---|---|
| Une phase affiche ✗ | `sudo less /var/log/webadmin.log`, corrige, relance : le script est idempotent |
| Plus d'accès SSH | Console VMware en `setup` (accès hors bande) |
| Quota Let's Encrypt atteint | Attendre 7 jours, ou utiliser `webadmin-test.sh` |
| `Token vide.` | Tu as fait Entrée sans coller le token |
