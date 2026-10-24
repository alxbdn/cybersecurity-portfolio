#!/usr/bin/env bash
# =============================================================================
# webadmin.sh - Déploiement et durcissement de web01 (Ubuntu Server + Apache2)
# DMZ 10.0.10.0/24
#
# Usage     : sudo webadmin.sh   (installé dans /usr/local/sbin, token DuckDNS demandé au lancement)
# Prérequis : réseau configuré, accès Internet sortant.
# Idempotent. Journal détaillé : /var/log/webadmin.log
# =============================================================================
set -euo pipefail

WEB_USER="webadmin"
WEB_GROUP="www-data"
DOCROOT="/var/www/html"
# Clé publique de webadmin (une clé publique n'est pas un secret)
# ECDSA P-256 : ANSSI NT OpenSSH R9 (ECDSA >= 256 bits), R10 (ECDSA préféré à RSA)
PUBKEY="ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBA1/fO+7Jfv+vbFqQnirV88JzUlBJ6lQRda5zt6mwWuFPeEBSOg8bShKTaRfDUs9XVXrQjrMv+N7AOMTazDjYAo= webadmin"
SERVER_NAME="alxbdn.duckdns.org"
ACME_EMAIL="admin@example.com"             # remplacé dans la version publique
ACME_SERVER="letsencrypt"              # letsencrypt_test pendant les essais (quota : 5 certifs/semaine)
ACME="/root/.acme.sh/acme.sh"
LOG="/var/log/webadmin.log"
export DEBIAN_FRONTEND=noninteractive   # apt sans questions : sinon une question invisible (sortie
                                       # envoyée dans le journal) bloquerait le script

# --- Affichage ---------------------------------------------------------------
G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'

phase() { printf '\n%s[%s/6] %s%s\n' "$B" "$1" "$2" "$N"; }

# step "libellé" commande... : exécute en arrière-plan avec spinner, sortie dans $LOG
step() {
  local label=$1; shift
  echo "### $label" >>"$LOG"
  "$@" >>"$LOG" 2>&1 &
  local pid=$! i=0 spin='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s %s' "${spin:i++%4:1}" "$label"; sleep 0.1
  done
  if wait "$pid"; then
    printf '\r  %s✓%s %s\n' "$G" "$N" "$label"
  else
    printf '\r  %s✗%s %s\n\n' "$R" "$N" "$label"
    tail -n 15 "$LOG"; echo -e "\nJournal complet : $LOG"; exit 1
  fi
}

# check "libellé" commande... : vérification (5 essais, le temps qu'un service recharge)
retry() { for _ in 1 2 3 4 5; do "$@" && return 0; sleep 1; done; return 1; }
check() { step "vérif : $1" retry "${@:2}"; }

# --- Prérequis ---------------------------------------------------------------
[[ $EUID -eq 0 ]]               || { echo "Lance ce script avec sudo." >&2; exit 1; }
# Token DuckDNS : saisi masqué (-s), jamais écrit dans le script ni dans l'historique.
# acme.sh le lit dans l'environnement, puis le garde dans /root/.acme.sh/account.conf (renouvellements).
read -rsp "Token DuckDNS : " DuckDNS_Token; echo
[[ -n "$DuckDNS_Token" ]]       || { echo "Token vide." >&2; exit 1; }
export DuckDNS_Token
: >"$LOG"; chmod 600 "$LOG"
echo "${B}webadmin.sh${N} - ${SERVER_NAME} - SSH : ${WEB_USER} par clé - CA : ${ACME_SERVER}"

# =============================================================================
# 1. Apache2
# =============================================================================
install_apache() {
  apt-get update -q
  apt-get install -y -q apache2 acl curl   # acl : setfacl (phase 3), curl : vérifs + acme.sh
  systemctl enable --now apache2
  echo "ServerName ${SERVER_NAME}" >/etc/apache2/conf-available/servername.conf
  a2enconf -q servername
}

