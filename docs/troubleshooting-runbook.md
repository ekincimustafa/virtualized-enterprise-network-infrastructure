# Troubleshooting Runbook: Incident Log and Operational Diagnostics

---

## 1. Purpose and Scope

This runbook documents the technical failures, configuration conflicts, and operational issues encountered during the design and integration of the **Virtualized Enterprise Network Infrastructure** project.

The goal is not to present an idealized deployment. Instead, the document records the troubleshooting process at the level supported by the preserved project history: observed symptoms, the affected infrastructure layer, the confirmed remediation when it was preserved, and the engineering lesson that followed.

### Provenance and Artifact Classification

This document distinguishes between three categories:

- **Observed during the live project:** behavior or problems encountered while building and testing the VMware-based homelab.
- **Confirmed resolution:** a setting or command that is documented as having resolved the corresponding issue.
- **Reconstructed repository artifact:** a configuration template, Compose file, CSV summary, or helper script created later for documentation and reproducibility.

Where an exact command, log line, or root cause was not permanently preserved, this runbook states that explicitly rather than reconstructing it as if it were a live record.

---

## 2. Troubleshooting Methodology

The project used a practical layer-by-layer troubleshooting approach:

```text
1. Observe the symptom
        |
        v
2. Identify the affected layer
   Virtualization / Network / Storage / OS / Container
        |
        v
3. Inspect the current state
   Interfaces / routes / sockets / mounts / services
        |
        v
4. Change one variable at a time
        |
        v
5. Re-test the affected path
        |
        v
6. Preserve the verified resolution
```

This approach is especially useful in a virtualized infrastructure because an application symptom can originate from a lower layer. For example, a container startup failure may actually be caused by host disk exhaustion, a host socket conflict, or unavailable network storage.

---

## 3. Incident 1 — Nested Virtualization / AMD-V Availability

**Layer:** Virtualization / Hypervisor

### Observed Symptom

The nested VMware ESXi 8.0 test instance encountered hardware-virtualization availability problems when running inside VMware Workstation Pro.

The project history associates the issue with nested AMD-V exposure and Windows host virtualization features such as VBS / Hyper-V-related layers.

### Impact

The ESXi evaluation environment could not operate as intended until nested virtualization was correctly exposed to the guest.

### Investigation

The troubleshooting process focused on two boundaries:

1. whether VMware Workstation was exposing hardware-assisted virtualization to the nested guest;
2. whether Windows host virtualization features were interfering with that exposure.

The exact Windows CLI, registry, or feature-toggle sequence used during troubleshooting was not permanently preserved.

### Confirmed Root Cause

The project records support a conflict involving nested hardware-virtualization exposure and host-side virtualization layers. The exact contribution of each Windows virtualization feature was not preserved in enough detail to attribute the failure to one specific setting.

### Resolution

The nested ESXi VM configuration included the following verified VMware `.vmx` parameters:

```text
vhv.enable = "TRUE"
hypervisor.cpuid.v0 = "FALSE"
```

Host-side virtualization settings were also reviewed/adjusted during troubleshooting, but the exact Windows changes are not reproduced here because they were not permanently documented.

### Verification

The nested ESXi instance subsequently operated as a virtualization test environment.

### Repository Artifact

The nested virtualization role and verified `.vmx` parameters are described in [architecture-deep-dive.md](architecture-deep-dive.md).

### Engineering Lesson

Nested virtualization problems must be diagnosed across both the outer hypervisor and the host operating system. A guest-side virtualization error does not necessarily originate inside the guest.

---

## 4. Incident 2 — Ubuntu Root Filesystem Exhaustion

**Layer:** Compute / Storage / LVM

### Observed Symptom

The Ubuntu Server compute node encountered:

```text
no space left on device
```

The failure interrupted container-related operations because the root filesystem had exhausted its allocated space.

### Impact

Docker image and service operations could not continue normally while the root filesystem was full.

### Investigation

Inspection of the Ubuntu LVM layout showed that free capacity still existed in the Volume Group even though the root Logical Volume had reached its current limit.

The preserved project history confirms the relevant Logical Volume paths:

```text
/dev/ubuntu-vg/ubuntu-lv
/dev/mapper/ubuntu--vg-ubuntu--lv
```

Exact disk-size values from the live incident were not retained and are intentionally not reconstructed here.

### Confirmed Root Cause

