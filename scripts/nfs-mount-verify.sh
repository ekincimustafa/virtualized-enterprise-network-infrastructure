#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# RECONSTRUCTED READ-ONLY OPERATIONAL HELPER
#
# Disclaimer:
# This script was NOT used as an automated health-check during the original lab
# build. The NFS relationship was verified manually with standard Linux commands.
#
# Final verified storage path:
#   TrueNAS:      192.168.100.128
#   NFS export:   /mnt/ESXi_Pool/NFS_Datastore
#   Ubuntu mount: /mnt/truenas_data
#   Route:        via 10.10.20.1 dev ens160 from 10.10.20.50
#
# The helper performs read-only validation of the final documented architecture.
# ==============================================================================

readonly MOUNT_POINT="/mnt/truenas_data"
readonly EXPECTED_SERVER="192.168.100.128"
readonly EXPECTED_SOURCE="${EXPECTED_SERVER}:/mnt/ESXi_Pool/NFS_Datastore"
readonly EXPECTED_GATEWAY="10.10.20.1"
readonly EXPECTED_INTERFACE="ens160"
readonly EXPECTED_SOURCE_IP="10.10.20.50"

echo "=== NFS Mount Verification (Read-Only) ==="
echo "Mount Point:     ${MOUNT_POINT}"
echo "Expected Source: ${EXPECTED_SOURCE}"
echo "Expected Route:  ${EXPECTED_SOURCE_IP} -> ${EXPECTED_GATEWAY} -> ${EXPECTED_SERVER}"
echo "------------------------------------------------------------"

# 1. Verify the mount-point directory exists.
if [[ ! -d "${MOUNT_POINT}" ]]; then
    echo "[-] FAIL: Directory '${MOUNT_POINT}' does not exist." >&2
    exit 1
fi
echo "[+] OK: Mount-point directory exists."

# 2. Verify that the directory is an active mount point.
if ! mountpoint -q "${MOUNT_POINT}"; then
    echo "[-] FAIL: '${MOUNT_POINT}' is not an active mount point." >&2
    echo "    Check TrueNAS availability, pfSense routing, and the Ubuntu mount configuration." >&2
    exit 1
fi
echo "[+] OK: Active mount confirmed."

# 3. Verify filesystem type.
fs_type=$(findmnt -n -o FSTYPE -M "${MOUNT_POINT}" 2>/dev/null || true)
if [[ "${fs_type}" != "nfs" && "${fs_type}" != "nfs4" ]]; then
    echo "[-] FAIL: Expected NFS/NFSv4, detected '${fs_type:-unknown}'." >&2
    exit 1
fi
echo "[+] OK: Filesystem type is '${fs_type}'."

# 4. Verify the mounted source matches the final documented export.
mount_source=$(findmnt -n -o SOURCE -M "${MOUNT_POINT}" 2>/dev/null || true)
if [[ "${mount_source}" != "${EXPECTED_SOURCE}" ]]; then
    echo "[-] FAIL: Unexpected NFS source." >&2
    echo "    Expected: ${EXPECTED_SOURCE}" >&2
    echo "    Detected: ${mount_source:-unknown}" >&2
    exit 1
fi
echo "[+] OK: NFS source matches the verified TrueNAS export."

# 5. Verify the route to TrueNAS matches the final documented path.
route_output=$(ip route get "${EXPECTED_SERVER}" 2>/dev/null | head -n 1 || true)

if [[ -z "${route_output}" ]]; then
    echo "[-] FAIL: Unable to resolve a route to ${EXPECTED_SERVER}." >&2
    exit 1
fi

if [[ "${route_output}" != *"via ${EXPECTED_GATEWAY}"* ||
      "${route_output}" != *"dev ${EXPECTED_INTERFACE}"* ||
      "${route_output}" != *"src ${EXPECTED_SOURCE_IP}"* ]]; then
    echo "[-] FAIL: Route to TrueNAS does not match the verified architecture." >&2
    echo "    Expected gateway:   ${EXPECTED_GATEWAY}" >&2
    echo "    Expected interface: ${EXPECTED_INTERFACE}" >&2
    echo "    Expected source IP:  ${EXPECTED_SOURCE_IP}" >&2
    echo "    Detected route:      ${route_output}" >&2
    exit 1
fi
echo "[+] OK: Route to TrueNAS matches the verified pfSense-routed path."

# 6. Verify read access without creating/modifying files.
if ! ls -1 -A "${MOUNT_POINT}" >/dev/null 2>&1; then
    echo "[-] FAIL: Unable to read directory contents inside '${MOUNT_POINT}'." >&2
    echo "    Check TrueNAS NFS permissions and Maproot/POSIX permissions." >&2
    exit 1
fi
echo "[+] OK: Mount contents are readable."

# 7. Display final diagnostic state.
echo ""
echo "=== Active Mount ==="
findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS -M "${MOUNT_POINT}"

echo ""
echo "=== Route to TrueNAS ==="
echo "${route_output}"

echo ""
echo "[+] Health check passed: verified TrueNAS NFS mount and routed path are available."
