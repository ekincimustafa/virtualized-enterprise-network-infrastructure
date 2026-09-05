#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# RECONSTRUCTED OPERATIONAL HELPER SCRIPT FOR DOCUMENTATION & REPRODUCIBILITY
#
# Disclaimer:
# This script was NOT executed as an automated script during the live project.
# During the homelab build, volume expansion was performed manually via direct
# CLI commands (lvextend, resize2fs) to resolve a "no space left on device" error.
#
# This helper script encapsulates those manual CLI steps with interactive safety
# checks solely for repository documentation and reproducible disaster recovery.
# It is tailored specifically to this project's verified Ubuntu LVM configuration
# (/dev/ubuntu-vg/ubuntu-lv) and is not intended as a generic disk utility.
# ==============================================================================

readonly TARGET_VG="ubuntu-vg"
readonly TARGET_LV="/dev/ubuntu-vg/ubuntu-lv"
readonly TARGET_FS="/dev/mapper/ubuntu--vg-ubuntu--lv"

echo "=== LVM Online Storage Extension Helper ==="
echo "Target Volume Group:   ${TARGET_VG}"
echo "Target Logical Volume: ${TARGET_LV}"
echo "Target Filesystem:     ${TARGET_FS}"
echo "--------------------------------------------------"

# 1. Privilege check
if [[ "${EUID}" -ne 0 ]]; then
    echo "[-] Error: Root privileges required. Please execute with sudo." >&2
    exit 1
fi

# 2. Verify target block devices exist
if [[ ! -b "${TARGET_LV}" ]]; then
    echo "[-] Error: Target logical volume '${TARGET_LV}' not found on this system." >&2
    exit 1
fi

if [[ ! -b "${TARGET_FS}" ]]; then
    echo "[-] Error: Target device mapper node '${TARGET_FS}' not found." >&2
    exit 1
fi

# 3. Verify root filesystem (/) is actively mounted on the target volume
root_source=$(findmnt -n -o SOURCE -M / 2>/dev/null || true)

root_source_real=$(readlink -f "${root_source}" 2>/dev/null || true)
target_lv_real=$(readlink -f "${TARGET_LV}" 2>/dev/null || true)

if [[ -z "${root_source_real}" || "${root_source_real}" != "${target_lv_real}" ]]; then
    echo "[-] Error: Root filesystem (/) is mounted on '${root_source}', not the expected target logical volume." >&2
    exit 1
fi

echo "[+] Verified: Root filesystem (/) is actively mounted on target LVM storage."

# 4. Verify filesystem type is strictly ext4
root_fstype=$(findmnt -n -o FSTYPE -M / 2>/dev/null || true)
if [[ "${root_fstype}" != "ext4" ]]; then
    echo "[-] Error: Root filesystem type is '${root_fstype}', expected 'ext4'." >&2
    echo "    Aborting to prevent executing resize2fs on an unsupported filesystem." >&2
    exit 1
fi
echo "[+] Verified: Filesystem type is confirmed as ext4."

# 5. Check if Volume Group has free extents/space available
free_extents=$(vgs --noheadings -o vg_free_count "${TARGET_VG}" 2>/dev/null | tr -d '[:space:]' || true)
if [[ -z "${free_extents}" || "${free_extents}" -le 0 ]]; then
    echo "[*] Notice: Volume Group '${TARGET_VG}' has no free space or extents remaining (0 free extents)."
    echo "[*] No expansion needed or possible. Exiting cleanly without making changes."
    exit 0
fi
echo "[+] Verified: Free extents available in ${TARGET_VG} (${free_extents} extents)."
echo ""

# 6. Display current LVM and filesystem state
echo "[+] Current Volume Group status:"
vgs "${TARGET_VG}"
echo ""

echo "[+] Current Logical Volume status:"
lvs "${TARGET_LV}"
echo ""

echo "[+] Current root filesystem disk usage:"
df -h /
echo ""

# 7. Require explicit user confirmation before executing changes
read -r -p "[?] Proceed with allocating 100% of free Volume Group space to ${TARGET_LV}? (y/N): " user_input
if [[ "${user_input}" != "y" && "${user_input}" != "Y" ]]; then
    echo "[*] Operation canceled by user. No disk modifications were made."
    exit 0
fi

# 8. Execute volume expansion and online filesystem resize
echo ""
echo "[+] Step 1/2: Extending Logical Volume across remaining free pool..."
lvextend -l +100%FREE "${TARGET_LV}"

echo "[+] Step 2/2: Resizing ext4 filesystem structures online..."
resize2fs "${TARGET_FS}"

# 9. Output final filesystem state
echo ""
echo "[+] Volume expansion completed successfully. Updated disk usage:"
df -h /