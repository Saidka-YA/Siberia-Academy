#!/usr/bin/env bash
set -Eeuo pipefail
# Ubuntu 22.04/24.04/26.04 desktop. Run: sudo bash install-security-toolkit-ubuntu.sh
# Docker runs as root via systemd. Use sudo docker; docker group grants root-level access.
log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || die "Run with sudo: sudo bash $0"
[[ -r /etc/os-release ]] || die 'Missing /etc/os-release'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == ubuntu ]] || die "Ubuntu required"
case "${VERSION_ID:-}" in 22.04|24.04|26.04) ;; *) die "Use Ubuntu 22.04, 24.04 or 26.04";; esac
ARCH="$(dpkg --print-architecture)"
case "$ARCH" in amd64|arm64) ;; *) die "amd64 or arm64 required";; esac
[[ -d /run/systemd/system ]] || die 'systemd is required'
TARGET_USER="${SUDO_USER:-}"
if [[ -z $TARGET_USER || $TARGET_USER == root ]] || ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER="$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)"
fi
[[ -n $TARGET_USER ]] || die 'A regular desktop user is required'
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d $TARGET_HOME ]] || die "Missing home directory: $TARGET_HOME"
export DEBIAN_FRONTEND=noninteractive
APT=(-y -o DPkg::Lock::Timeout=120)

log 'Updating Ubuntu repositories'
apt-get update
apt-get install "${APT[@]}" ca-certificates curl gnupg software-properties-common
add-apt-repository -y universe
apt-get update
echo 'wireshark-common wireshark-common/install-setuid boolean true' | debconf-set-selections
echo 'ubridge ubridge/install-setuid boolean true' | debconf-set-selections
PACKAGES=(libimage-exiftool-perl xxd binwalk grep unzip zip qpdf binutils
  sleuthkit testdisk wireshark tshark tcpdump traceroute dnsutils
  netcat-openbsd iptables python3 python3-pip python3-venv python3-dev
  file tar coreutils htop btop debianutils openssh-client nmap git
  build-essential g++ gdb cmake pkg-config clang clangd clang-format
  clang-tidy cppcheck cron firefox)
for pkg in "${PACKAGES[@]}"; do
  apt-cache show "$pkg" >/dev/null 2>&1 || die "Unavailable package: $pkg"
done
apt-get install "${APT[@]}" "${PACKAGES[@]}"
# base64 and wc = coreutils; which = debianutils; nc = netcat-openbsd; ssh = openssh-client.

log 'Installing Docker Engine from the official repository'
if ! dpkg-query -W -f='${Status}' docker-ce 2>/dev/null | grep -qx 'install ok installed'; then
  CONFLICTS=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
  FOUND=()
  for pkg in "${CONFLICTS[@]}"; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed'; then FOUND+=("$pkg"); fi
  done
  if (("${#FOUND[@]}")); then
    warn "Removing conflicting packages: ${FOUND[*]}; Docker data is preserved"
    apt-get remove "${APT[@]}" "${FOUND[@]}"
  fi
fi
install -m 0755 -d /etc/apt/keyrings
curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $ARCH
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
apt-get install "${APT[@]}" docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
timeout 20 docker info >/dev/null || die 'Docker daemon did not respond'

log 'Installing root cron watchdog for Docker'
cat > /usr/local/sbin/docker-healthcheck <<'EOF'
#!/usr/bin/env bash
set -u
exec 9>/run/docker-healthcheck.lock
flock -n 9 || exit 0
systemctl is-active --quiet docker &&
  timeout --kill-after=5s 20s docker info >/dev/null 2>&1 &&
  timeout --kill-after=5s 30s docker system df >/dev/null 2>&1 && exit 0
logger -t docker-healthcheck 'Docker daemon unhealthy or unresponsive; restarting'
if timeout --kill-after=5s 45s systemctl restart docker; then
  timeout --kill-after=5s 20s docker info >/dev/null 2>&1 &&
    timeout --kill-after=5s 30s docker system df >/dev/null 2>&1 && exit 0
