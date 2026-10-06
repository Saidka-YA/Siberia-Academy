#!/usr/bin/env bash
set -Eeuo pipefail
# Arch Linux x86_64 desktop. Run: sudo bash install-security-toolkit-arch.sh
log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || die "Run with sudo: sudo bash $0"
[[ -r /etc/os-release ]] || die 'Missing /etc/os-release'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == arch ]] || die 'Arch Linux required'
[[ $(uname -m) == x86_64 ]] || die 'Arch Linux x86_64 required'
[[ -d /run/systemd/system ]] || die 'systemd is required'
TARGET_USER="${SUDO_USER:-}"
[[ -n $TARGET_USER && $TARGET_USER != root ]] && id "$TARGET_USER" >/dev/null 2>&1 || die 'Run from a regular desktop account with sudo'
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d $TARGET_HOME ]] || die "Missing home directory: $TARGET_HOME"

log 'Updating Arch Linux and installing official packages'
pacman -Syu --noconfirm
PACKAGES=(ca-certificates curl gnupg git perl-image-exiftool vim binwalk grep
  unzip zip qpdf binutils sleuthkit testdisk wireshark-qt wireshark-cli
  tcpdump traceroute bind inetutils openbsd-netcat iptables python python-pip
  file tar coreutils htop btop which openssh nmap base-devel gcc gdb cmake
  pkgconf clang cppcheck cronie firefox xterm docker docker-compose go sudo)
pacman -S --needed --noconfirm "${PACKAGES[@]}"
systemctl enable --now cronie docker
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
logger -t docker-healthcheck 'Docker restart timed out; killing daemon and starting service'
timeout --kill-after=5s 15s systemctl kill --kill-who=main --signal=SIGKILL docker >/dev/null 2>&1 || true
systemctl reset-failed docker >/dev/null 2>&1 || true
timeout --kill-after=5s 45s systemctl start docker || exit 1
timeout --kill-after=5s 20s docker info >/dev/null 2>&1
EOF
chmod 0755 /usr/local/sbin/docker-healthcheck
printf '*/5 * * * * root /usr/local/sbin/docker-healthcheck\n' > /etc/cron.d/docker-healthcheck
chmod 0644 /etc/cron.d/docker-healthcheck

log 'Installing GNS3, ubridge, VPCS, VS Code and Postman from AUR'
if ! command -v yay >/dev/null 2>&1; then
  AUR_BUILD_DIR="$(mktemp -d)"
  chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$AUR_BUILD_DIR"
  trap 'rm -rf -- "$AUR_BUILD_DIR"' EXIT
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" git clone https://aur.archlinux.org/yay.git "$AUR_BUILD_DIR/yay"
  printf 'Review the yay PKGBUILD before continuing: %s\n' "$AUR_BUILD_DIR/yay/PKGBUILD"
  read -r -p 'Have you reviewed it? Type yes to continue: ' REVIEWED
  [[ $REVIEWED == yes ]] || die 'AUR review not confirmed'
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" bash -c 'cd "$1" && makepkg -si' bash "$AUR_BUILD_DIR/yay"
  rm -rf -- "$AUR_BUILD_DIR"
  trap - EXIT
fi
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" yay -S --needed \
  gns3-gui gns3-server ubridge vpcs visual-studio-code-bin postman-bin

log 'Installing Python tools in isolated environments'
python3 -m venv /opt/volatility3-venv
/opt/volatility3-venv/bin/python -m pip install --upgrade pip volatility3
ln -sfn /opt/volatility3-venv/bin/vol /usr/local/bin/vol
python3 -m venv /opt/python-devtools-venv
/opt/python-devtools-venv/bin/python -m pip install --upgrade pip ruff debugpy
ln -sfn /opt/python-devtools-venv/bin/ruff /usr/local/bin/ruff

log 'Installing XSStrike'
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

log 'Installing Go tools and VS Code extensions for the desktop user'
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" GOPATH="$TARGET_HOME/go" go install golang.org/x/tools/gopls@latest
runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" GOPATH="$TARGET_HOME/go" go install honnef.co/go/tools/cmd/staticcheck@latest
if ! grep -Fq '# security-toolkit-go-path' "$TARGET_HOME/.profile" 2>/dev/null; then
  printf '\n# security-toolkit-go-path\nexport PATH="$HOME/go/bin:$PATH"\n' >> "$TARGET_HOME/.profile"
  chown "$TARGET_USER:$(id -gn "$TARGET_USER")" "$TARGET_HOME/.profile"
fi
for extension in ms-python.python ms-python.vscode-pylance charliermarsh.ruff golang.go ms-vscode.cpptools; do
  runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" code --install-extension "$extension" --force || warn "VS Code extension failed: $extension"
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

log 'Installing Burp Suite Community'
BURP_INSTALLER="$(mktemp --suffix=.sh)"
trap 'rm -f "$BURP_INSTALLER"' EXIT
if curl -fsSL --retry 3 -o "$BURP_INSTALLER" 'https://portswigger.net/burp/releases/download?product=community&type=Linux'; then
  chmod 0755 "$BURP_INSTALLER"
  "$BURP_INSTALLER" -q -dir /opt/BurpSuite || warn 'Burp Suite installer failed'
else warn 'Burp Suite download failed'; fi
for executable in /opt/BurpSuite/BurpSuite /opt/BurpSuite/BurpSuiteCommunity /opt/BurpSuiteCommunity/BurpSuiteCommunity; do
  if [[ -x $executable ]]; then ln -sfn "$executable" /usr/local/bin/burpsuite; break; fi
done
rm -f "$BURP_INSTALLER"
trap - EXIT

log 'Configuring FoxyProxy for Burp in Firefox'
install -m 0755 -d /etc/firefox/policies
python3 - /etc/firefox/policies/policies.json <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {}
policies = config.setdefault('policies', {})
policies.setdefault('ExtensionSettings', {})['foxyproxy@eric.h.jung'] = {
    'installation_mode': 'normal_installed',
    'install_url': 'https://addons.mozilla.org/firefox/downloads/latest/foxyproxy@eric.h.jung/latest.xpi',
}
policies.setdefault('3rdparty', {}).setdefault('Extensions', {})['foxyproxy@eric.h.jung'] = {
    'mode': '127.0.0.1:8080',
    'data': [{'active': True, 'title': 'Burp Suite', 'type': 'http',
              'hostname': '127.0.0.1', 'port': 8080, 'username': '', 'password': '',
              'cc': '', 'city': '', 'color': '#ff6633', 'pac': '', 'pacString': '',
              'proxyDNS': True, 'include': [], 'exclude': [], 'tabProxy': []}],
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

for group in wireshark ubridge libvirt kvm; do
  if getent group "$group" >/dev/null; then usermod -aG "$group" "$TARGET_USER"; fi
done

log 'Verification'
for cmd in docker code firefox python3 go g++ gdb clangd clang-format clang-tidy cppcheck ruff vol exiftool xxd binwalk qpdf tshark tcpdump xterm ubridge vpcs gns3 postman burpsuite file tar zip unzip base64 htop btop which wc nc ssh curl nmap; do
  if command -v "$cmd" >/dev/null 2>&1; then printf '  [OK] %-14s %s\n' "$cmd" "$(command -v "$cmd")"; else printf '  [MISSING] %s\n' "$cmd"; fi
done
printf 'Log out and back in for Go PATH and capture/GNS3 groups. Use sudo docker.\n'
