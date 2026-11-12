#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_PATH="${1:-${MAC_APP_DIR}/Bridge.app}"
OUT_DMG="${2:-${MAC_APP_DIR}/Bridge-macOS.dmg}"
VOLUME_NAME="Bridge"
BG_SRC="${MAC_APP_DIR}/Resources/dmg/dmg-background.tiff"
FALLBACK_DS_STORE="${MAC_APP_DIR}/Resources/dmg/DS_Store"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "Error: App bundle not found at ${APP_PATH}" >&2
  exit 1
fi

if [[ ! -f "${BG_SRC}" ]]; then
  echo "Error: DMG background image not found at ${BG_SRC}" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bridge-dmg.XXXXXX")"
STAGE_DIR="${WORK_DIR}/stage"
RW_DMG="${WORK_DIR}/Bridge-rw.dmg"
ATTACHED_DEVICE=""

cleanup() {
  if [[ -n "${ATTACHED_DEVICE}" ]]; then
    hdiutil detach "${ATTACHED_DEVICE}" >/dev/null 2>&1 || hdiutil detach -force "${ATTACHED_DEVICE}" >/dev/null 2>&1 || true
    ATTACHED_DEVICE=""
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

mkdir -p "${STAGE_DIR}/.background"
ditto "${APP_PATH}" "${STAGE_DIR}/Bridge.app"
ln -s /Applications "${STAGE_DIR}/Applications"
cp "${BG_SRC}" "${STAGE_DIR}/.background/dmg-bg.tiff"

APP_MB="$(du -sm "${STAGE_DIR}" | awk '{print $1}')"
DMG_MB=$(( APP_MB + 24 ))
if (( DMG_MB < 40 )); then
  DMG_MB=40
fi

hdiutil create \
  -srcfolder "${STAGE_DIR}" \
  -volname "${VOLUME_NAME}" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -size "${DMG_MB}m" \
  "${RW_DMG}" >/dev/null

ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "${RW_DMG}")"
ATTACHED_DEVICE="$(echo "${ATTACH_OUT}" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="$(echo "${ATTACH_OUT}" | awk -F'\t' '/\/Volumes\// {print $NF; exit}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

if [[ -z "${ATTACHED_DEVICE}" || -z "${MOUNT_POINT}" ]]; then
  echo "Error: Failed to attach temporary DMG ${RW_DMG}" >&2
  exit 1
fi

MOUNT_DISK_NAME="$(basename "${MOUNT_POINT}")"

if command -v SetFile >/dev/null 2>&1; then
  SetFile -a V "${MOUNT_POINT}/.background" || true
fi

# Style the DMG Finder window (bounds, dark green background, drag-to-Applications layout).
# Uses a bounded timeout and falls back to the checked-in .DS_Store template on headless hosts.
if ! python3 - "${MOUNT_DISK_NAME}" << 'PYEOF'
import subprocess, sys

disk_name = sys.argv[1]
script = f'''
tell application "Finder"
  tell disk "{disk_name}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {{200, 120, 840, 520}}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 120
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:dmg-bg.tiff"
    set position of item "Bridge.app" of container window to {{170, 185}}
    set position of item "Applications" of container window to {{470, 185}}
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
'''
try:
    res = subprocess.run(["osascript", "-e", script], timeout=20, check=False)
    sys.exit(res.returncode)
except subprocess.TimeoutExpired:
    sys.exit(1)
PYEOF
then
  echo "Warning: Finder AppleScript styling skipped or timed out; applying fallback .DS_Store layout"
  if [[ -f "${FALLBACK_DS_STORE}" ]]; then
    cp "${FALLBACK_DS_STORE}" "${MOUNT_POINT}/.DS_Store"
  fi
fi

sync
sleep 1

for attempt in 1 2 3; do
  if hdiutil detach "${ATTACHED_DEVICE}" >/dev/null 2>&1; then
    ATTACHED_DEVICE=""
    break
  fi
  sleep 1
done
if [[ -n "${ATTACHED_DEVICE}" ]]; then
  hdiutil detach -force "${ATTACHED_DEVICE}" >/dev/null
  ATTACHED_DEVICE=""
fi

mkdir -p "$(dirname "${OUT_DMG}")"
rm -f "${OUT_DMG}"
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -o "${OUT_DMG}" >/dev/null
hdiutil verify "${OUT_DMG}" >/dev/null

echo "Created verified DMG installer: ${OUT_DMG}"
