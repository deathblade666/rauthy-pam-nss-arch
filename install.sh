#!/bin/bash

set -euo pipefail

ROOT="$(dirname "$(realpath "$0")")"

# --- Helper Overrides ---
chmod() { /usr/bin/chmod "$@"; }
command() {
  if /usr/bin/test -f /usr/bin/"$1"; then return 0;
  elif /usr/bin/test -f /usr/sbin/"$1"; then return 0;
  else return 1; fi
}
cp() { /usr/bin/cp "$@"; }
mkdir() { /usr/bin/mkdir -p "$@"; }
mv() { /usr/bin/mv "$@"; }
sed() { /usr/bin/sed "$@"; }
systemctl() { /usr/bin/systemctl "$@"; }
test() { /usr/bin/test "$@"; }

# --- Distro Detection ---
is_debian() { test -f /usr/bin/apt && return 0 || return 1; }
is_rhel() { test -f /usr/bin/dnf && return 0 || return 1; }
is_arch() { test -f /usr/bin/pacman && return 0 || return 1; }

is_root() {
  if [[ $(id -u) -ne 0 ]]; then
      echo "This script must be executed as root" 1>&2
      exit 100
  fi
}

createConfig () {
  echo "Creating Rauthy configuration..."
  mkdir /etc/rauthy
  chmod 0600 /etc/rauthy
  if test -f /etc/rauthy/rauthy-pam-nss.toml; then
      mv /etc/rauthy/rauthy-pam-nss.toml /etc/rauthy/rauthy-pam-nss.toml.$(date +%s)
  fi

  cp "$ROOT"/rauthy-pam-nss.toml /etc/rauthy/
  chmod 0600 /etc/rauthy/rauthy-pam-nss.toml

  read -p "Rauthy URL (e.g. https://auth.example.com): " URL
  read -p "Rauthy Host ID: " ID
  read -s -p "Rauthy Host Secret: " SECRET; echo

  URL_ESC=$(echo "$URL" | sed -e 's/\//\\\//g')
  sed -i "s/{{ rauthy_url }}/$URL_ESC/g" /etc/rauthy/rauthy-pam-nss.toml
  sed -i "s/{{ rauthy_host_id }}/$ID/g" /etc/rauthy/rauthy-pam-nss.toml
  sed -i "s/{{ rauthy_host_secret }}/$SECRET/g" /etc/rauthy/rauthy-pam-nss.toml

  mkdir /var/lib/pam_rauthy
  cp "$ROOT"/session_scripts/session_* /var/lib/pam_rauthy/
  chmod 700 /var/lib/pam_rauthy/session_*

  if ! test -d /etc/skel_rauthy; then cp -r /etc/skel /etc/skel_rauthy; fi
}

installNSS () {
  echo "Setting up Rauthy NSS..."
  systemctl stop rauthy-nss || true

  ARCH=$(uname -m)
  NSS_BIN="/usr/sbin/rauthy-nss"
  if is_arch; then NSS_BIN="/usr/bin/rauthy-nss"; fi

  # Deploy Binary
  cp "$ROOT"/"$ARCH"/rauthy-nss "$NSS_BIN"
  chmod 755 "$NSS_BIN"

  # Deploy Library
  if is_arch; then
    cp -f "$ROOT"/"$ARCH"/libnss_rauthy.so.2 /usr/lib/libnss_rauthy.so.2
  elif is_rhel; then
    cp -f "$ROOT"/"$ARCH"/libnss_rauthy.so.2 /lib64/libnss_rauthy.so.2
  elif is_debian; then
    cp -f "$ROOT"/"$ARCH"/libnss_rauthy.so.2 /lib/"$ARCH"-linux-gnu/libnss_rauthy.so.2
  fi

  # Deploy & Patch Service
  cp "$ROOT"/rauthy-nss.service /etc/systemd/system/
  if is_arch; then
    sed -i "s|/usr/sbin/rauthy-nss|/usr/bin/rauthy-nss|g" /etc/systemd/system/rauthy-nss.service
  fi

  systemctl daemon-reload
  systemctl enable rauthy-nss --now

  # NSSwitch Config
  if ! test -f /etc/nsswitch.conf.bak; then cp /etc/nsswitch.conf /etc/nsswitch.conf.bak; fi

  if is_arch; then cp "$ROOT"/pam/arch/nsswitch.conf /etc/nsswitch.conf
  elif is_rhel; then cp "$ROOT"/pam/rhel/nsswitch.conf /etc/nsswitch.conf
  elif is_debian; then cp "$ROOT"/pam/debian/nsswitch.conf /etc/nsswitch.conf; fi

  echo "NSS Installation Complete."
}

