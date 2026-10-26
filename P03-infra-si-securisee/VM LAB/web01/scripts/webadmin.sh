#!/usr/bin/env bash
# =============================================================================
# webadmin.sh - Deploy and harden web01 (Ubuntu Server + Apache2), DMZ 10.0.10.0/24
#
# Usage   : sudo webadmin.sh   (installed in /usr/local/sbin, asks for the DuckDNS token)
# Needs   : network configured, outbound Internet access.
# Idempotent. Full log: /var/log/webadmin.log
# =============================================================================
set -euo pipefail

WEB_USER="webadmin"
WEB_GROUP="www-data"
DOCROOT="/var/www/html"
# webadmin public key (not a secret)
# ECDSA P-256: ANSSI OpenSSH R9 (ECDSA >= 256 bits), R10 (ECDSA over RSA)
PUBKEY="ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBA1/fO+7Jfv+vbFqQnirV88JzUlBJ6lQRda5zt6mwWuFPeEBSOg8bShKTaRfDUs9XVXrQjrMv+N7AOMTazDjYAo= webadmin"
SERVER_NAME="alxbdn.duckdns.org"
ACME_EMAIL="admin@example.com"             # replaced in the public version
ACME_SERVER="letsencrypt"              # letsencrypt_test while testing (quota: 5 certs/week)
ACME="/root/.acme.sh/acme.sh"
LOG="/var/log/webadmin.log"
export DEBIAN_FRONTEND=noninteractive   # no apt prompts (output goes to the log, a prompt would hang)

# --- Display -----------------------------------------------------------------
G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'

phase() { printf '\n%s[%s/6] %s%s\n' "$B" "$1" "$2" "$N"; }

# step "label" command... : runs in background with a spinner, output to $LOG
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
    tail -n 15 "$LOG"; echo -e "\nFull log: $LOG"; exit 1
  fi
}

# check "label" command... : verification (5 tries, time for a service to reload)
retry() { for _ in 1 2 3 4 5; do "$@" && return 0; sleep 1; done; return 1; }
check() { step "check: $1" retry "${@:2}"; }

# --- Prerequisites -------------------------------------------------------------
[[ $EUID -eq 0 ]]               || { echo "Run this script with sudo." >&2; exit 1; }
# DuckDNS token: hidden input, never in the script or shell history.
# acme.sh reads it from the environment, then keeps it in /root/.acme.sh/account.conf (renewals).
read -rsp "DuckDNS token: " DuckDNS_Token; echo
[[ -n "$DuckDNS_Token" ]]       || { echo "Empty token." >&2; exit 1; }
export DuckDNS_Token
: >"$LOG"; chmod 600 "$LOG"
echo "${B}webadmin.sh${N} - ${SERVER_NAME} - SSH: ${WEB_USER} by key - CA: ${ACME_SERVER}"

# =============================================================================
# 1. Apache2
# =============================================================================
install_apache() {
  apt-get update -q
  apt-get install -y -q apache2 acl curl   # acl: setfacl (phase 3), curl: checks + acme.sh
  systemctl enable --now apache2
  echo "ServerName ${SERVER_NAME}" >/etc/apache2/conf-available/servername.conf
  a2enconf -q servername
}

phase 1 "Apache2"
step  "Install Apache2 and tools"   install_apache
check "Apache running"              systemctl is-active --quiet apache2

# =============================================================================
# 2. webadmin user (no sudo: system admin goes through the console, out of band)
# =============================================================================
create_user() {
  id "$WEB_USER" &>/dev/null || adduser --disabled-password --gecos "Web admin" "$WEB_USER"
  usermod -aG "$WEB_GROUP" "$WEB_USER"
}

phase 2 "User ${WEB_USER}"
step  "Create ${WEB_USER}, add to ${WEB_GROUP}"   create_user
check "${WEB_USER} member of ${WEB_GROUP}"        bash -c "id -nG $WEB_USER | grep -qw $WEB_GROUP"

# =============================================================================
# 3. Permissions (least privilege)
#    DocumentRoot : webadmin rw, www-data r (setgid: group inherited)
#    Apache logs  : www-data rw, no exec (ACL)
#    /etc/apache2 : root only can write
# =============================================================================
set_perms() {
  chown -R "${WEB_USER}:${WEB_GROUP}" "$DOCROOT"
  find "$DOCROOT" -type d -exec chmod 2750 {} +
  find "$DOCROOT" -type f -exec chmod 0640 {} +

  setfacl -R -m u:"${WEB_GROUP}":rwX /var/log/apache2   # existing: rw, X = traverse dirs only
  setfacl -d -m u:"${WEB_GROUP}":rw  /var/log/apache2   # default: inherited by new log files

  chown -R root:root /etc/apache2
  find /etc/apache2 -type d -exec chmod 755 {} +
  find /etc/apache2 -type f -exec chmod 644 {} +
}

