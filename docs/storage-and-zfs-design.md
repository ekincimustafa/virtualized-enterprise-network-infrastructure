# Storage and ZFS Design: Decoupled Network Storage Fabric

---

## 1. Purpose and Storage Requirements

In traditional homelab and server environments, persistent application state is commonly written directly to the local virtual disk of the compute virtual machine. While straightforward, this tightly couples the lifecycle of the application runtime to the virtual machine itself. If the compute operating system requires a reinstallation, experiences a kernel panic, or suffers filesystem corruption, persistent databases, configuration files, and user uploads are placed at immediate risk.

The storage architecture of this project was designed to address this problem by separating application execution from persistent data storage:
* **Compute Tier:** The Ubuntu Server compute node hosts container runtimes, system logs, and temporary OS files, but offloads persistent business state. While the compute node is not completely stateless—retaining its base operating system, network configuration, and container images—it retains minimal critical application state.
* **Centralized Storage:** Databases, Git repositories, and cloud uploads are directed to an independent virtual storage appliance running **TrueNAS SCALE** and managed by **OpenZFS**.
* **Protocol Abstraction:** Storage is exported over the internal network using **NFSv4**, allowing compute nodes to interact with remote storage via standard POSIX filesystem operations.

> **Engineering Note:** This architecture models enterprise data center separation patterns within the boundaries of a single physical machine. It is not presented as an enterprise-grade high-availability system; rather, it provides a controlled demonstration of compute/storage decoupling under strict hardware constraints.

---

## 2. Storage Architecture Overview

The end-to-end storage pipeline spans multiple abstraction layers, from the underlying virtual disk allocated in VMware to the application processes running inside Docker containers:

```
+-----------------------------------------------------------------------------+
|                          TRUENAS SCALE STORAGE NODE                         |
|                                 (10.10.20.x)                                |
+-----------------------------------------------------------------------------+
|  OpenZFS Storage Layer                                                      |
|   └── Storage Pool (zpool)                                                  |
|         ├── Native lz4 Compression                                          |
|         ├── Transactional Copy-on-Write (CoW) Semantics                     |
|         └── Application Datasets (/nextcloud, /gitea, /pihole)              |
|                                                                             |
|  NFSv4 Service                                           |
|   ├── Listening: TCP Port 2049                                              |
|   ├── Export Subnet: 10.10.20.0/24                                          |
|   └── Maproot Configuration: root:root                                      |
+-----------------------------------------------------------------------------+
                                       │
                                       │ NFSv4 Protocol (TCP 2049)
                                       │ Same-subnet VMware virtual network communication
                                       ▼
+-----------------------------------------------------------------------------+
|                     UBUNTU SERVER 24.04 LTS COMPUTE NODE                    |
|                                (10.10.20.50)                                |
+-----------------------------------------------------------------------------+
|  Linux Kernel VFS / NFS Client (nfs.ko)                                     |
|   └── Persistent Mount Point: /mnt/truenas_data (/etc/fstab with _netdev)   |
|                                                                             |
|  Docker Engine Runtime (Container Host Bind Mounts)                         |
|   ├── Nextcloud Container ────> /mnt/truenas_data/nextcloud/data            |
|   ├── Gitea Container ────────> /mnt/truenas_data/gitea                     |
|   ├── Pi-hole Container ──────> /mnt/truenas_data/pihole/etc-pihole         |
|   └── NPM (Reconstructed) ────> /mnt/truenas_data/npm/...                   |
+-----------------------------------------------------------------------------+
```

---

## 3. Why TrueNAS Was Separated from Compute

In Linux environments, OpenZFS can be installed natively on Ubuntu (`zfsutils-linux`), allowing storage pools to run directly on the compute host without an additional virtual machine. A separate storage VM was chosen as an architectural separation-of-concerns decision rather than as a technical requirement of OpenZFS.

However, TrueNAS SCALE was provisioned as an independent virtual appliance based on the **Separation of Concerns** principle:

1. **Independent System Lifecycles:**  
   The compute node undergoes frequent software modifications: kernel updates, container runtime upgrades, dependency installations, and exploratory testing. If a package conflict or misconfiguration compromises Ubuntu, the storage appliance remains unaffected.
