# Troubleshooting Runbook: Incident Log and Operational Diagnostics

---

## 1. Purpose and Scope

This runbook documents failures and configuration conflicts encountered while building the **Virtualized Enterprise Network Infrastructure** homelab.

Its purpose is to preserve:

- the observed symptom;
- the affected layer;
- the confirmed or best-supported cause;
- the resolution actually preserved in the project history;
- the verification method;
- the engineering lesson.

The document intentionally avoids turning uncertain recollections into exact technical claims.

---

## 2. Provenance Labels

Three evidence levels are used throughout this runbook.

### Observed live behavior

A symptom or state encountered while building or validating the environment.

### Confirmed resolution

A preserved setting, command, or configuration change known to have resolved the issue.

### Reconstructed repository artifact

A file created later to make the project easier to review or reproduce.

Examples:

- `compose/docker-compose.yml`
- `configs/pfsense/nat-rules-summary.csv`
- `scripts/lvm-online-extend.sh`
- `scripts/nfs-mount-verify.sh`

A reconstructed artifact is **not** presented as the original deployment source.

---

## 3. Troubleshooting Method

The project followed a practical bottom-up approach:

```text
1. Identify the visible symptom
2. Locate the likely infrastructure layer
3. Inspect actual runtime state
4. Change one variable
5. Re-test
6. Preserve only the verified conclusion
```

Typical inspection layers were:

```text
Hypervisor
-> virtual networking
-> routing / firewall
-> storage / mount
-> operating system
-> Docker
-> application
```

A high-level application symptom often originated below the application layer.

---

# Incident Log

## 4. Incident 1 — Nested Virtualization / AMD-V Availability

**Layer:** Physical host / VMware Workstation / nested hypervisor

### Symptom

The nested ESXi VM could not operate correctly when hardware-assisted virtualization was not exposed as required.

The project history associated the problem with nested AMD-V exposure and Windows host virtualization features.

### Impact

The ESXi layer could not be used as the intended nested hypervisor.

### Investigation

Troubleshooting focused on:

- VMware Workstation nested-virtualization settings;
- whether AMD virtualization extensions were visible inside the nested guest;
- possible interference from Windows host virtualization layers.

The exact complete Windows feature/registry/CLI sequence was not preserved and is therefore not reconstructed as a guaranteed recipe.

### Confirmed configuration

The ESXi Workstation VM used:

```text
vhv.enable = "TRUE"
hypervisor.cpuid.v0 = "FALSE"
```

### Verification

The final environment successfully ran **VMware ESXi 7.0.3** as a nested Workstation VM and hosted:

- pfSense;
- Ubuntu Server;
- Windows Server AD.

### Lesson

Nested virtualization must be diagnosed across both the outer hypervisor and the host operating system.

---

## 5. Incident 2 — Ubuntu Root Filesystem Exhaustion

**Layer:** Ubuntu / LVM / Docker host storage

### Symptom

Ubuntu reported:

```text
no space left on device
```

Container/image operations could no longer proceed normally.

### Cause

The preserved project history showed unused free extents remaining in the LVM Volume Group while the root Logical Volume had reached its current allocation.

Relevant paths:

```text
/dev/ubuntu-vg/ubuntu-lv
/dev/mapper/ubuntu--vg-ubuntu--lv
```

### Confirmed resolution