phase 1 "Apache2"
step  "Installation d'Apache2 et des outils"   install_apache
check "Apache actif"                           systemctl is-active --quiet apache2

# =============================================================================
# 2. Utilisateur webadmin (pas de sudo : admin système par la console, hors bande)
# =============================================================================
create_user() {
  id "$WEB_USER" &>/dev/null || adduser --disabled-password --gecos "Administrateur web" "$WEB_USER"
  usermod -aG "$WEB_GROUP" "$WEB_USER"
}

phase 2 "Utilisateur ${WEB_USER}"
step  "Création de ${WEB_USER}, ajout à ${WEB_GROUP}"   create_user
check "${WEB_USER} membre de ${WEB_GROUP}"              bash -c "id -nG $WEB_USER | grep -qw $WEB_GROUP"

# =============================================================================
# 3. Droits (moindre privilège)
#    DocumentRoot : webadmin rw, www-data r (setgid : héritage du groupe)
#    Logs Apache  : www-data rw sans exécution (ACL)
#    /etc/apache2 : root seul en écriture
# =============================================================================
set_perms() {
  chown -R "${WEB_USER}:${WEB_GROUP}" "$DOCROOT"
  find "$DOCROOT" -type d -exec chmod 2750 {} +
  find "$DOCROOT" -type f -exec chmod 0640 {} +

  setfacl -R -m u:"${WEB_GROUP}":rwX /var/log/apache2   # existant : rw, X = traverser les dossiers seulement
  setfacl -d -m u:"${WEB_GROUP}":rw  /var/log/apache2   # défaut : hérité par les futurs fichiers de logs

  chown -R root:root /etc/apache2
  find /etc/apache2 -type d -exec chmod 755 {} +
  find /etc/apache2 -type f -exec chmod 644 {} +
}

phase 3 "Droits"
step  "DocumentRoot, logs, configuration"      set_perms
check "${DOCROOT} en 2750 ${WEB_USER}:${WEB_GROUP}" \
      bash -c "[[ \$(stat -c '%a %U:%G' $DOCROOT) == '2750 ${WEB_USER}:${WEB_GROUP}' ]]"

# =============================================================================
# 4. Durcissement Apache : version masquée, pas de listing, pas de TRACE
# =============================================================================
harden_apache() {
  cat >/etc/apache2/conf-available/hardening.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off

<Directory /var/www/>
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOF
  a2disconf -q security                 # security.conf (ServerTokens OS) est lu après et écraserait le nôtre
  a2enconf -q hardening
  apache2ctl configtest
  systemctl reload apache2
}

phase 4 "Durcissement Apache"
step  "hardening.conf (ServerTokens, -Indexes, TRACE)"   harden_apache
check "en-tête 'Server: Apache' sans version" \
      bash -c "curl -sI http://127.0.0.1 | grep -qx $'Server: Apache\r'"

# =============================================================================
# 5. SSH : clé uniquement, webadmin seul
#    Le filtrage par IP source (zone Admin uniquement) est fait par fw01
#    Fichier 00- : sshd garde la 1re valeur lue, donc il passe avant 50-cloud-init.conf.
# =============================================================================
harden_ssh() {
  # Clés autorisées : /home/webadmin/.ssh/authorized_keys (équivalent du .ssh Windows)
  install -d -m 700 -o "$WEB_USER" -g "$WEB_USER" "/home/${WEB_USER}/.ssh"
  echo "$PUBKEY" >"/home/${WEB_USER}/.ssh/authorized_keys"
  chown "${WEB_USER}:${WEB_USER}" "/home/${WEB_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${WEB_USER}/.ssh/authorized_keys"
  cat >/etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# ANSSI NT OpenSSH R17 : pas de mot de passe, authentification par clé
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
# ANSSI NT OpenSSH R21 : pas de connexion directe en root
PermitRootLogin no
# ANSSI NT OpenSSH R22 : accès restreint aux seuls utilisateurs qui en ont besoin
AllowUsers ${WEB_USER}
MaxAuthTries 3
LoginGraceTime 30
EOF
  sshd -t
  systemctl restart ssh
}

