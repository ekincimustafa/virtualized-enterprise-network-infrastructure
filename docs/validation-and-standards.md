# Validation, Testing, and Standards Notes

---

## 1. Purpose

This document summarizes the validation methods, engineering protocols/standards, configuration checks, and implementation boundaries associated with the **Virtualized Enterprise Network Infrastructure** homelab.

It was created as a **post-implementation documentation artifact** after the final live architecture had been verified. It is not presented as a contemporaneous test plan that was followed line-by-line during the original internship build.

The goal is to make three things explicit:

1. how the final infrastructure state was validated;
2. which networking/system standards and protocols were used or studied;
3. which capabilities were **not** implemented or independently tested.

---

## 2. Validation Strategy

The final audit used an evidence-driven, layer-by-layer validation approach:

```text
Physical / Virtualization Layer
        |
        v
Network Interfaces and Routing
        |
        v
Firewall / NAT
        |
        v
Storage / NFS
        |
        v
Operating System
        |
        v
Docker / Containers
        |
        v
DNS / Reverse Proxy
        |
        v
Directory Services
```

The main principle was:

> Verify the live runtime state first, then align documentation and reconstructed configuration artifacts with that evidence.

This prevented older design assumptions from being carried into the final repository.

---

## 3. Final Validation Matrix

| Area | Validation Method | Expected / Verified Result | Evidence |
|---|---|---|---|
| Workstation topology | VMware Workstation inventory inspection | TrueNAS and nested ESXi are direct Workstation VMs | `screenshots/01-vmware-lab-overview.png` |
| Nested ESXi workloads | ESXi / Workstation inventory inspection | pfSense, Ubuntu, and Windows Server AD run under ESXi | `screenshots/01-vmware-lab-overview.png` |
| pfSense interface state | pfSense console / interface inspection | WAN, LAN, Servers, DMZ, Clients, and Guest interfaces are assigned and up | `screenshots/02-pfsense-network-segments.png` |
| pfSense DNAT | Firewall → NAT → Port Forward | Five verified WAN-to-Ubuntu forwarding rules | `screenshots/03-pfsense-nat-rules.png` |
| TrueNAS storage services | TrueNAS Shares view | NFS, SMB, and iSCSI services running | `screenshots/04-truenas-storage-services.png` |
| ESXi datastore | ESXi Storage view | `NFS_Datastore`, type NFS, associated with 3 VMs | `screenshots/05-esxi-nfs-datastore.png` |
| Ubuntu NFS mount | `findmnt -T /mnt/truenas_data -o SOURCE,TARGET,FSTYPE` | TrueNAS export mounted at `/mnt/truenas_data` as NFS | `screenshots/06-ubuntu-nfs-routing.png` |
| Ubuntu → TrueNAS route | `ip route get 192.168.100.128` | Route uses gateway `10.10.20.1`, interface `ens160`, source `10.10.20.50` | `screenshots/06-ubuntu-nfs-routing.png` |
| Container runtime | Portainer container list | Gitea, Nextcloud, NPM, Pi-hole, and Portainer running/healthy | `screenshots/07-portainer-containers.png` |
| Reverse proxy | NPM Proxy Hosts | `git.lab.local` and `nextcloud.lab.local` online | `screenshots/08-npm-proxy-hosts.png` |
| Local DNS | Pi-hole generated local hosts list | Three `.lab.local` records resolve to pfSense WAN address | `screenshots/09-pihole-local-dns.png` |
| Active Directory | PowerShell `Get-WindowsFeature` / `Get-ADDomain` | AD DS installed; domain `network.lab` operational | `screenshots/10-active-directory-domain.png` |

---

## 4. Validation Commands

### 4.1 NFS mount source

```bash
findmnt -T /mnt/truenas_data -o SOURCE,TARGET,FSTYPE
```

Verified final relationship:

```text
192.168.100.128:/mnt/ESXi_Pool/NFS_Datastore
    -> /mnt/truenas_data
    -> nfs4
```

### 4.2 Route to TrueNAS

```bash
ip route get 192.168.100.128
```

Verified path:

```text
192.168.100.128 via 10.10.20.1 dev ens160 src 10.10.20.50
```

