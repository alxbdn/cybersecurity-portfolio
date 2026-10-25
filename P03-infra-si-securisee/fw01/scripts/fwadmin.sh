#!/usr/bin/env bash
# =============================================================================
# fwadmin.sh - SSH admin access to fw01 (Ubuntu Server, P03 firewall)
# fwadmin account, ECDSA key only. Network restriction (Admin zone only): nftables (fw01-nft-apply.sh)
#
# Usage   : sudo fwadmin.sh   (installed in /usr/local/sbin, asks for fwadmin's sudo password on first run only)
# Needs   : Netplan in place (ens36 = 10.0.30.254), VMware console open as a fallback.
# Idempotent. Full log: /var/log/fwadmin.log
# =============================================================================
set -euo pipefail

FW_USER="fwadmin"
# Admin public key dedicated to fw01 (not a secret)
# ECDSA P-256: ANSSI OpenSSH R9 (ECDSA >= 256 bits), R10 (ECDSA over RSA)
PUBKEY="ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBOpoSMG2ltwby47iRZQqyTX1hEy3FkuRKZgDonjxoMhMbnFl3W6y/0RI4XiuUa6UU/IWYd10qHVLMzBCY32HIUk= fwadmin"
LOG="/var/log/fwadmin.log"

# --- Display -----------------------------------------------------------------
G=$'\e[32m'; R=$'\e[31m'; B=$'\e[1m'; N=$'\e[0m'

phase() { printf '\n%s[%s/3] %s%s\n' "$B" "$1" "$2" "$N"; }

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

# check "label" command... : check (5 tries, time for a service to reload)
retry() { for _ in 1 2 3 4 5; do "$@" && return 0; sleep 1; done; return 1; }
check() { step "check: $1" retry "${@:2}"; }

# --- Prerequisites -------------------------------------------------------------
[[ $EUID -eq 0 ]]               || { echo "Run this script with sudo." >&2; exit 1; }
# fwadmin password: only used for sudo (SSH stays key only).
# Hidden input (-s), never written in the script or the shell history.
# Only asked when the account is created: re-running the script keeps the password.
FW_PASS=""
if ! id "$FW_USER" &>/dev/null; then
  read -rsp "sudo password for ${FW_USER}: " FW_PASS; echo
  read -rsp "Confirm: " FW_PASS2; echo
  [[ -n "$FW_PASS" && "$FW_PASS" == "$FW_PASS2" ]] || { echo "Empty or different passwords." >&2; exit 1; }
  unset FW_PASS2
fi
: >"$LOG"; chmod 600 "$LOG"
echo "${B}fwadmin.sh${N} - fw01 - SSH: ${FW_USER} by key only"

# =============================================================================
# 1. fwadmin user (sudo: nft, netplan, sysctl are root actions)
#    ANSSI GNU/Linux guide: dedicated accounts, sudo rather than direct root
#    adm group: read-only access to the logs (/var/log/fw01-nftables.log) without sudo
# =============================================================================
create_user() {
  id "$FW_USER" &>/dev/null || adduser --disabled-password --gecos "Firewall administrator" "$FW_USER"
  usermod -aG sudo,adm "$FW_USER"
  [[ -z "$FW_PASS" ]] || echo "${FW_USER}:${FW_PASS}" | chpasswd
}

phase 1 "User ${FW_USER}"
step  "Create ${FW_USER}, add to sudo and adm"   create_user
unset FW_PASS
check "${FW_USER} in sudo group"              bash -c "id -nG $FW_USER | grep -qw sudo"
check "${FW_USER} in adm group (log reading)"  bash -c "id -nG $FW_USER | grep -qw adm"

# =============================================================================
# 2. Public key
# =============================================================================
install_key() {
  install -d -m 700 -o "$FW_USER" -g "$FW_USER" "/home/${FW_USER}/.ssh"
  echo "$PUBKEY" >"/home/${FW_USER}/.ssh/authorized_keys"
  chown "${FW_USER}:${FW_USER}" "/home/${FW_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${FW_USER}/.ssh/authorized_keys"
}

phase 2 "Public key"
step  "authorized_keys for ${FW_USER}"          install_key
check "authorized_keys 600 ${FW_USER}" \
      bash -c "[[ \$(stat -c '%a %U' /home/$FW_USER/.ssh/authorized_keys) == '600 $FW_USER' ]]"

# =============================================================================
# 3. SSH: key only, fwadmin only (the Admin zone restriction is done by nftables)
#    00- file: sshd keeps the first value read, so it wins over 50-cloud-init.conf.
# =============================================================================
harden_ssh() {
  cat >/etc/ssh/sshd_config.d/00-hardening.conf <<EOF
# ANSSI OpenSSH R17: no password, key authentication
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
# ANSSI OpenSSH R21: no direct root login
PermitRootLogin no
# ANSSI OpenSSH R22: access limited to the users that need it (network source filtered by nftables)
AllowUsers ${FW_USER}
MaxAuthTries 3
LoginGraceTime 30
# No useless forwarding on a firewall (X11, agent, remote tunnels)
# AllowTcpForwarding local: keeps VS Code Remote-SSH working
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
PermitTunnel no
# Drop dead sessions (10 min)
ClientAliveInterval 300
ClientAliveCountMax 2
EOF
  sshd -t
  systemctl restart ssh
}

phase 3 "SSH"
step  "sshd_config.d/00-hardening.conf"        harden_ssh
check "passwords refused, AllowUsers ${FW_USER}" \
      bash -c "sshd -T | grep -qx 'passwordauthentication no' && sshd -T | grep -qx 'allowusers ${FW_USER}'"
check "root refused"                            bash -c "sshd -T | grep -qx 'permitrootlogin no'"

echo -e "\n${G}${B}fw01: SSH access hardened.${N} Log: ${LOG}"
echo "  1. DO NOT close this session. Test in a 2nd window: ssh fw01"
echo "  2. If it works, from the fwadmin session: sudo deluser --remove-home setup"