phase 5 "SSH"
step  "Clé publique + sshd_config.d/00-hardening.conf"   harden_ssh
check "mots de passe refusés, AllowUsers ${WEB_USER}" \
      bash -c "sshd -T | grep -qx 'passwordauthentication no' && sshd -T | grep -qx 'allowusers ${WEB_USER}'"

# =============================================================================
# 6. HTTPS : Let's Encrypt (DNS-01 via DuckDNS, acme.sh, ECDSA P-256) + TLS 1.2/1.3
# =============================================================================
install_acme() {
  [[ -x "$ACME" ]] && return 0
  curl -fsSL https://get.acme.sh -o /tmp/get-acme.sh
  HOME=/root sh /tmp/get-acme.sh email="$ACME_EMAIL"
  rm -f /tmp/get-acme.sh
}

issue_cert() {
  local rc=0
  # ec-256 : ANSSI guide de sélection crypto R21 (EC-DSA recommandé)
  "$ACME" --issue --dns dns_duckdns -d "$SERVER_NAME" --keylength ec-256 \
          --server "$ACME_SERVER" --dnssleep 60 || rc=$?
  [[ $rc -eq 0 || $rc -eq 2 ]]      # 2 = certificat encore valide, rien à faire
}

install_cert() {
  "$ACME" --install-cert -d "$SERVER_NAME" --ecc \
          --key-file       "/etc/ssl/private/${SERVER_NAME}.key" \
          --fullchain-file "/etc/ssl/certs/${SERVER_NAME}.fullchain.pem" \
          --reloadcmd      "systemctl reload apache2"
  chmod 600 "/etc/ssl/private/${SERVER_NAME}.key"
}

enable_https() {
  # ANSSI guide TLS : TLS 1.2 minimum, suites ECDHE (confidentialité persistante) + AEAD
  cat >/etc/apache2/conf-available/tls-hardening.conf <<'EOF'
SSLProtocol -all +TLSv1.2 +TLSv1.3
SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305
SSLHonorCipherOrder off
SSLSessionTickets off
EOF
  cat >/etc/apache2/sites-available/alxbdn-ssl.conf <<EOF
<VirtualHost *:443>
    ServerName ${SERVER_NAME}
    DocumentRoot ${DOCROOT}

    SSLEngine on
    SSLCertificateFile    /etc/ssl/certs/${SERVER_NAME}.fullchain.pem
    SSLCertificateKeyFile /etc/ssl/private/${SERVER_NAME}.key

    Header always set Strict-Transport-Security "max-age=63072000"

    ErrorLog \${APACHE_LOG_DIR}/${SERVER_NAME}-error.log
    CustomLog \${APACHE_LOG_DIR}/${SERVER_NAME}-access.log combined
</VirtualHost>
EOF
  a2enmod -q ssl headers
  a2enconf -q tls-hardening
  a2ensite -q alxbdn-ssl
  apache2ctl configtest
  systemctl daemon-reload
  systemctl restart apache2
}

phase 6 "HTTPS"
step  "Installation d'acme.sh"                              install_acme
step  "Certificat ${SERVER_NAME} (DNS-01, ~1 min)"          issue_cert
step  "Installation du certificat + renouvellement auto"    install_cert
step  "TLS 1.2/1.3 + VirtualHost 443"                       enable_https
check "HTTPS répond avec HSTS" \
      bash -c "curl -skI --resolve ${SERVER_NAME}:443:127.0.0.1 https://${SERVER_NAME} | grep -qi '^strict-transport-security'"

echo -e "\n${G}${B}web01 prêt.${N} https://${SERVER_NAME} - journal : ${LOG}"