### 4.3 Active Directory

```powershell
Get-WindowsFeature AD-Domain-Services |
    Select-Object DisplayName, InstallState
```

```powershell
Get-ADDomain |
    Select-Object DNSRoot, NetBIOSName, DomainMode, Forest, PDCEmulator
```

Verified domain information:

```text
DNSRoot:       network.lab
NetBIOSName:   NETWORK
DomainMode:    Windows2016Domain
Forest:        network.lab
PDCEmulator:   DC01.network.lab
```

---

## 5. Functional Testing Approach

The project did not use a dedicated automated infrastructure test framework.

Instead, validation relied on targeted functional checks appropriate to each layer.

### 5.1 Connectivity and routing

Routing decisions were checked using the operating-system routing table and effective-route commands.

Example:

```bash
ip route get 192.168.100.128
```

This was more reliable than assuming a path based only on the intended network diagram.

### 5.2 Storage availability

Storage validation separated:

1. whether the mount point existed;
2. whether it was actively mounted;
3. whether it was an NFS filesystem;
4. whether the source export was correct;
5. whether the mounted directory was readable.

The later-created helper:

```text
scripts/nfs-mount-verify.sh
```

reconstructs these checks in a read-only form.

### 5.3 Service availability

Container state and published ports were reviewed in Portainer.

Application routing was checked separately from backend service state. This distinction was important during reverse-proxy troubleshooting because a healthy backend does not guarantee a correct NPM host mapping.

### 5.4 Configuration-state verification

For infrastructure components such as pfSense, TrueNAS, NPM, and Pi-hole, GUI/CLI state was captured directly rather than relying only on reconstructed configuration templates.

---

## 6. Protocols and Standards Used or Observed

The following protocols and standards are relevant to the implemented architecture.

| Standard / Protocol | Relevance to the Project | Implementation Status |
|---|---|---|
| RFC 1918 private IPv4 addressing | Private `10.10.x.0/24` and `192.168.100.0/24` lab networks | Implemented |
| IPv4 routing and subnetting | Routed separation between internal server zones and host-side network | Implemented |
| TCP / UDP | Transport for web, SSH, DNS, and infrastructure services | Implemented |
| DNS | Local hostname resolution through Pi-hole | Implemented |
| HTTP | NPM host-based routing to Gitea and Nextcloud | Implemented |
| HTTPS port forwarding | pfSense DNAT path to NPM port 443 | Implemented as network path |
| NFSv4 | Shared network filesystem between TrueNAS, ESXi, and Ubuntu | Implemented |
| SSH | Administrative access to Ubuntu through DNAT | Implemented |
| SMB | TrueNAS Windows file-sharing service | Implemented / observed |
| iSCSI | TrueNAS block-storage target service | Implemented / observed |
| Active Directory Domain Services | `network.lab` directory domain | Implemented |
| IEEE 802.1Q VLAN terminology | Considered when designing segmented network zones | **Not implemented as VLAN tagging** |

---

## 7. IEEE 802.1Q Clarification

The pfSense interfaces use labels such as:

```text
VLAN20_SERVERS
VLAN30_DMZ
VLAN40_CLIENTS
VLAN99_GUEST
```

However, the final pfSense VLAN configuration table was empty.

Therefore the final implementation uses:

```text
separate VMware / ESXi virtual network segments
+ separate pfSense virtual NICs
```

rather than an IEEE 802.1Q tagged trunk.

The VLAN-style numbering remains useful as a logical naming convention, but the repository does not claim that VLAN tagging was implemented.

---

## 8. Configuration and Maintenance Activities

Verified or preserved configuration/maintenance tasks include:

- assigning pfSense network interfaces and gateway addresses;
- defining pfSense DNAT/port-forward rules;
- moving the pfSense WebConfigurator from port 443 to 8443;
- adjusting private-WAN filtering for an RFC1918 lab WAN;
- configuring TrueNAS NFS export permissions and Maproot;
- mounting the TrueNAS NFS export on Ubuntu;
- expanding the Ubuntu LVM root filesystem online;
- disabling the `systemd-resolved` DNS stub listener to free port 53;
- deploying and managing containerized services through Portainer;
- configuring Pi-hole local DNS entries;
- configuring Nginx Proxy Manager host mappings;
- installing and validating Windows Server Active Directory Domain Services.