phase 3 "Permissions"
step  "DocumentRoot, logs, configuration"   set_perms
check "${DOCROOT} is 2750 ${WEB_USER}:${WEB_GROUP}" \
      bash -c "[[ \$(stat -c '%a %U:%G' $DOCROOT) == '2750 ${WEB_USER}:${WEB_GROUP}' ]]"

# =============================================================================
# 4. Apache hardening: hide version, no directory listing, no TRACE
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
  a2disconf -q security                 # security.conf (ServerTokens OS) loads after ours and overrides it
  a2enconf -q hardening
  apache2ctl configtest
  systemctl reload apache2
}

phase 4 "Apache hardening"
step  "hardening.conf (ServerTokens, -Indexes, TRACE)"   harden_apache
check "'Server: Apache' header without version" \
      bash -c "curl -sI http://127.0.0.1 | grep -qx $'Server: Apache\r'"

# =============================================================================
# 5. SSH: key only, webadmin only
#    Source IP filtering (Admin zone only) is done by fw01.
#    File 00-: sshd keeps the first value read, so it wins over 50-cloud-init.conf.
# =============================================================================
harden_ssh() {
  install -d -m 700 -o "$WEB_USER" -g "$WEB_USER" "/home/${WEB_USER}/.ssh"
  echo "$PUBKEY" >"/home/${WEB_USER}/.ssh/authorized_keys"
  chown "${WEB_USER}:${WEB_USER}" "/home/${WEB_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${WEB_USER}/.ssh/authorized_keys"
  cat >/etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# ANSSI OpenSSH R17: no passwords, key authentication
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
# ANSSI OpenSSH R21: no direct root login
PermitRootLogin no
# ANSSI OpenSSH R22: only the users who need it
AllowUsers ${WEB_USER}
MaxAuthTries 3
LoginGraceTime 30
EOF
  sshd -t
  systemctl restart ssh
}

phase 5 "SSH"
step  "Public key + sshd_config.d/00-hardening.conf"   harden_ssh
check "passwords refused, AllowUsers ${WEB_USER}" \
      bash -c "sshd -T | grep -qx 'passwordauthentication no' && sshd -T | grep -qx 'allowusers ${WEB_USER}'"

# =============================================================================
# 6. HTTPS: Let's Encrypt (DNS-01 via DuckDNS, acme.sh, ECDSA P-256) + TLS 1.2/1.3
# =============================================================================
install_acme() {
  [[ -x "$ACME" ]] && return 0
  curl -fsSL https://get.acme.sh -o /tmp/get-acme.sh
  HOME=/root sh /tmp/get-acme.sh email="$ACME_EMAIL"
  rm -f /tmp/get-acme.sh
}

issue_cert() {
  local rc=0
  # ec-256: ANSSI crypto guide R21 (EC-DSA recommended)
  "$ACME" --issue --dns dns_duckdns -d "$SERVER_NAME" --keylength ec-256 \
          --server "$ACME_SERVER" --dnssleep 60 || rc=$?
  [[ $rc -eq 0 || $rc -eq 2 ]]      # 2 = certificate still valid, nothing to do
}

install_cert() {
  "$ACME" --install-cert -d "$SERVER_NAME" --ecc \
          --key-file       "/etc/ssl/private/${SERVER_NAME}.key" \
          --fullchain-file "/etc/ssl/certs/${SERVER_NAME}.fullchain.pem" \
          --reloadcmd      "systemctl reload apache2"
  chmod 600 "/etc/ssl/private/${SERVER_NAME}.key"
}

enable_https() {
  # ANSSI TLS guide: TLS 1.2 minimum, ECDHE suites (forward secrecy) + AEAD
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
step  "Install acme.sh"                                   install_acme
step  "Certificate ${SERVER_NAME} (DNS-01, ~1 min)"       issue_cert
step  "Install certificate + auto renewal"                install_cert
step  "TLS 1.2/1.3 + VirtualHost 443"                     enable_https
check "HTTPS answers with HSTS" \
      bash -c "curl -skI --resolve ${SERVER_NAME}:443:127.0.0.1 https://${SERVER_NAME} | grep -qi '^strict-transport-security'"

echo -e "\n${G}${B}web01 ready.${N} https://${SERVER_NAME} - log: ${LOG}"