fi
# Kill only the root-owned Docker daemon if service restart hangs. Never erase cache/data.
logger -t docker-healthcheck 'Docker restart timed out; killing daemon and starting service'
timeout --kill-after=5s 15s systemctl kill --kill-who=main --signal=SIGKILL docker >/dev/null 2>&1 || true
systemctl reset-failed docker >/dev/null 2>&1 || true
timeout --kill-after=5s 45s systemctl start docker || exit 1
timeout --kill-after=5s 20s docker info >/dev/null 2>&1
EOF
chmod 0755 /usr/local/sbin/docker-healthcheck
printf '*/5 * * * * root /usr/local/sbin/docker-healthcheck\n' > /etc/cron.d/docker-healthcheck
chmod 0644 /etc/cron.d/docker-healthcheck
systemctl enable --now cron

log 'Installing VS Code from Microsoft repository'
curl -fsSL --retry 3 https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg
cat > /etc/apt/sources.list.d/vscode.sources <<'EOF'
Types: deb
URIs: https://packages.microsoft.com/repos/code
Suites: stable
Components: main
Architectures: amd64 arm64 armhf
Signed-By: /usr/share/keyrings/microsoft.gpg
EOF
apt-get update
apt-get install "${APT[@]}" code

log 'Installing GNS3 from official PPA'
if add-apt-repository -y ppa:gns3/ppa && apt-get update; then
  if apt-cache show gns3-gui >/dev/null 2>&1 && apt-cache show gns3-server >/dev/null 2>&1; then
    apt-get install "${APT[@]}" gns3-gui gns3-server || warn 'GNS3 install failed; check PPA release support'
  else warn 'GNS3 PPA has no packages for this Ubuntu release'; fi
else warn 'GNS3 PPA could not be added or updated'; fi
for group in wireshark ubridge libvirt kvm; do
  if getent group "$group" >/dev/null; then usermod -aG "$group" "$TARGET_USER"; fi
done

log 'Installing Python tools in isolated environments'
python3 -m venv /opt/volatility3-venv
/opt/volatility3-venv/bin/python -m pip install --upgrade pip volatility3
ln -sfn /opt/volatility3-venv/bin/vol /usr/local/bin/vol
python3 -m venv /opt/python-devtools-venv
/opt/python-devtools-venv/bin/python -m pip install --upgrade pip ruff debugpy
ln -sfn /opt/python-devtools-venv/bin/ruff /usr/local/bin/ruff

log 'Installing XSStrike from the previous toolkit'
if [[ -d /opt/xsstrike/.git ]]; then
  git -C /opt/xsstrike pull --ff-only || warn 'Keeping existing XSStrike checkout'
elif [[ ! -e /opt/xsstrike ]]; then
  git clone --depth 1 https://github.com/s0md3v/XSStrike.git /opt/xsstrike
else
  warn '/opt/xsstrike exists and is not a Git checkout'
fi
if [[ -f /opt/xsstrike/requirements.txt ]]; then
  python3 -m venv /opt/xsstrike/.venv
  /opt/xsstrike/.venv/bin/python -m pip install --upgrade pip
  /opt/xsstrike/.venv/bin/python -m pip install -r /opt/xsstrike/requirements.txt
  printf '#!/bin/sh\nexec /opt/xsstrike/.venv/bin/python /opt/xsstrike/xsstrike.py "$@"\n' > /usr/local/bin/xsstrike
  chmod 0755 /usr/local/bin/xsstrike
fi

