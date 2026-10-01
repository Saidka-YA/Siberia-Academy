 
set -Eeuo pipefail

readonly FOXYPROXY_URL="https://addons.mozilla.org/firefox/addon/foxyproxy-standard/"
readonly XSSTRIKE_DIR="/opt/xsstrike"
readonly VOLATILITY_VENV="/opt/volatility3-venv"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

if [[ ${EUID} -ne 0 ]]; then
  die "Run this script as root: sudo bash $0"
fi

if [[ ! -r /etc/os-release ]]; then
  die "Cannot identify the operating system (/etc/os-release is missing)."
fi

 
source /etc/os-release
if [[ ${ID:-} != "ubuntu" ]]; then
  die "This script supports Ubuntu only (detected: ${PRETTY_NAME:-unknown})."
fi

case "$(dpkg --print-architecture)" in
  amd64) BURP_TYPE="Linux" ;;
  arm64) BURP_TYPE="LinuxArm64" ;;
  *) warn "Burp Suite will be skipped: unsupported architecture $(dpkg --print-architecture)."; BURP_TYPE="" ;;
esac

TARGET_USER="${SUDO_USER:-}"
if [[ -z ${TARGET_USER} || ${TARGET_USER} == "root" ]]; then
  TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 { print $1; exit }' /etc/passwd)"
fi
if [[ -z ${TARGET_USER} ]]; then
  warn "No desktop user detected; browser launch and group membership changes will be skipped."
fi

export DEBIAN_FRONTEND=noninteractive

log "Enabling the Ubuntu Universe repository"
apt-get update
apt-get install -y software-properties-common ca-certificates gnupg
add-apt-repository -y universe

log "Installing APT packages"
 
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections
echo "ubridge ubridge/install-setuid boolean true" | debconf-set-selections

APT_PACKAGES=(
  libimage-exiftool-perl
  xxd
  binwalk
  grep
  unzip
  zip
  qpdf
  binutils
  sleuthkit
  testdisk
  wireshark
  tshark
  tcpdump
  traceroute
  curl
  dnsutils
  netcat-openbsd
  iptables
  python3
  python3-pip
  python3-venv
  git
  snapd
  firefox
)

AVAILABLE_APT_PACKAGES=()
for package_name in "${APT_PACKAGES[@]}"; do
  if apt-cache show "${package_name}" >/dev/null 2>&1; then
    AVAILABLE_APT_PACKAGES+=("${package_name}")
  else
    warn "APT package '${package_name}' is unavailable for Ubuntu ${VERSION_ID:-unknown}; skipping it."
  fi
done
apt-get install -y "${AVAILABLE_APT_PACKAGES[@]}"

log "Installing GNS3 from its official Ubuntu PPA"
if add-apt-repository -y ppa:gns3/ppa && apt-get update; then
  if ! apt-get install -y gns3-gui gns3-server; then
    warn "GNS3 installation failed. The GNS3 PPA may not yet support Ubuntu ${VERSION_ID:-unknown}."
  fi
else
  warn "Could not add the GNS3 PPA; GNS3 was not installed."
fi

if [[ -n ${TARGET_USER} ]]; then
  for group_name in wireshark ubridge libvirt kvm; do
    if getent group "${group_name}" >/dev/null; then
      usermod -aG "${group_name}" "${TARGET_USER}"
    fi
  done
fi

log "Installing Volatility 3 with pip in ${VOLATILITY_VENV}"
python3 -m venv "${VOLATILITY_VENV}"
"${VOLATILITY_VENV}/bin/python" -m pip install --upgrade pip
"${VOLATILITY_VENV}/bin/python" -m pip install --upgrade volatility3
ln -sfn "${VOLATILITY_VENV}/bin/vol" /usr/local/bin/vol

log "Installing XSStrike in ${XSSTRIKE_DIR}"
if [[ -d "${XSSTRIKE_DIR}/.git" ]]; then
  if ! git -C "${XSSTRIKE_DIR}" pull --ff-only; then
    warn "XSStrike already exists and could not be fast-forwarded; keeping the current checkout."
  fi