The Ubuntu LVM layout had unused Volume Group capacity that had not yet been allocated to the root Logical Volume.

### Resolution

The following commands were executed manually during the project:

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

The first command allocated the remaining free extents to the root Logical Volume. The second expanded the ext4 filesystem to use the enlarged block device.

### Verification

The root filesystem capacity increased online and the Ubuntu VM did not require a reboot for the resize operation.

### Repository Artifact

The later-created helper [lvm-online-extend.sh](../scripts/lvm-online-extend.sh) reconstructs these manual steps with additional safety checks and interactive confirmation.

It is **not** the original deployment script.

### Engineering Lesson

Logical disk capacity and filesystem capacity are separate layers. A virtual disk can have available capacity while the mounted filesystem remains full because the Logical Volume has not been expanded.

---

## 5. Incident 3 — NFS Permission / Root Mapping Failure

**Layer:** Storage / NFS / Container Persistence

### Observed Symptom

Containerized services encountered write-permission problems when using the TrueNAS-backed storage mounted at:

```text
/mnt/truenas_data
```

### Impact

Applications could not reliably initialize or write their expected persistent data to the NFS-backed paths.

### Investigation

The troubleshooting process separated two questions:

1. Was the NFS storage mounted and reachable?
2. Were the identities used by container initialization processes allowed to perform the required filesystem operations?

The incident led to investigation of NFS root identity mapping / root-squashing behavior.

Exact UID traces, packet captures, and complete application error logs were not permanently preserved.

### Confirmed Root Cause

The preserved project history supports an NFS root-mapping permission conflict between container-side operations and the TrueNAS export.

### Resolution

The TrueNAS NFS configuration was changed to:

```text
Maproot User: root
Maproot Group: root
```

This allowed the required root-originated initialization operations to succeed in the lab.

### Verification

After the storage permission configuration was changed, the affected application storage became writable for the required container operations.

### Repository Artifact

The later-created [nfs-mount-verify.sh](../scripts/nfs-mount-verify.sh) is a read-only diagnostic helper that checks the mount point, filesystem type, and readability.

It is a **reconstructed repository artifact**, not a script that was used during the original incident.

### Security Trade-off

Mapping client root to server root increases privilege on the NFS export. It was accepted as a lab-specific compatibility decision and should not be treated as a universal production recommendation.

A stricter design could use aligned UIDs/GIDs, more restrictive identity mapping, per-application exports, or appropriate ACLs. Those alternatives were not implemented as part of this project.

### Engineering Lesson

When a container uses a host bind mount backed by NFS, successful mounting alone does not guarantee successful writes. NFS identity mapping and server-side permissions must also match the application's runtime behavior.

---

## 6. Incident 4 — pfSense Private WAN Filtering

**Layer:** Network / Firewall

### Observed Symptom

Host-side access through the pfSense WAN-facing lab segment did not behave as required while the WAN interface used the private address:

```text
192.168.100.250
```

on the private host-side network:

```text
192.168.100.0/24
```

### Impact

The intended host-to-lab ingress path could not operate correctly with the default WAN assumptions left unchanged.

### Investigation

pfSense WAN defaults are designed for an Internet-facing interface. In this homelab, however, the WAN side itself exists inside an RFC1918 private network.

The relevant WAN options were reviewed:

- `Block private networks`
- `Block bogon networks`

### Confirmed Root Cause

The **Block private networks** option directly conflicted with the lab design because legitimate host-side traffic originated from an RFC1918 address range.

`Block bogon networks` was also disabled as part of the lab-specific WAN configuration. This runbook does not claim that the bogon option itself was the specific cause of the RFC1918 failure.

### Resolution

On the pfSense WAN interface, the following options were unchecked for this private-WAN lab topology:

```text
Block private networks
Block bogon networks
```

### Verification

The intended host-side ingress path through the pfSense WAN interface became usable after the WAN policy was adjusted.

### Repository Artifact

The WAN design is described in [architecture-deep-dive.md](architecture-deep-dive.md). The verified DNAT mappings are summarized separately in [nat-rules-summary.csv](../configs/pfsense/nat-rules-summary.csv).

### Engineering Lesson

A firewall's secure defaults reflect an assumed topology. When a laboratory "WAN" is itself an RFC1918 network, those assumptions must be reviewed rather than disabled blindly.

---

## 7. Incident 5 — pfSense HTTPS Management Port Conflict

**Layer:** Network / Management Plane / Ingress

