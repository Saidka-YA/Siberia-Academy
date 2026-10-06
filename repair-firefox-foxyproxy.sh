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