2. **Dedicated Storage Resource Management:**  
   OpenZFS relies heavily on system memory for its caching subsystem (Adaptive Replacement Cache - ARC). Running storage and container workloads in separate VMs creates an explicit resource boundary that can be sized and managed independently. This does not eliminate contention on the physical host, but it makes the division between compute and storage resources clearer.
3. **Enterprise Architecture Modeling:**  
   In production data centers, compute clusters (e.g., hypervisor clusters, worker nodes) do not manage physical storage arrays directly. They consume shared block (SAN) or file (NAS) storage fabrics. Isolating TrueNAS reproduces this architectural boundary.

---

## 4. OpenZFS Role

OpenZFS provides the storage pool and filesystem layer on TrueNAS SCALE. Some capabilities below are inherent OpenZFS behavior, while only settings explicitly documented as verified should be interpreted as lab-specific configuration.

### 4.1 Storage Pool (`zpool`) Abstraction
OpenZFS abstracts virtual disks into a unified storage pool (`zpool`). Rather than formatting traditional partitions with fixed boundaries, the pool serves as a dynamic allocation space from which logical datasets draw storage on demand.

### 4.2 Granular Dataset Segmentation
Within the storage pool, isolated datasets were created for distinct application workloads. Datasets behave like dedicated filesystems, allowing independent configuration of compression, access permissions, and export policies without requiring partition resizing.

### 4.3 Copy-on-Write (CoW) Semantics
Traditional filesystems (such as ext4 without special journaling modes) overwrite data in-place. An unexpected power failure or hypervisor shutdown during a write operation can leave blocks partially written, causing metadata corruption.
* OpenZFS enforces Copy-on-Write: when data is modified, the new data is written to unallocated blocks. Only after the write is confirmed do metadata pointers update to reference the new block.
* *Limitation Note:* While CoW protects filesystem metadata consistency during sudden outages, it does not prevent application-level data corruption if a database container crashes mid-transaction.

### 4.4 Block-Level Checksumming
OpenZFS stores checksums for data and metadata and verifies them during normal I/O. The exact checksum algorithm was not separately recorded for this lab.
* *Important Architectural Distinction:* In multi-disk mirrored or RAIDZ pools, OpenZFS uses parity data to automatically self-heal corrupted blocks. In this homelab, because storage is backed by a single virtual disk, OpenZFS can **detect** bitrot, but it cannot automatically repair corrupted data blocks due to the lack of redundant parity.

### 4.5 Inline `lz4` Compression
The documented datasets used native `lz4` compression. `lz4` is commonly chosen for fast compression and decompression with relatively low CPU overhead; actual performance and space savings depend on workload characteristics.

---

## 5. Dataset and Persistent Data Organization

Storage is structured around application-oriented datasets on TrueNAS SCALE, mounted under `/mnt/truenas_data` on the compute node:

| Service | Persistent Data Role | Ubuntu Host Path | Storage Backend | Implementation Status |
| :--- | :--- | :--- | :--- | :---: |
| **Nextcloud** | File uploads, user profiles, internal app data | `/mnt/truenas_data/nextcloud/data` | TrueNAS SCALE ZFS Dataset | ✅ Verified Live |
| **Gitea** | Git repositories, user metadata, SQLite database | `/mnt/truenas_data/gitea` | TrueNAS SCALE ZFS Dataset | ✅ Verified Live |
| **Pi-hole** | DNS blocklists, custom A records (`custom.list`), FTL db | `/mnt/truenas_data/pihole/etc-pihole` | TrueNAS SCALE ZFS Dataset | ✅ Verified Live |
| **Nginx Proxy Manager** | Proxy host configurations and runtime certificates | `/mnt/truenas_data/npm/data`<br>`/mnt/truenas_data/npm/letsencrypt` | Reconstructed Compose path | 🔄 Reconstructed Artifact |

> **Verification Boundary:** In the live lab, dedicated datasets were verified for Nextcloud, Gitea, and Pi-hole. The paths for Nginx Proxy Manager are included in the declarative [compose/docker-compose.yml](../compose/docker-compose.yml) template to enable complete stack reproducibility, but an independently isolated ZFS dataset for NPM was not permanently logged in the live environment. Underlying physical disk designations, pool names, and dataset quotas were intentionally not frozen.