The commands executed manually were:

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/mapper/ubuntu--vg-ubuntu--lv
```

### Result

The logical volume and ext4 filesystem were expanded online.

### Reconstructed helper

[`../scripts/lvm-online-extend.sh`](../scripts/lvm-online-extend.sh)

The helper was created after the incident and adds:

- root checks;
- target-device validation;
- filesystem validation;
- free-extent checks;
- explicit user confirmation.

It was **not** the original live repair script.

### Lesson

Virtual disk size, LVM allocation, and filesystem size are separate capacity layers.

---

## 6. Incident 3 — NFS Write Permission / Root Mapping Failure

**Layer:** TrueNAS / NFS / Docker persistence

### Symptom

Containerized services could reach the NFS-backed path but encountered write/initialization permission failures.

Affected host mount:

```text
/mnt/truenas_data
```

### Investigation

The mount itself and the NFS identity/permission model were treated as separate questions:

1. Is the NFS filesystem mounted?
2. Can the relevant process identity write to it?

### Best-supported cause

The preserved project history supports a root identity-mapping conflict between container initialization operations and the TrueNAS NFS export.

Complete UID traces or packet captures were not preserved.

### Confirmed lab resolution

TrueNAS NFS Maproot was configured as:

```text
Maproot User:  root
Maproot Group: root
```

### Result

The required container-side storage initialization became writable.

### Security note

This increases the authority of a root-capable NFS client and is therefore a **lab-specific trade-off**, not a production default.

### Reconstructed diagnostic helper

[`../scripts/nfs-mount-verify.sh`](../scripts/nfs-mount-verify.sh)

The script is read-only and checks mount state, filesystem type, and readability.

### Lesson

A successful NFS mount does not prove that application write permissions are correct.

---

## 7. Incident 4 — pfSense Private-WAN Filtering

**Layer:** pfSense / network perimeter

### Symptom

Host-side communication through pfSense WAN did not behave as required while the WAN itself used a private RFC1918 network.

Verified WAN address:

```text
192.168.100.250/24
```

### Cause

The pfSense default `Block private networks` behavior conflicts with a lab where legitimate WAN-side traffic originates from a private subnet.

### Confirmed lab configuration

The WAN settings were changed to disable:

```text
Block private networks
Block bogon networks
```

The project specifically supports `Block private networks` as conflicting with the RFC1918 WAN design.

`Block bogon networks` was also disabled as part of the lab configuration, but this runbook does not claim it was independently the root cause of the RFC1918 access failure.

### Verification

The required host-side access path became usable.

### Lesson

Firewall defaults are based on topology assumptions. A private laboratory WAN must be treated differently from a real Internet-facing WAN.

---

## 8. Incident 5 — pfSense Port 443 Management Conflict

**Layer:** pfSense management plane / application ingress

### Symptom

The pfSense WebConfigurator and the intended Nginx Proxy Manager HTTPS ingress both required WAN-side `443/TCP`.

### Cause

The same address/port could not cleanly represent both management access and forwarded application ingress.

### Confirmed resolution

The pfSense WebConfigurator was moved to:

```text
8443/TCP
```

Management URL:

```text
https://192.168.100.250:8443
```

WAN `443/TCP` was then available for the verified DNAT rule:

```text
192.168.100.250:443
        ->
10.10.20.50:443
```

### Evidence

[`screenshots/03-pfsense-nat-rules.png`](screenshots/03-pfsense-nat-rules.png)

Sanitized NAT summary:

[`../configs/pfsense/nat-rules-summary.csv`](../configs/pfsense/nat-rules-summary.csv)

### Lesson

Management-plane ports should be deliberately separated from application ingress.

---

## 9. Incident 6 — Pi-hole Port 53 Conflict

**Layer:** Ubuntu / `systemd-resolved` / Docker

### Symptom

Pi-hole could not bind host DNS ports:

```text
53/TCP
53/UDP
```

because another local service already occupied the DNS listener.

### Cause

Ubuntu's `systemd-resolved` DNS stub listener conflicted with Docker's attempt to publish Pi-hole on host port 53.

### Confirmed configuration

`/etc/systemd/resolved.conf` was configured with:

```ini
[Resolve]
DNSStubListener=no
```

The resolver service was then restarted/reloaded during the live troubleshooting process.

### Result

Pi-hole was able to use the intended DNS host ports.

### Reconstructed artifact

[`../configs/systemd/resolved.conf`](../configs/systemd/resolved.conf)

### Lesson

When Docker reports a port-binding failure, inspect host socket ownership before debugging the container application.

---

## 10. Incident 7 — Nginx Proxy Manager / OpenResty 404

**Layer:** Reverse proxy / Layer 7 routing

### Symptom

Requests through Nginx Proxy Manager returned an OpenResty/Nginx-style `404` instead of the intended backend application.

### Investigation

The troubleshooting path included:

- checking whether backend containers were running;
- checking backend host ports directly;
- checking NPM Proxy Host configuration;
- checking hostname matching.

Earlier drafts attributed the incident to NPM SQLite corruption after storage/disk problems.

### Root-cause confidence

**The exact root cause was not preserved strongly enough to call SQLite corruption confirmed.**

The safe conclusion is that the symptom was consistent with missing/incorrect reverse-proxy host routing state.

### Final verified NPM state

The final live NPM screen showed:

```text
git.lab.local
    -> http://10.10.20.50:3000
    -> Online

