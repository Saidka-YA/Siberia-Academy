#!/usr/bin/env bash
set -Eeuo pipefail
# Fedora Workstation 43/44, x86_64 or aarch64. Run: sudo bash install-security-toolkit-fedora.sh
log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
(( EUID == 0 )) || die "Run with sudo: sudo bash $0"
[[ -r /etc/os-release ]] || die 'Missing /etc/os-release'
# shellcheck disable=SC1091
source /etc/os-release
[[ ${ID:-} == fedora ]] || die 'Fedora required'
case "${VERSION_ID:-}" in 43|44) ;; *) die 'Use Fedora Workstation 43 or 44';; esac
ARCH="$(uname -m)"
case "$ARCH" in x86_64|aarch64) ;; *) die 'x86_64 or aarch64 required';; esac
[[ -d /run/systemd/system ]] || die 'systemd is required'
TARGET_USER="${SUDO_USER:-}"
[[ -n $TARGET_USER && $TARGET_USER != root ]] && id "$TARGET_USER" >/dev/null 2>&1 || die 'Run from a regular desktop account with sudo'
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -d $TARGET_HOME ]] || die "Missing home directory: $TARGET_HOME"
if ! rpm -q docker-ce >/dev/null 2>&1; then
  for pkg in podman-docker docker docker-common docker-engine docker-client; do
    rpm -q "$pkg" >/dev/null 2>&1 && die "Conflicting Docker package installed: $pkg. Resolve it before running this installer"
  done
fi

log 'Installing Fedora packages'
dnf -y upgrade --refresh
PACKAGES=(ca-certificates curl gnupg2 git perl-Image-ExifTool xxd binwalk grep
  unzip zip qpdf binutils sleuthkit testdisk wireshark wireshark-cli tcpdump
  traceroute bind-utils telnet ftp netcat iptables python3 python3-pip python3-devel
  file tar coreutils htop btop which openssh-clients nmap gcc gcc-c++ gdb
  cmake pkgconf-pkg-config clang clang-tools-extra cppcheck cronie firefox
  xterm ubridge gns3-gui gns3-server golang make glibc-static)
dnf -y install "${PACKAGES[@]}"
# Fedora provides telnet and ftp separately instead of GNU inetutils.
systemctl enable --now crond

log 'Installing VPCS from the GNS3 source repository'
if ! command -v vpcs >/dev/null 2>&1; then
  if [[ ! -e /opt/vpcs ]]; then git clone --depth 1 https://github.com/GNS3/vpcs.git /opt/vpcs; fi
  [[ -f /opt/vpcs/src/mk.sh ]] || die '/opt/vpcs exists but has no VPCS build script'
  (cd /opt/vpcs/src && sh mk.sh)
  install -m 0755 /opt/vpcs/src/vpcs /usr/local/bin/vpcs
fi

log 'Installing Docker Engine from the official Fedora repository'
if ! rpm -q docker-ce >/dev/null 2>&1; then
  dnf -y install dnf-plugins-core
  dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo
  dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
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
logger -t docker-healthcheck 'Docker restart timed out; killing daemon and starting service'
timeout --kill-after=5s 15s systemctl kill --kill-who=main --signal=SIGKILL docker >/dev/null 2>&1 || true
systemctl reset-failed docker >/dev/null 2>&1 || true
timeout --kill-after=5s 45s systemctl start docker || exit 1
timeout --kill-after=5s 20s docker info >/dev/null 2>&1
EOF
chmod 0755 /usr/local/sbin/docker-healthcheck
printf '*/5 * * * * root /usr/local/sbin/docker-healthcheck\n' > /etc/cron.d/docker-healthcheck
chmod 0644 /etc/cron.d/docker-healthcheck

log 'Installing VS Code from the Microsoft repository'
rpm --import https://packages.microsoft.com/keys/microsoft.asc
cat > /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
autorefresh=1
type=rpm-md
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
dnf -y install code

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