### Observed Symptom

pfSense WebConfigurator used `443/TCP`, while Nginx Proxy Manager also needed the lab's WAN-side `443/TCP` ingress path for HTTPS forwarding.

### Impact

The same WAN address could not cleanly serve the intended pfSense management path and NPM HTTPS ingress design using the same port.

### Investigation

The conflict was treated as a management-plane versus application-ingress problem rather than as an application failure.

The exact internal pfSense web-server process or socket listing was not preserved and is therefore not reconstructed here.

### Confirmed Root Cause

The management interface and the desired HTTPS ingress design competed for the same logical service port on the pfSense WAN address.

### Resolution

pfSense WebConfigurator was moved from:

```text
443/TCP
```

to:

```text
8443/TCP
```

Port `443/TCP` was then reserved for the verified NPM DNAT path:

```text
192.168.100.250:443
        ->
10.10.20.50:443
```

This was a **pfSense management listening-port change**, not another DNAT rule.

### Verification

pfSense administration was available through:

```text
https://192.168.100.250:8443
```

while the WAN `443/TCP` mapping could be used for Nginx Proxy Manager ingress.

### Repository Artifact

The distinction is documented in [nat-rules-summary.csv](../configs/pfsense/nat-rules-summary.csv).

### Engineering Lesson

Management-plane ports should be planned separately from application-ingress ports. Port conflicts at an edge device can look like application routing failures even when the backend service is healthy.

---

## 8. Incident 6 — Port 53 Conflict with `systemd-resolved`

**Layer:** Compute OS / Container Networking

### Observed Symptom

Pi-hole could not bind the required host DNS port because port `53` was already in use on Ubuntu Server.

### Impact

The Pi-hole DNS service could not start with the intended host mappings for:

```text
53/TCP
53/UDP
```

### Investigation

The conflict was traced to Ubuntu's local `systemd-resolved` stub listener.

The project history preserves the configuration change, but not every command used to restart or inspect the service.

### Confirmed Root Cause

The local DNS stub listener occupied port 53 in a way that conflicted with Docker's attempt to publish Pi-hole on the host DNS port.

### Resolution

The verified configuration was added to:

```text
/etc/systemd/resolved.conf
```

as:

```ini
[Resolve]
DNSStubListener=no
```

The resolver configuration was then reloaded/restarted so the stub listener no longer occupied the required host port.

### Verification

Pi-hole was subsequently able to bind the intended DNS ports.

### Repository Artifact

The setting is preserved as a reconstructed configuration template in [resolved.conf](../configs/systemd/resolved.conf).

### Engineering Lesson

When Docker reports a host-port binding conflict, the first diagnostic target should be the host socket table. A container can fail before its own application process starts because another host service already owns the requested port.

---

## 9. Incident 7 — Nginx Proxy Manager / OpenResty 404

**Layer:** Layer 7 Ingress / Reverse Proxy

### Observed Symptom

Requests routed through Nginx Proxy Manager produced an OpenResty/Nginx-style `404` response instead of the expected backend application.

### Impact

The backend services could exist and still remain inaccessible through their intended `.lab.local` hostnames.

### Investigation

The troubleshooting process considered multiple layers:

- whether the target backend container was running;
- whether the backend service was reachable on its host port;
- whether the incoming `Host` header matched an NPM Proxy Host entry;
- whether NPM configuration state remained consistent after earlier system/storage problems.

Earlier draft documentation associated this incident with host disk saturation and possible NPM/SQLite corruption. The preserved evidence is not strong enough to treat that explanation as a confirmed root cause.

### Confirmed Root Cause

**Root cause was not conclusively preserved.**

The observed 404 was consistent with a reverse-proxy routing/configuration problem, but the available project history does not justify attributing it to a specific database-corruption or disk-saturation mechanism.

### Resolution

The exact final remediation sequence was not preserved with enough confidence to reproduce it as a verified step-by-step fix.

The project ultimately reached a working state in which the intended NPM host-based mappings routed:

```text
nextcloud.lab.local -> 10.10.20.50:8080
git.lab.local       -> 10.10.20.50:3000
pihole.lab.local    -> 10.10.20.50:8053
```

These mappings describe the verified final architecture, not necessarily the exact troubleshooting sequence used during the incident.

### Verification

The final lab architecture successfully used Nginx Proxy Manager for host-based routing to the documented backend services.

### Repository Artifact