nextcloud.lab.local
    -> http://10.10.20.50:8080
    -> Online
```

![NPM proxy hosts](screenshots/08-npm-proxy-hosts.png)

### Important correction

`pihole.lab.local` exists in Pi-hole DNS, but a corresponding NPM Proxy Host was **not present** in the final verified NPM screen.

It is therefore not documented as a verified active NPM mapping.

### Lesson

Test the backend service and the hostname-based proxy route separately before attributing an HTTP error to the application.

---

## 11. Incident 8 — Pi-hole v6 Configuration Differences

**Layer:** Pi-hole / container configuration

### Symptom

Configuration and password-management assumptions from older Pi-hole versions did not directly match Pi-hole v6.

### Cause

Pi-hole v6 uses a revised FTL-centric configuration model.

### Live-history boundary

The exact interactive password-management command used during the original troubleshooting was not preserved with enough confidence to present as a verified historical command.

### Repository reconstruction

The later consolidated Compose file uses:

```yaml
FTLCONF_webserver_api_password: "${PIHOLE_PASSWORD:?PIHOLE_PASSWORD must be defined in .env}"
```

and the reconstructed Docker-network compatibility setting:

```yaml
FTLCONF_dns_listeningMode: 'ALL'
```

The second setting is explicitly a **reconstructed Compose deployment requirement**, not a preserved original live environment value.

### Final verification

Portainer showed Pi-hole in a healthy state with DNS published on port 53.

The final local DNS entries were:

```text
192.168.100.250 nextcloud.lab.local
192.168.100.250 git.lab.local
192.168.100.250 pihole.lab.local
```

### Lesson

Major application versions should be documented against the version actually deployed rather than older examples.

---

# Architecture Corrections Discovered During Final Audit

## 12. Correction 1 — ESXi Is a Core Workload Hypervisor

An early documentation version treated nested ESXi as an evaluation-only environment.

Final evidence showed that ESXi actually hosts three project VMs:

```text
pfSense-Firewall
Ubuntu_Server_01
Windows-Server-AD
```

The architecture documentation was therefore corrected.

### Lesson

Runtime topology should be verified from the hypervisor, not inferred from early design notes.

---

## 13. Correction 2 — TrueNAS Is Not on `10.10.20.0/24`

An earlier draft documented TrueNAS as `10.10.20.x`.

Final verification showed:

```text
TrueNAS: 192.168.100.128
Ubuntu:  10.10.20.50
Gateway: 10.10.20.1
```

The command:

```bash
ip route get 192.168.100.128
```

showed:

```text
192.168.100.128 via 10.10.20.1 dev ens160 src 10.10.20.50
```

Therefore Ubuntu-to-TrueNAS NFS traffic is routed through pfSense.

![Ubuntu NFS routing](screenshots/06-ubuntu-nfs-routing.png)

### Lesson

Do not infer packet paths solely from remembered logical diagrams. Inspect the active routing table.

---

## 14. Correction 3 — Application Directories Are Not Proven ZFS Datasets

Earlier documentation described dedicated datasets for:

```text
nextcloud
gitea
pihole
```

Final TrueNAS and ESXi evidence showed a common NFS datastore with application directories.

The repository now treats these as directories unless an individual ZFS dataset is independently demonstrated.

### Lesson

A directory name inside an export is not automatically a filesystem/dataset boundary.

---

## 15. Correction 4 — Segmentation Is Not 802.1Q VLAN Tagging

pfSense interface names include:

```text
VLAN20_SERVERS
VLAN30_DMZ
VLAN40_CLIENTS
VLAN99_GUEST
```

However, the verified pfSense VLAN configuration table was empty.

The final architecture therefore describes the implementation as:

```text
separate virtual network segments / virtual NICs
```

rather than verified 802.1Q tagging.

### Lesson

Interface labels are not evidence of VLAN encapsulation.

---

## 16. Correction 5 — Active Directory Is Implemented

An earlier repository state listed Active Directory as future scope.

Final PowerShell verification showed:

```text
Active Directory Domain Services: Installed
DNSRoot:       network.lab
NetBIOSName:   NETWORK
DomainMode:    Windows2016Domain
Forest:        network.lab
PDCEmulator:   DC01.network.lab
```

![Active Directory verification](screenshots/10-active-directory-domain.png)

The final documentation now classifies AD DS as implemented.

### Scope boundary

Application authentication integration with AD was not independently verified.

### Lesson

Service installation and service integration are separate claims.

---

## 17. Correction 6 — Final Software/Interface Versions Changed

Final live evidence corrected several early documentation values.

| Earlier documentation | Final verified state |
|---|---|
| pfSense 2.7.x | **pfSense 2.8.1** |
| ESXi 8.0 | **ESXi 7.0.3** |
| Ubuntu 24.04 LTS | **Ubuntu 26.04 LTS** |
| Ubuntu `ens33` | **Ubuntu `ens160`** |
| Workstation 25H2 | **Workstation Pro 26H1** |

### Lesson

Version strings in a portfolio repository should reflect captured live state rather than installation-era assumptions.

---

# Operational Diagnostic Reference

## 18. Virtualization Diagnostics

### ESXi availability

Verify ESXi Host Client is reachable and inspect:

```text
Storage -> NFS_Datastore
```

Expected final state:

```text
Type: NFS
Virtual Machines: 3
```

### Workstation topology

Confirm that Workstation directly hosts:

```text
TrueNAS
ESXi-1
```

and that the ESXi inventory contains the three nested VMs.

---

## 19. pfSense Diagnostics

### Interface state

Use:

```text
Status -> Interfaces
```

Expected gateway addresses:

```text
WAN             192.168.100.250
LAN             10.10.10.1
VLAN20_SERVERS  10.10.20.1
VLAN30_DMZ      10.10.30.1
VLAN40_CLIENTS  10.10.40.1
VLAN99_GUEST    10.10.99.1
```

### NAT state

Use:

```text
Firewall -> NAT -> Port Forward
```

Expected verified forwards:

```text
2222 -> 10.10.20.50:22
80   -> 10.10.20.50:80
443  -> 10.10.20.50:443
81   -> 10.10.20.50:81
9443 -> 10.10.20.50:9443
```

---

## 20. NFS Diagnostics

### Show the actual mounted source

```bash
findmnt -T /mnt/truenas_data -o SOURCE,TARGET,FSTYPE
```

Expected final source:

```text
192.168.100.128:/mnt/ESXi_Pool/NFS_Datastore
```

### Verify route

```bash
ip route get 192.168.100.128
```

Expected path contains:

```text
via 10.10.20.1 dev ens160 src 10.10.20.50
```

### Check mount point

```bash
mountpoint /mnt/truenas_data
```

### Run repository health helper

```bash
sudo ./scripts/nfs-mount-verify.sh
```

The helper performs read-only validation.

---

## 21. Docker and Portainer Diagnostics

The verified live service set contains:

```text
gitea
nextcloud-server-nextcloud-1
nginx-proxy-manager-app-1
pihole
portainer
```

Expected live published ports include:

```text
Gitea:       3000:3000, 2223:22
Nextcloud:   8080:80
NPM:         80:80, 81:81, 443:443
Pi-hole:     53:53, 8053:80
Portainer:   9443:9443, 8000:8000
```

If a service is unavailable:

1. confirm the container state;
2. confirm its published port;
3. test the backend directly;
4. then test NPM hostname routing.

---

## 22. Pi-hole Diagnostics

### Verify local records

The final live generated file was observed at:

```text
/etc/pihole/hosts/custom.list
```

Relevant records:

```text
192.168.100.250 nextcloud.lab.local
192.168.100.250 git.lab.local
192.168.100.250 pihole.lab.local
```

> Pi-hole identifies this path as generated configuration. The repository's `configs/pihole/custom.list` is documentation/sanitized reconstruction, not an instruction to overwrite the generated file.

---

## 23. NPM Diagnostics

Final verified Proxy Hosts:

```text
git.lab.local       -> http://10.10.20.50:3000
nextcloud.lab.local -> http://10.10.20.50:8080
```

Both were shown as Online and HTTP Only.

Troubleshooting sequence:

```text
1. Verify backend container
2. Verify backend host port
3. Verify DNS result
4. Verify NPM Proxy Host
5. Verify Host header/domain
6. Test through pfSense WAN :80
```

---

## 24. Active Directory Diagnostics

Useful read-only verification commands:

```powershell
Get-WindowsFeature AD-Domain-Services |
    Select-Object DisplayName, InstallState