log 'Installing Postman'
dnf -y install snapd
systemctl enable --now snapd.socket
snap install postman || warn 'Postman Snap failed; snapd may require a reboot'

log 'Installing Burp Suite Community'
case "$ARCH" in x86_64) BURP_TYPE=Linux;; aarch64) BURP_TYPE=LinuxArm64;; esac
BURP_INSTALLER="$(mktemp --suffix=.sh)"
trap 'rm -f "$BURP_INSTALLER"' EXIT
if curl -fsSL --retry 3 -o "$BURP_INSTALLER" "https://portswigger.net/burp/releases/download?product=community&type=$BURP_TYPE"; then
  chmod 0755 "$BURP_INSTALLER"
  "$BURP_INSTALLER" -q -dir /opt/BurpSuite || warn 'Burp Suite installer failed'
else warn 'Burp Suite download failed'; fi
for executable in /opt/BurpSuite/BurpSuite /opt/BurpSuite/BurpSuiteCommunity /opt/BurpSuiteCommunity/BurpSuiteCommunity; do
  if [[ -x $executable ]]; then ln -sfn "$executable" /usr/local/bin/burpsuite; break; fi
done
rm -f "$BURP_INSTALLER"
trap - EXIT

log 'Removing obsolete managed FoxyProxy settings'
cat > /usr/local/sbin/foxyproxy-burp <<'FOXY_REPAIR'
#!/usr/bin/env bash
set -Eeuo pipefail
# Removes only the FoxyProxy policies created by the old toolkit installer.
(( EUID == 0 )) || { echo "Run with sudo: sudo bash $0" >&2; exit 1; }
case "${1:-unlock}" in
  off|unlock) ;;
  *) echo 'Use off or unlock. Enable Burp manually in the FoxyProxy menu.' >&2; exit 2;;
esac
python3 - <<'PY'
import datetime
import json
import pathlib
import shutil

path = pathlib.Path('/etc/firefox/policies/policies.json')
extension = 'foxyproxy@eric.h.jung'
if path.exists():
    config = json.loads(path.read_text(encoding='utf-8'))
    policies = config.get('policies', {})
    changed = False
    for section in (policies.get('ExtensionSettings', {}),
                    policies.get('3rdparty', {}).get('Extensions', {})):
        if extension in section:
            del section[extension]
            changed = True
    if changed:
        backup = path.with_name(path.name + '.backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f'))
        shutil.copy2(path, backup)
        path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
        print(f'FoxyProxy policies removed. Backup: {backup}')
    else:
        print('No toolkit FoxyProxy policies found.')
else:
    print('No toolkit Firefox policy file found.')
PY
echo 'Completely quit and restart Firefox, then disable FoxyProxy in about:addons'
echo 'or select Disable in its menu. Managed settings are no longer imposed.'
FOXY_REPAIR
chmod 0755 /usr/local/sbin/foxyproxy-burp
/usr/local/sbin/foxyproxy-burp unlock
printf 'Install FoxyProxy manually if needed: https://addons.mozilla.org/firefox/addon/foxyproxy-standard/\n'
printf 'Add an HTTP proxy 127.0.0.1:8080 in FoxyProxy; enable it only during Burp exercises.\n'

for group in wireshark ubridge libvirt kvm; do
  if getent group "$group" >/dev/null; then usermod -aG "$group" "$TARGET_USER"; fi
done

log 'Verification'
for cmd in docker code firefox python3 go g++ gdb clangd clang-format clang-tidy cppcheck ruff vol exiftool xxd binwalk qpdf tshark tcpdump xterm ubridge vpcs gns3 postman burpsuite file tar zip unzip base64 htop btop which wc nc ssh curl nmap; do
  if command -v "$cmd" >/dev/null 2>&1; then printf '  [OK] %-14s %s\n' "$cmd" "$(command -v "$cmd")"; else printf '  [MISSING] %s\n' "$cmd"; fi
done
printf 'Log out and back in for Go PATH and capture/GNS3 groups. Use sudo docker.\n'