The final routing design is described in [architecture-deep-dive.md](architecture-deep-dive.md).

### Engineering Lesson

An HTTP 404 should first be attributed to the component that generated it. Direct backend testing and hostname-based proxy testing should be separated before concluding that the application itself is broken.

---

## 10. Incident 8 — Pi-hole v6 Configuration and Password Handling

**Layer:** Container / Application Configuration

### Observed Symptom

Pi-hole v6 configuration and administrative-password handling differed from older examples and guidance used for previous Pi-hole versions.

### Impact

Legacy configuration assumptions could not simply be reused for the v6 deployment.

### Investigation

The project identified that Pi-hole v6 uses a newer configuration model. The exact interactive password-change command used during live troubleshooting was not permanently preserved.

### Confirmed Root Cause

The issue was a **version-specific configuration mismatch**: legacy Pi-hole configuration examples did not map directly to the Pi-hole v6 behavior used in the lab.

### Resolution

The exact original live CLI sequence is not reconstructed here.

For repository reproducibility, the later-created Compose template uses:

```yaml
FTLCONF_webserver_api_password: "${PIHOLE_PASSWORD:?PIHOLE_PASSWORD must be defined in .env}"
```

The reconstructed Compose template also contains:

```yaml
FTLCONF_dns_listeningMode: 'ALL'
```

The latter is documented as a **reconstructed Compose compatibility requirement** for the chosen Docker networking approach, not as a preserved original live deployment setting.

### Verification

The final live lab used Pi-hole v6 successfully for local DNS service and local record management. The repository Compose file represents a later reconstruction of the service definition.

### Repository Artifact

See:

- [docker-compose.yml](../compose/docker-compose.yml)
- [.env.example](../compose/.env.example)

### Engineering Lesson

Major-version upgrades can change configuration interfaces even when the application's high-level role stays the same. Version-specific deployment documentation should be checked before reusing old environment variables or commands.

---

## 11. Cross-Layer Troubleshooting Lessons

The incidents demonstrate how failures propagate across infrastructure layers:

```text
Physical Host / Hypervisor
        |
        +-- Nested virtualization exposure
        |
Network Perimeter
        |
        +-- Private-WAN filtering
        +-- Management / ingress port conflict
        |
Storage
        |
        +-- NFS identity and permission mapping
        |
Compute OS
        |
        +-- LVM filesystem exhaustion
        +-- Port 53 host-socket conflict
        |
Containers / Layer 7
        |
        +-- Reverse-proxy routing
        +-- Pi-hole version-specific configuration
```

### 11.1 Hypervisor Problem vs. Guest Problem

A guest error can be caused by a host or outer-hypervisor constraint. Nested virtualization is a clear example: changing settings inside ESXi alone cannot solve a problem if hardware virtualization is not exposed through VMware Workstation.

### 11.2 Network Problem vs. Application Problem

A service can be healthy while pfSense blocks the path to it. Network reachability, firewall policy, NAT, and application health should be tested as separate stages.

### 11.3 Host Port Conflict vs. Docker Failure

Docker may report that a container cannot start even when the image and container configuration are otherwise valid. The real problem may simply be that the requested host port is already owned by an operating-system service.

### 11.4 Storage Availability vs. Container Failure

An application error can originate from the filesystem beneath the container. NFS mount state and permissions should be checked before debugging higher-level application behavior.

### 11.5 DNS Resolution vs. HTTP Routing

Internal application access involves at least two separate decisions:

```text
DNS name -> ingress IP
HTTP Host header -> reverse-proxy backend
```

A successful DNS lookup does not prove that NPM routing is correct, and a working backend does not prove that the hostname resolves correctly.

---

## 12. Diagnostic Command Reference

The commands below are **useful diagnostic commands for reproducing or investigating similar failures**. They are not presented as a complete record of commands executed during the original incidents.

### Network and Socket Diagnostics

```bash
# Display interface addresses and state
ip addr

# Display routes
ip route

# Inspect listening TCP/UDP sockets and owning processes
sudo ss -lntup

# Test reachability to the pfSense LAN gateway from the internal LAN
ping -c 3 10.10.20.1

# Query an explicitly selected DNS server
nslookup git.lab.local <dns_server_ip>
```

### Storage and Filesystem Diagnostics