elif [[ -e ${XSSTRIKE_DIR} ]]; then
  warn "${XSSTRIKE_DIR} exists but is not an XSStrike Git checkout; XSStrike was skipped."
else
  git clone --depth 1 https://github.com/s0md3v/XSStrike.git "${XSSTRIKE_DIR}"
fi

if [[ -f "${XSSTRIKE_DIR}/requirements.txt" ]]; then
  python3 -m venv "${XSSTRIKE_DIR}/.venv"
  "${XSSTRIKE_DIR}/.venv/bin/python" -m pip install --upgrade pip
  "${XSSTRIKE_DIR}/.venv/bin/python" -m pip install -r "${XSSTRIKE_DIR}/requirements.txt"
  printf '%s\n' \
    '#!/bin/sh' \
    'exec /opt/xsstrike/.venv/bin/python /opt/xsstrike/xsstrike.py "$@"' \
    > /usr/local/bin/xsstrike
  chmod 0755 /usr/local/bin/xsstrike
fi

log "Installing Postman from the official Snap package"
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now snapd.socket || true
fi
if ! snap install postman; then
  warn "Postman installation failed. Snap requires a running systemd/snapd service."
fi

log "Downloading and silently installing Burp Suite"
if [[ -n ${BURP_TYPE} ]]; then
  BURP_INSTALLER="$(mktemp --suffix=.sh)"
  trap 'rm -f "${BURP_INSTALLER:-}"' EXIT
  BURP_URL="https://portswigger.net/burp/releases/download?product=community&type=${BURP_TYPE}"
  if curl --fail --location --retry 3 --output "${BURP_INSTALLER}" "${BURP_URL}"; then
    chmod 0755 "${BURP_INSTALLER}"
    if ! "${BURP_INSTALLER}" -q -dir /opt/BurpSuite; then
      warn "Burp's silent installer failed. Download it manually from https://portswigger.net/burp/downloads"
    else
      for burp_executable in \
        /opt/BurpSuite/BurpSuite \
        /opt/BurpSuite/BurpSuiteCommunity \
        /opt/BurpSuiteCommunity/BurpSuiteCommunity; do
        if [[ -x ${burp_executable} ]]; then
          ln -sfn "${burp_executable}" /usr/local/bin/burpsuite
          break
        fi
      done
    fi
  else
    warn "Could not download Burp Suite from PortSwigger."
  fi
fi

log "FoxyProxy installation"
if [[ -n ${TARGET_USER} ]] && command -v firefox >/dev/null 2>&1 && [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
   
  sudo -u "${TARGET_USER}" --preserve-env=DISPLAY,WAYLAND_DISPLAY \
    nohup firefox "${FOXYPROXY_URL}" >/dev/null 2>&1 &
  disown || true
  echo "Confirm the FoxyProxy Standard installation in the Firefox window."
else
  echo "Install FoxyProxy Standard in Firefox from: ${FOXYPROXY_URL}"
fi

log "Basic verification"
CHECK_COMMANDS=(
  exiftool xxd binwalk grep unzip zip qpdf strings mmls testdisk
  wireshark tshark tcpdump traceroute curl dig nc iptables python3 pip3
  vol xsstrike gns3 postman burpsuite firefox
)

for command_name in "${CHECK_COMMANDS[@]}"; do
  if command -v "${command_name}" >/dev/null 2>&1; then
    printf '  [OK]      %-12s %s\n' "${command_name}" "$(command -v "${command_name}")"
  else
    printf '  [MISSING] %-12s\n' "${command_name}"
  fi
done

cat <<EOF

Installation finished.

Important:
  * Log out and back in before using Wireshark/GNS3 without root.
  * FoxyProxy requires one confirmation click in Firefox:
    ${FOXYPROXY_URL}
  * XSStrike example (authorized targets only):
    xsstrike -u 'https://your-test-site.example/?q=test'
  * Volatility 3 help:
    vol -h
EOF