installPAM () {
  echo "Setting up Rauthy PAM..."
  ARCH=$(uname -m)

  # Deploy PAM module
  if is_arch; then
    cp "$ROOT"/"$ARCH"/pam_rauthy.so /usr/lib/security/pam_rauthy.so
    chmod 755 /usr/lib/security/pam_rauthy.so
  elif is_rhel; then
    cp "$ROOT"/"$ARCH"/pam_rauthy.so /lib64/security/pam_rauthy.so
  elif is_debian; then
    cp "$ROOT"/"$ARCH"/pam_rauthy.so /lib/"$ARCH"-linux-gnu/security/pam_rauthy.so
  fi

  if [[ "${1:-}" == "update" ]]; then return 0; fi

  # PAM Configuration
  if command authselect && ! is_arch; then
    echo "Using authselect (RHEL/Fedora detected)"
    authselect create-profile -b=local rauthy || true
    cp "$ROOT"/pam/rhel/system-auth /etc/authselect/custom/rauthy/
    cp "$ROOT"/pam/rhel/password-auth /etc/authselect/custom/rauthy/
    cp "$ROOT"/pam/rhel/nsswitch.conf /etc/authselect/custom/rauthy/
    echo "Run 'authselect select custom/rauthy' to activate."
  else
    if is_arch; then
      echo "Configuring PAM for Arch Linux..."
      for f in system-auth password-auth; do
        if ! test -f /etc/pam.d/"$f".bak; then cp /etc/pam.d/"$f" /etc/pam.d/"$f".bak; fi
        cp "$ROOT"/pam/arch/"$f" /etc/pam.d/"$f"
      done
    elif is_rhel; then
      for f in system-auth password-auth; do
        cp "$ROOT"/pam/rhel/"$f" /etc/pam.d/"$f"
      done
    elif is_debian; then
      for f in common-auth common-account common-password common-session; do
        if ! test -f /etc/pam.d/"$f".bak; then cp /etc/pam.d/"$f" /etc/pam.d/"$f".bak; fi
        cp "$ROOT"/pam/debian/"$f" /etc/pam.d/"$f"
      done
    fi
  fi

  # Setup authorized keys binary if present
  if test -f "$ROOT"/"$ARCH"/rauthy-authorized-keys; then
    cp "$ROOT"/"$ARCH"/rauthy-authorized-keys /usr/bin/
    chmod 755 /usr/bin/rauthy-authorized-keys
  fi

  echo "PAM Installation Complete."
}

enableSudo() {
  echo "%wheel-rauthy ALL=(ALL) ALL" > /etc/sudoers.d/wheel-rauthy
  chmod 440 /etc/sudoers.d/wheel-rauthy
  chown root:root /etc/sudoers.d/wheel-rauthy
}

# --- Execution ---
is_root

case "${1:-}" in
  nss)
    createConfig
    installNSS
    enableSudo
    ;;
  pam)
    installPAM
    ;;
  update)
    installNSS
    installPAM update
    ;;
  *)
    echo "Usage: $0 {nss|pam|update}"
    exit 1
    ;;
esac