---

## 9. Design and Troubleshooting Method

The project used an iterative engineering method rather than a formal software-development methodology.

Typical cycle:

```text
Define requirement
    |
    v
Design one infrastructure layer
    |
    v
Configure / deploy
    |
    v
Observe runtime behavior
    |
    v
Isolate the failing layer
    |
    v
Change one configuration variable
    |
    v
Re-test
    |
    v
Document the verified result
```

This approach was particularly useful for failures that crossed multiple layers, such as:

- Docker service failure caused by Ubuntu filesystem exhaustion;
- container write failure caused by NFS identity mapping;
- Pi-hole startup failure caused by host port 53 ownership;
- reverse-proxy failure caused by host-routing/proxy configuration;
- NFS availability depending on both storage and routing.

---

## 10. Repository and Change Documentation

Git/GitHub was used for the **post-implementation documentation and portfolio repository**.

The repository records:

- architecture documentation;
- implementation evidence screenshots;
- sanitized configuration summaries;
- reconstructed helper scripts;
- reconstructed Compose and network templates;
- troubleshooting history.

This should not be interpreted as evidence that Git-based change management was used for every configuration change during the original internship implementation.

---

## 11. Validation Boundaries — Not Implemented or Not Independently Verified

The following items should not be described as completed features.

| Capability | Final Status |
|---|---|
| IEEE 802.1Q VLAN trunking/tagging | Not implemented |
| High availability / automatic failover | Not implemented |
| Multiple physical storage-node redundancy | Not implemented |
| Public TLS certificates for `.lab.local` services | Not implemented |
| Verified NPM Proxy Host for `pihole.lab.local` | Not present in final verified state |
| Gitea / Nextcloud authentication through Active Directory | Not independently verified |
| Ubuntu domain join | Not independently verified |
| Automated disaster-recovery restore test | Not performed |
| Formal load/stress benchmark | Not performed |
| Automated end-to-end infrastructure test suite | Not implemented |
| Zero-downtime operation | Not claimed |

These limitations are useful engineering findings because they identify clear future extensions without overstating the current project.

---

## 12. Possible Future Validation Work

If the lab is extended later, useful next steps would include:

1. implement real IEEE 802.1Q VLAN tagging and trunking;
2. add explicit inter-zone firewall policies and test cases;
3. integrate selected applications with Active Directory/LDAP;
4. implement internal TLS using an appropriate private certificate authority;
5. add automated service-health and configuration validation;
6. perform backup-and-restore tests;
7. benchmark storage and network performance;
8. test recovery from TrueNAS, pfSense, and Ubuntu service failures.

These are **future improvements**, not claims about the completed implementation.

---

## 13. Engineering Lessons

1. Live runtime evidence should override early architecture assumptions.
2. Naming a network interface `VLAN` is not equivalent to implementing 802.1Q.
3. Routing must be verified from actual route tables.
4. Storage availability, mount status, and write permissions are separate validation problems.
5. Application availability should be tested independently from reverse-proxy routing.
6. Infrastructure startup order matters when centralized storage is used.
7. Version-specific configuration changes can invalidate older deployment guidance.
8. A professional report should clearly separate implemented work, reconstructed documentation, and future improvements.

---

## 14. Related Documentation

- [`../README.md`](../README.md)
- [`architecture-deep-dive.md`](architecture-deep-dive.md)
- [`storage-and-zfs-design.md`](storage-and-zfs-design.md)
- [`troubleshooting-runbook.md`](troubleshooting-runbook.md)
- [`../configs/pfsense/nat-rules-summary.csv`](../configs/pfsense/nat-rules-summary.csv)
- [`../scripts/nfs-mount-verify.sh`](../scripts/nfs-mount-verify.sh)

---

## 15. Scope Note

This document supports the technical reporting of testing methods, standards/protocols, configuration tasks, and engineering validation.

It does not convert unperformed work into completed work. Statements marked as not implemented, not verified, reconstructed, or future work should remain classified that way in the internship report.