---

## 6. NFSv4 Architecture

Persistent network sharing between TrueNAS SCALE and Ubuntu Server relies on **NFSv4** (Network File System version 4):

* **Client/Server Model:** TrueNAS provides the NFS service, while Ubuntu acts as the NFS client and mounts the exported storage through the Linux NFS client stack.
* **Port Consolidation (TCP Port 2049):** Unlike NFSv3, which required multiple auxiliary services (`rpcbind`, `statd`, `lockd`) operating across dynamically assigned high-numbered UDP/TCP ports, the documented NFSv4 service in this lab uses **TCP port 2049**, which simplifies the primary storage service path compared with older multi-service RPC layouts.
* **Stateful Sessions:** NFSv4 maintains stateful client-server sessions, tracking file open/close states and locks directly within the protocol.

### Network Path and Routing Clarification
Both Ubuntu (`10.10.20.50`) and TrueNAS SCALE (`10.10.20.x`) reside within the same internal virtual subnet: `10.10.20.0/24`.
* **Same-Subnet Communication:** Communication between the compute node and storage node occurs directly across the VMware virtual switch (VMnet).
* **No Firewall Traversal:** Because traffic remains within the local broadcast domain, NFS packets do not require pfSense Layer 3 forwarding because the endpoints share the same subnet. pfSense remains relevant for the lab's routed ingress and default-gateway functions.

---

## 7. Persistent Mounting with `/etc/fstab`

To ensure storage persistence across compute node reboots, the remote NFS export is declared in `/etc/fstab` on Ubuntu Server:

```text
# ==============================================================================
# SANITIZED STORAGE MOUNT CONFIGURATION (/etc/fstab)
# Note: Target IP 10.10.20.x represents the verified TrueNAS internal LAN address.
# ==============================================================================
10.10.20.x:/mnt/truenas_pool/data  /mnt/truenas_data  nfs  defaults,_netdev  0  0
```

### The Role and Limitations of `_netdev`
The `_netdev` mount option is useful for declaring that a filesystem depends on network availability:
* **Systemd Integration:** In modern Linux distributions managed by systemd, local filesystems are mounted early in the boot process before network interfaces are brought up. Without `_netdev`, systemd attempts to mount the remote NFS share immediately, causing boot timeouts or halting the system into emergency recovery mode.
* **Dependency Ordering:** The `_netdev` directive flags the mount as network-dependent, instructing systemd to defer mounting until `network-online.target` is reached.
* **Important Operational Nuance:** `_netdev` helps order the mount relative to network availability, but it does **not** guarantee that the remote TrueNAS service is already ready or that the NFS export is reachable when the mount is attempted.

Operational validation of this mount is encapsulated in the read-only diagnostic script [scripts/nfs-mount-verify.sh](../scripts/nfs-mount-verify.sh).

---

## 8. Docker Bind Mount Integration

The compute instance executes microservices inside Docker containers while mounting persistent directories directly from the host filesystem. It is important to clarify that this architecture uses **standard Linux host bind mounts**, rather than specialized third-party Docker volume plugins:

```
[ Container Process (e.g., Gitea) ]
             │
             │ Writes to container path: /data
             ▼
[ Container Mount Namespace (VFS) ]
             │
             │ Mapped via Compose volume declaration
             ▼
[ Ubuntu Host Filesystem Path: /mnt/truenas_data/gitea ]
             │
             │ Intercepted by Linux Kernel NFS Client (nfs.ko)
             ▼
[ Network Protocol RPC Call (NFSv4 over TCP 2049) ]
             │
             │ Transmitted directly across internal 10.10.20.0/24 subnet
             ▼
[ TrueNAS SCALE OpenZFS Dataset: /gitea ]
```

### 8.1 Docker Abstraction Layer
From Docker's perspective, `/mnt/truenas_data/...` is a host path that can be bind-mounted into a container. When the NFS mount is active, those paths belong to the mounted NFS filesystem rather than Ubuntu's local ext4 root filesystem. Docker itself does not establish or manage the NFS session in this design:
* The mounting and unmounting lifecycle is managed entirely by Ubuntu's kernel and `/etc/fstab`.
* Application definitions in [compose/docker-compose.yml](../compose/docker-compose.yml) declare host paths (e.g., `/mnt/truenas_data/nextcloud/data:/var/www/html/data`), allowing the container runtime to remain agnostic of the underlying storage hardware.