```bash
# Display filesystem usage
df -h

# Display block devices and mount points
lsblk

# Inspect LVM Volume Groups
sudo vgs

# Inspect LVM Logical Volumes
sudo lvs

# Inspect the NFS-backed mount
findmnt -o SOURCE,TARGET,FSTYPE,OPTIONS -M /mnt/truenas_data

# Test whether the path is an active mount point
mountpoint -q /mnt/truenas_data && echo "Mounted" || echo "Not mounted"
```

### Container Runtime Diagnostics

```bash
# List containers and their current state
docker ps -a

# Inspect recent logs for one container
docker logs --tail 50 <container_name>

# Inspect Docker's recorded configuration for one container
docker inspect <container_name>
```

These commands are diagnostic only. State-changing recovery commands should be used only after the affected layer has been identified and the target system has been verified.

---

## 13. Reconstructed Operational Artifacts

The repository contains several artifacts created after the live build to make the project easier to review and reproduce.

| Repository Artifact | Provenance | Purpose |
| :--- | :--- | :--- |
| [`scripts/lvm-online-extend.sh`](../scripts/lvm-online-extend.sh) | 🔄 Reconstructed | Encapsulates the verified manual `lvextend` and `resize2fs` operations with additional safety checks. |
| [`scripts/nfs-mount-verify.sh`](../scripts/nfs-mount-verify.sh) | 🔄 Reconstructed | Provides a read-only NFS mount health check based on the verified mount design. |
| [`configs/systemd/resolved.conf`](../configs/systemd/resolved.conf) | 🔄 Reconstructed from verified setting | Preserves the verified `DNSStubListener=no` directive. |
| [`configs/pfsense/nat-rules-summary.csv`](../configs/pfsense/nat-rules-summary.csv) | 🔄 Sanitized reconstruction | Documents verified DNAT mappings without publishing a raw pfSense backup. |
| [`compose/docker-compose.yml`](../compose/docker-compose.yml) | 🔄 Reconstructed | Recreates the documented container service definitions for repository reproducibility. |
| [`compose/.env.example`](../compose/.env.example) | 🔄 Reconstructed | Provides a secret-free environment-variable template for the reconstructed Compose deployment. |

The artifacts above should not be interpreted as proof that the live environment was originally deployed from these files.

---

## 14. Preventive Improvements

The following items are **future recommendations** derived from the incidents. They were not implemented as part of the documented live project unless explicitly stated elsewhere.

- **Disk-space monitoring:** alert before the Ubuntu root filesystem or physical host storage reaches a critical threshold.
- **Configuration backups:** retain sanitized exports or documented settings for pfSense, TrueNAS, and other critical infrastructure.
- **Service health checks:** validate important sockets and service endpoints after changes or reboots.
- **Documented startup procedure:** preserve the recommended TrueNAS → Ubuntu/NFS mount → Docker/application startup relationship alongside the separate pfSense ingress dependency.
- **Periodic mount verification:** verify that `/mnt/truenas_data` is an active NFS mount before dependent applications are started.
- **More restrictive NFS identity design:** evaluate UID/GID alignment, per-application exports, or suitable ACLs instead of broad root mapping.
- **Version-pinned container review:** document major-version configuration changes before upgrading infrastructure services such as Pi-hole.

---

## 15. Key Troubleshooting Takeaways

1. **Troubleshoot the lowest plausible layer first.** A container symptom can originate from disk, networking, storage, or the hypervisor.
2. **Separate capacity layers.** Virtual-disk size, LVM allocation, and filesystem size are different things and must be checked independently.
3. **Treat port-binding errors as host-level evidence.** Verify which process owns a socket before changing container configuration.
4. **Mount success and write permission are different checks.** NFS identity mapping can fail even when the share is reachable.
5. **Private laboratory WANs require firewall defaults to be reviewed in context.** RFC1918 WAN addressing differs from the topology pfSense normally assumes.
6. **Keep the management plane distinct from application ingress.** The pfSense `8443` change prevented the management interface from competing with the intended HTTPS ingress port.
7. **DNS and reverse-proxy routing are independent layers.** Validate name resolution and HTTP host routing separately.
8. **Do not overstate uncertain root causes.** The NPM/OpenResty 404 incident demonstrates why observed symptoms, investigated possibilities, and confirmed causes should be documented separately.
9. **Major application versions can invalidate old configuration examples.** Pi-hole v6 required version-aware configuration handling.
10. **Repository provenance matters.** Reconstructed scripts and templates improve reproducibility only when they are clearly distinguished from artifacts actually used during the live build.