log 'Installing current Go toolchain from official verified archive'
if [[ ! -x /usr/local/go/bin/go ]]; then
  [[ ! -e /usr/local/go ]] || die '/usr/local/go exists but is not a working Go installation'
  GO_METADATA="$(mktemp)"
  GO_ARCHIVE="$(mktemp --suffix=.tar.gz)"
  trap 'rm -f "$GO_METADATA" "$GO_ARCHIVE"' EXIT
  curl -fsSL --retry 3 'https://go.dev/dl/?mode=json' -o "$GO_METADATA"
  read -r GO_FILE GO_SHA < <(python3 - "$GO_METADATA" "$ARCH" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
for release in data:
    if release.get('stable'):
        for item in release['files']:
            if item.get('os') == 'linux' and item.get('arch') == sys.argv[2] and item.get('kind') == 'archive':
                print(item['filename'], item['sha256'])
                raise SystemExit
raise SystemExit('No stable Go archive for this architecture')
PY
)
  [[ -n $GO_FILE && -n $GO_SHA ]] || die 'Could not resolve current Go release'
  curl -fsSL --retry 3 "https://go.dev/dl/$GO_FILE" -o "$GO_ARCHIVE"
  printf '%s  %s\n' "$GO_SHA" "$GO_ARCHIVE" | sha256sum -c -
  tar -C /usr/local -xzf "$GO_ARCHIVE"
  rm -f "$GO_METADATA" "$GO_ARCHIVE"
  trap - EXIT
else
  log "Using existing $("/usr/local/go/bin/go" version)"
fi
cat > /etc/profile.d/go-path.sh <<'EOF'
export PATH="/usr/local/go/bin:$PATH"
EOF
export PATH="/usr/local/go/bin:$PATH"

log 'Installing Go language tools for desktop user'
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" GOTOOLCHAIN=auto GOPATH="$TARGET_HOME/go" /usr/local/go/bin/go install golang.org/x/tools/gopls@latest
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" GOTOOLCHAIN=auto GOPATH="$TARGET_HOME/go" /usr/local/go/bin/go install honnef.co/go/tools/cmd/staticcheck@latest
if ! grep -Fq '# security-toolkit-go-path' "$TARGET_HOME/.profile" 2>/dev/null; then
  printf '\n# security-toolkit-go-path\nexport PATH="$HOME/go/bin:$PATH"\n' >> "$TARGET_HOME/.profile"
  chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$TARGET_HOME/.profile"
fi

log 'Installing VS Code extensions'
for extension in ms-python.python ms-python.vscode-pylance charliermarsh.ruff golang.go ms-vscode.cpptools; do
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" code --install-extension "$extension" --force ||
    warn "VS Code extension failed: $extension"
done
SETTINGS_DIR="$TARGET_HOME/.config/Code/User"
install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" "$SETTINGS_DIR"
if [[ ! -e $SETTINGS_DIR/settings.json ]]; then
  cat > "$SETTINGS_DIR/settings.json" <<EOF
{
  "python.defaultInterpreterPath": "/usr/bin/python3",
  "python.analysis.typeCheckingMode": "basic",
  "go.toolsManagement.autoUpdate": true,
  "go.alternateTools": {
    "go": "/usr/local/go/bin/go",
    "gopls": "$TARGET_HOME/go/bin/gopls",
    "staticcheck": "$TARGET_HOME/go/bin/staticcheck"
  },
  "C_Cpp.default.compilerPath": "/usr/bin/g++",
  "C_Cpp.default.cppStandard": "c++20",
  "C_Cpp.codeAnalysis.clangTidy.enabled": true,
  "editor.formatOnSave": true
}
EOF
  chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$SETTINGS_DIR/settings.json"
else warn "Existing VS Code settings preserved: $SETTINGS_DIR/settings.json"; fi

log 'Installing Postman'
command -v snap >/dev/null 2>&1 || apt-get install "${APT[@]}" snapd
systemctl enable --now snapd.socket || true
snap install postman || warn 'Postman Snap failed; snapd may require a reboot'