---

## 9. NFS Permission Incident: UID Squashing and Maproot Remediation

During the initial deployment of database-backed containers (Nextcloud and Gitea), services crashed repeatedly upon startup, failing to create database locks, temporary directories, or session tables:
`Permission Denied (errno 13): cannot write to /var/www/html/data`

### 9.1 Root Cause Analysis: NFS Root Mapping
The verified problem was a permission mismatch when containerized services attempted to write through the NFS-backed mount. Container entrypoints can perform setup operations with elevated privileges, while NFS commonly restricts or remaps client UID 0 so remote root does not automatically receive unrestricted server-side root privileges. In this lab, that identity mismatch prevented required write or ownership operations.

### 9.2 Technical Remediation: TrueNAS Maproot Configuration
To enable container initialization without breaking POSIX permission hierarchies, the NFS export configuration on TrueNAS SCALE was modified to explicitly override root squashing:
* **Maproot User:** `root`
* **Maproot Group:** `root`

This configuration instructs the TrueNAS NFS daemon to treat incoming client requests from UID 0 as legitimate administrative operations, allowing container entrypoint scripts to configure internal directory ownership cleanly.

### 9.3 Security Trade-off Analysis
* **Risk:** Mapping client root to server root increases the impact of a compromised or misconfigured NFS client because root-originated operations can receive elevated privileges on the export.
* **Lab Justification:** The Ubuntu compute node was the intended application-side NFS client. Maproot was accepted as a lab-specific compatibility trade-off to resolve the observed permission problem.
* **General Hardening Options (Not Implemented Here):** A production-oriented design could use more restrictive identity mapping, per-application exports, aligned UIDs/GIDs, or suitable ACLs. These alternatives were not implemented in this lab.

---

## 10. Storage Availability and Boot Dependencies

In a decoupled architecture, compute instances depend on storage reachability. Because services communicate across the internal virtual network, specific operational sequencing is required:

```
[ Power On: TrueNAS SCALE Storage Appliance ]
                     │
                     ▼ (Storage pool and NFS service become available)
[ Power On: Ubuntu Server Compute Node ]
                     │
                     ▼ (Netplan Binds 10.10.20.50 & fstab Attaches /mnt/truenas_data)
[ Start Docker Engine & Microservice Containers ]
                     │
                     ▼ (Containers Safely Bind to Active Remote Storage)
[ Normal System Operation ]
```

### 10.1 Direct Layer 2 Operational Path
As established in [docs/architecture-deep-dive.md](architecture-deep-dive.md), both Ubuntu (`10.10.20.50`) and TrueNAS (`10.10.20.x`) reside on the same isolated subnet (`10.10.20.0/24`).
* **Independence from Firewall Routing:** NFS packets travel directly across the virtual switch. If the pfSense firewall appliance is temporarily halted, internal NFS traffic between Ubuntu and TrueNAS continues uninterrupted.
* **External Ingress Dependency:** pfSense is required solely for host-to-ingress routing (DNAT) and client internet access; it does not mediate storage I/O.

### 10.2 The Missing Mount Race Condition
If the Ubuntu compute node powers on and starts the Docker daemon while the TrueNAS virtual machine is still booting:
1. Docker evaluates the host path declared in the compose file (`/mnt/truenas_data/nextcloud/data`).
2. Finding that `/mnt/truenas_data` is an empty, unmounted directory on Ubuntu's local ext4 root volume, Docker will automatically create the subdirectories on the **local virtual disk**.
3. When the TrueNAS NFS mount eventually attaches seconds later, it overlays itself on top of `/mnt/truenas_data`. The local directories created by Docker become **shadowed** (hidden beneath the mount point), leading to container I/O errors and state inconsistencies.

To verify mount readiness before starting workloads, the diagnostic helper [scripts/nfs-mount-verify.sh](../scripts/nfs-mount-verify.sh) was created to check mount status and directory readability.

