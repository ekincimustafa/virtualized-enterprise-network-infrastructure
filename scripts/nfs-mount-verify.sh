#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# RECONSTRUCTED OPERATIONAL HELPER SCRIPT FOR DOCUMENTATION & REPRODUCIBILITY
#
# Disclaimer:
# This script was NOT executed as an automated health-check during the live project.
# In the homelab environment, NFS mounts were verified manually using standard
# system commands (mount, df -h, ls).
#
# This helper script reconstructs those manual verification steps in a strictly
# read-only manner for repository documentation and operational diagnostics.
# Because the TrueNAS storage controller IP was logged as a dynamic/subnet target
# (10.10.20.x) rather than a permanently frozen static IP, this script avoids
# hard-coding remote host addresses and validates the local mount point directly.
# ==============================================================================

readonly MOUNT_POINT="/mnt/truenas_data"

echo "=== NFS Mount Verification (Read-Only Health Check) ==="
echo "Target Mount Point: ${MOUNT_POINT}"
echo "Network Subnet:     10.10.20.0/24 (Isolated LAN)"
echo "-------------------------------------------------------"

# 1. Check if the directory exists
if [[ ! -d "${MOUNT_POINT}" ]]; then
    echo "[-] FAIL: Directory '${MOUNT_POINT}' does not exist on the local filesystem." >&2
    exit 1
fi
echo "[+] OK: Directory '${MOUNT_POINT}' is present."

# 2. Check if the directory is actively mounted
if ! mountpoint -q "${MOUNT_POINT}"; then
    echo "[-] FAIL: '${MOUNT_POINT}' exists but is NOT an active mount point." >&2
    echo "    Hint: Check /etc/fstab entry and verify network connectivity to TrueNAS." >&2
    exit 1
fi
echo "[+] OK: '${MOUNT_POINT}' is confirmed as an active mount point."

# 3. Check filesystem type (must be NFS or NFSv4)
fs_type=$(findmnt -n -o FSTYPE -M "${MOUNT_POINT}" 2>/dev/null || true)
if [[ "${fs_type}" != "nfs" && "${fs_type}" != "nfs4" ]]; then
    echo "[-] FAIL: Expected filesystem type 'nfs' or 'nfs4', but detected: '${fs_type:-unknown}'" >&2
    exit 1
fi
echo "[+] OK: Filesystem type confirmed as '${fs_type}'."

# 4. Check read access by listing directory contents (strictly read-only)
if ! ls -1 -A "${MOUNT_POINT}" >/dev/null 2>&1; then
    echo "[-] FAIL: Unable to read directory contents inside '${MOUNT_POINT}'." >&2
    echo "    Hint: Check TrueNAS Maproot (root:root) configuration or directory POSIX permissions." >&2
    exit 1
fi
echo "[+] OK: Directory contents inside mount point are readable."

# 5. Display active mount details from system tables
echo ""
echo "=== Active Mount Details ==="
findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS -M "${MOUNT_POINT}"

echo ""
echo "[+] Health check passed: TrueNAS NFS storage fabric is properly mounted and accessible."