log 'Installing Burp Suite Community'
case "$ARCH" in amd64) BURP_TYPE=Linux;; arm64) BURP_TYPE=LinuxArm64;; esac
BURP_INSTALLER="$(mktemp --suffix=.sh)"
trap 'rm -f "$BURP_INSTALLER"' EXIT
if curl -fsSL --retry 3 -o "$BURP_INSTALLER" "https://portswigger.net/burp/releases/download?product=community&type=$BURP_TYPE"; then
  chmod 0755 "$BURP_INSTALLER"
  "$BURP_INSTALLER" -q -dir /opt/BurpSuite || warn 'Burp Suite installer failed'
else warn 'Burp Suite download failed'; fi
for executable in /opt/BurpSuite/BurpSuite /opt/BurpSuite/BurpSuiteCommunity /opt/BurpSuiteCommunity/BurpSuiteCommunity; do
  if [[ -x $executable ]]; then ln -sfn "$executable" /usr/local/bin/burpsuite; break; fi
done

log 'Installing FoxyProxy Standard in Firefox and configuring Burp proxy'
install -m 0755 -d /etc/firefox/policies
python3 - /etc/firefox/policies/policies.json <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
if path.exists():
    config = json.loads(path.read_text(encoding='utf-8'))
else:
    config = {}
policies = config.setdefault('policies', {})
policies.setdefault('ExtensionSettings', {})['foxyproxy@eric.h.jung'] = {
    'installation_mode': 'normal_installed',
    'install_url': 'https://addons.mozilla.org/firefox/downloads/latest/foxyproxy@eric.h.jung/latest.xpi',
}
extensions = policies.setdefault('3rdparty', {}).setdefault('Extensions', {})
extensions['foxyproxy@eric.h.jung'] = {
    'mode': '127.0.0.1:8080',
    'data': [{
        'active': True,
        'title': 'Burp Suite',
        'type': 'http',
        'hostname': '127.0.0.1',
        'port': '8080',
        'username': '',
        'password': '',
        'cc': '',
        'city': '',
        'color': '#ff6633',
        'pac': '',
        'pacString': '',
        'proxyDNS': True,
        'include': [],
        'exclude': [],
        'tabProxy': [],
    }],
}
path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
PY
chmod 0644 /etc/firefox/policies/policies.json
cat > /usr/local/sbin/foxyproxy-burp <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
(( EUID == 0 )) || { echo 'Run with sudo' >&2; exit 1; }
case "${1:-}" in on) mode='127.0.0.1:8080';; off) mode='disable';; *)
  echo 'Usage: sudo foxyproxy-burp on|off' >&2; exit 2;; esac
python3 - /etc/firefox/policies/policies.json "$mode" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding='utf-8'))
config['policies']['3rdparty']['Extensions']['foxyproxy@eric.h.jung']['mode'] = sys.argv[2]
path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
PY
echo 'Restart Firefox to apply the change.'
EOF
chmod 0755 /usr/local/sbin/foxyproxy-burp

log 'Verification'
for cmd in docker code firefox python3 go g++ gdb clangd clang-format clang-tidy cppcheck ruff vol exiftool xxd binwalk qpdf tshark tcpdump gns3 postman burpsuite file tar zip unzip base64 htop btop which wc nc ssh curl nmap; do
  if command -v "$cmd" >/dev/null 2>&1; then printf '  [OK] %-14s %s\n' "$cmd" "$(command -v "$cmd")"; else printf '  [MISSING] %s\n' "$cmd"; fi
done
printf '\nDocker: sudo docker info. Health check: sudo /usr/local/sbin/docker-healthcheck. Logs: journalctl -t docker-healthcheck\n'
printf 'Log out and back in for Go PATH and Wireshark/GNS3 groups.\n'
printf 'Firefox: restart it for FoxyProxy policy. Start Burp before browsing; proxy 127.0.0.1:8080.\n'
printf 'Toggle: sudo foxyproxy-burp on|off, then restart Firefox. HTTPS needs Burp CA certificate in Firefox.\n'