---

## 11. Failure Scenarios and Edge Cases

A realistic engineering review requires analyzing how the storage subsystem behaves during common operational faults:

### 11.1 TrueNAS VM Unavailability
* **Failure Mode:** TrueNAS SCALE is shut down or experiences a kernel panic while containers on Ubuntu are running.
* **Behavior:** Applications that depend on the NFS-backed paths can block, fail I/O operations, or become unavailable while the remote storage service is unreachable. Administrative commands that traverse the mount may also block depending on the active NFS mount options and timeout behavior.
* **Recovery:** Restore TrueNAS/NFS availability first, then verify the mount and application state. Automatic recovery behavior depends on mount options and failure duration, so successful recovery should be verified rather than assumed.

### 11.2 Host-Level Storage Exhaustion
* **Failure Mode:** The physical host's 512 GB NVMe SSD runs out of free space.
* **Behavior:** Virtual-disk growth, logging, and application writes may fail or become unstable if the host filesystem runs critically low on free space; exact VMware Workstation behavior depends on the situation and should not be assumed to be an automatic safe suspension.
* **Mitigation:** Allocating thin-provisioned virtual disks requires proactive monitoring of the physical host drive.

### 11.3 Lack of Physical Redundancy (Single Disk Backing)
* **Failure Mode:** Underlying physical sector degradation or NVMe SSD hardware failure.
* **Behavior:** While OpenZFS includes checksumming to identify corrupted blocks, **it cannot repair data** when backed by a single virtual drive without mirror or RAIDZ parity. Checksum verification will log read errors in `zpool status`, but the affected data blocks will be lost.

---

## 12. Security Considerations

The storage design limits exposure by keeping NFS on the internal server network and by avoiding a pfSense WAN port-forward for NFS. Repository hygiene is used separately to avoid publishing sensitive runtime artifacts.

1. **Subnet-Restricted Exports:**  
   The NFS data path is designed for the internal `10.10.20.0/24` server segment between Ubuntu and TrueNAS. The exact TrueNAS export ACL/subnet restriction is not asserted here unless separately verified from the live appliance.
2. **Perimeter Isolation:**  
   TCP port `2049` does not appear in the verified pfSense DNAT summary ([configs/pfsense/nat-rules-summary.csv](../configs/pfsense/nat-rules-summary.csv)); this repository therefore documents no WAN-side NFS port-forward.
3. **Repository Sanitization:**  
   To prevent leaking live infrastructure artifacts, secrets, VM disk images, database files, and other runtime artifacts are excluded according to [.gitignore](../.gitignore). Raw TrueNAS backups and live storage data are intentionally not committed.

---

## 13. Verified vs. General OpenZFS Features

To preserve strict technical accuracy, the table below distinguishes between OpenZFS features verified during this project and enterprise ZFS capabilities that were not implemented:

| OpenZFS Feature | Lab Implementation Status | Technical Context & Justification |
| :--- | :---: | :--- |
| **Unified Storage Pool (`zpool`)** | ✅ Verified Live | Basic virtual disk abstraction on TrueNAS SCALE. |
| **Granular Datasets** | ✅ Verified Live | Independent datasets allocated for application data (`/nextcloud`, `/gitea`, `/pihole`). |
| **Native `lz4` Compression** | ✅ Verified Live | Documented as enabled for the verified application datasets; actual benefit depends on workload. |
| **NFSv4 Network Sharing** | ✅ Verified Live | Centralized storage export listening on TCP port 2049. |
| **Maproot UID Translation** | ✅ Verified Live | Reconfigured to `root:root` to resolve container permission conflicts. |
| **Copy-on-Write (CoW)** | ℹ️ Inherent OpenZFS Capability | Fundamental filesystem architecture; active by default. |
| **Block Checksumming (Detection)** | ℹ️ Inherent OpenZFS Capability | Active on all blocks; detects data corruption upon read operations. |
| **Automated Self-Healing / Repair** | ❌ Not Implemented | Requires multi-disk redundancy (Mirror/RAIDZ) to reconstruct bad blocks. |
| **ZFS Snapshots & Rollbacks** | ❌ Not Implemented / Not Verified | Supported natively by ZFS, but automated snapshot schedules were not deployed. |
| **ZFS Send / Receive Replication**| ❌ Not Implemented | Off-site replication was not configured due to single-node scope. |
| **RAIDZ / Mirroring** | ❌ Not Implemented | Pool backed by a single virtual disk due to hardware limits. |
| **L2ARC (SSD Read Cache)** | ❌ Not Implemented / Not Verified | Unnecessary overhead for a lightweight virtualized homelab. |
| **Dedicated SLOG (ZFS Intent Log)**| ❌ Not Implemented | Synchronous writes were handled directly within the main pool. |
| **Native Dataset Encryption** | ❌ Not Implemented / Not Verified | Datasets were unencrypted to conserve compute and memory resources. |
| **Block Deduplication** | ❌ Not Implemented / Not Verified | Excluded; deduplication is not documented as part of the verified configuration. |