```

and:

```powershell
Get-ADDomain |
    Select-Object DNSRoot, NetBIOSName, DomainMode, Forest, PDCEmulator
```

Verified final values:

```text
AD DS:       Installed
DNSRoot:     network.lab
NetBIOSName: NETWORK
Forest:      network.lab
PDCEmulator: DC01.network.lab
```

---

# Startup / Recovery Runbook

## 25. Cold Start Sequence

Use this dependency-aware order:

```text
1. Boot Windows host
2. Start VMware Workstation
3. Start TrueNAS
4. Wait for TrueNAS storage/NFS readiness
5. Start nested ESXi
6. Confirm NFS_Datastore is available
7. Start pfSense
8. Start Windows Server AD
9. Start Ubuntu
10. Verify /mnt/truenas_data
11. Verify Docker / Portainer
12. Verify Pi-hole and NPM
13. Verify Nextcloud and Gitea
```

### Why TrueNAS comes first

ESXi-hosted VM disks reside on the TrueNAS-backed NFS datastore.

### Why pfSense precedes Ubuntu application operation

Ubuntu's verified route to TrueNAS is:

```text
10.10.20.50
-> 10.10.20.1
-> 192.168.100.128
```

so pfSense is required for the Ubuntu NFS client path.

---

## 26. Controlled Shutdown Sequence

Recommended order:

```text
1. Stop application activity / containers as appropriate
2. Shut down Ubuntu
3. Shut down Windows Server
4. Halt pfSense
5. Shut down nested ESXi
6. Shut down TrueNAS last
7. Close VMware Workstation
```

TrueNAS should remain available until its datastore consumers have stopped.

---

# Repository Artifact Safety

## 27. Files That Must Not Be Committed

Do not commit:

```text
.env
private keys
passwords
tokens
raw pfSense config.xml
live SQLite databases
VM disks
ISO images
VM snapshots
TrueNAS credential-bearing backups
```

The repository intentionally uses sanitized summaries and reconstructed templates instead.

---

## 28. Reconstruction Labels

These files should retain explicit reconstruction disclaimers:

```text
compose/docker-compose.yml
configs/netplan/50-cloud-init.yaml
configs/systemd/resolved.conf
configs/pihole/custom.list
configs/pfsense/nat-rules-summary.csv
scripts/lvm-online-extend.sh
scripts/nfs-mount-verify.sh
```

The goal is reproducibility without rewriting history.

---

## 29. Core Engineering Lessons

1. **Verify the lowest layer first.**
2. **A healthy container does not prove storage, DNS, or routing is correct.**
3. **A mounted filesystem does not prove write permissions are correct.**
4. **An interface named VLAN does not prove 802.1Q tagging.**
5. **Version-specific application configuration matters.**
6. **Central storage changes the entire boot dependency graph.**
7. **Live command output should override remembered topology.**
8. **Separate observed facts from reconstructed artifacts.**
9. **Avoid overly specific root-cause claims when evidence is incomplete.**
10. **Document corrections as part of the engineering process rather than hiding them.**

---

## 30. Related Files

- [`../README.md`](../README.md)
- [`architecture-deep-dive.md`](architecture-deep-dive.md)
- [`storage-and-zfs-design.md`](storage-and-zfs-design.md)
- [`../configs/pfsense/nat-rules-summary.csv`](../configs/pfsense/nat-rules-summary.csv)
- [`../configs/systemd/resolved.conf`](../configs/systemd/resolved.conf)
- [`../compose/docker-compose.yml`](../compose/docker-compose.yml)
- [`../scripts/lvm-online-extend.sh`](../scripts/lvm-online-extend.sh)
- [`../scripts/nfs-mount-verify.sh`](../scripts/nfs-mount-verify.sh)

---

## 31. Final Scope Boundary

This runbook documents the failures and corrections supported by the preserved project evidence.

It does not claim that:

- every historical command was captured;
- every incident root cause was proven with logs or packet captures;
- the lab is production-ready;
- the lab provides HA or automatic recovery;
- every `.lab.local` hostname has an NPM route;
- AD authentication is integrated into every application;
- 802.1Q VLAN tagging is implemented.