---

## 14. Design Limitations

A rigorous engineering assessment requires acknowledging the architectural constraints of this homelab environment:

* **Single Bare-Metal Host (Single Point of Failure):**  
  TrueNAS, Ubuntu, pfSense, and VMware all execute on a single physical laptop (HP Victus 16). Hardware maintenance, driver crashes, or power loss takes down both compute and storage simultaneously.
* **Virtualization Layer Overhead:**  
  Running TrueNAS SCALE inside a Type-2 hypervisor (VMware Workstation Pro) means storage I/O passes through multiple abstraction layers: Guest Application $\rightarrow$ Guest NFS Client $\rightarrow$ Hypervisor Virtual Switch $\rightarrow$ Guest Storage OS $\rightarrow$ Virtual SCSI Controller $\rightarrow$ Host OS VFS $\rightarrow$ Physical NVMe Driver. This introduces latency compared to bare-metal storage arrays.
* **Non-ECC Memory Environment:**  
  Consumer laptops lack Error-Correcting Code (ECC) RAM. While OpenZFS safely handles data integrity on disk, memory bitflips can theoretically corrupt data before it is written to the pool.
* **No Automated Failover:**  
  Storage high availability (e.g., TrueNAS active/standby pairs or shared SAS multipathing) was not deployed due to hardware and licensing constraints.

---

## 15. Key Storage Engineering Takeaways

1. **Compute and Storage Decoupling Simplifies Compute Maintenance:** Offloading persistent application volumes to TrueNAS reduces lifecycle coupling between the Ubuntu compute node and persistent application data, while recovery still depends on correct configuration, mounts, and backups.
2. **NFSv4 Eliminates Portmapper Complexity:** Standardizing on NFSv4 consolidates storage traffic onto a single deterministic port (`2049/TCP`), avoiding the firewall routing issues associated with legacy NFSv3 RPC portmappers.
3. **Same-Subnet Storage Keeps the Data Path Simple:** Placing storage and compute nodes on the same isolated subnet (`10.10.20.0/24`) allows direct Layer 2 communication, so NFS traffic does not require pfSense Layer 3 forwarding.
4. **NFS Root Squashing Can Block Container Initialization:** Container images that perform setup routines as UID 0 will fail on default NFS exports. Configuring `Maproot User: root` resolves permission issues in single-tenant lab setups, though production systems require more granular ACLs.
5. **Network Mounts Need Explicit Boot-Awareness:** Mounting network filesystems via `/etc/fstab` uses `_netdev` to mark the NFS mount as network-dependent, improving boot ordering without guaranteeing that the remote TrueNAS service is already ready.
6. **ZFS Checksumming Detects Corruption but Requires Redundancy to Repair:** OpenZFS reliably flags bitrot, but true data self-healing requires physical disk redundancy (mirrors or RAIDZ) that a single-disk virtual lab cannot provide.
7. **`lz4` Compression Is a Practical Default, Not a Universal Performance Guarantee:** Enabling inline `lz4` compression on ZFS datasets can reduce stored data size with relatively low overhead, but workload-dependent results should not be treated as guaranteed.
8. **Startup Dependencies Must Account for Remote Storage:** Applications relying on NFS mounts must not initialize before the remote storage pool is confirmed accessible, preventing mount collisions and directory shadowing.