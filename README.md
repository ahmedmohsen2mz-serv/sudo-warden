# AI Agent Production Operating System (ai-agent-system)
**Enterprise-Grade Linux Hardening, Read-Only Diagnostics, Supervised Mutations, and Comprehensive Auditing for AI Autonomous Agents**

---

## 1. Executive Summary & Philosophy

Operating an autonomous or semi-autonomous AI agent on production infrastructure introduces unique operational risks. Traditional access models either grant broad, unrestricted root privileges (high catastrophic blast radius) or severely restricted shell accounts (ineffective diagnostics).

The **`ai-agent-system`** implements a **Strict Whitelist Privilege Model** tailored for Linux server operations:

1. **Unrestricted, Autonomous Diagnostics (Read-Only):** The AI agent is granted passwordless sudo access (`NOPASSWD`) to 200+ non-destructive diagnostic, monitoring, and inspection utilities.
2. **Supervised & Atomic Mutations (Write Operations):** Destructive commands (`rm`, `sed -i`, direct editor invocation, raw package managers, arbitrary file redirection) are strictly blocked. System modifications are exclusively permitted via audited **wrapper scripts** that enforce **mandatory pre-flight backups**, **diff inspection**, and **health validation**.
3. **Multi-Tier Kernel & Session Auditing:** Every keystroke, terminal output stream (I/O logging), system call (`execve`, `open`, `connect`), and configuration diff is permanently captured and indexed.
4. **Behavioral Enforcement via `SKILL.md`:** The AI agent's operational manual enforces non-destructive diagnosis and human-in-the-loop approvals before applying state changes.

---

## 2. Architecture & Security Model

```
                                  +------------------------------+
                                  |     AI Agent / SSH Model     |
                                  +--------------+---------------+
                                                 |
                                                 v
                                  +------------------------------+
                                  |  Restricted User: ai-agent   |
                                  |   (No Password, SSH Only)    |
                                  +--------------+---------------+
                                                 |
                 +-------------------------------+-------------------------------+
                 |                                                               |
                 v                                                               v
   +---------------------------+                                   +---------------------------+
   |  READ-ONLY DIAGNOSTICS    |                                   |     WRITE OPERATIONS      |
   | (NOPASSWD via Sudoers)    |                                   |  (Audited Wrapper Scripts)|
   +-------------+-------------+                                   +-------------+-------------+
                 |                                                               |
                 +-> System Info: uptime, lscpu, uname                           +-> ai-safe-edit
                 +-> Processes: ps, top, free, vmstat                            |   (Auto-Backup + Diff)
                 +-> Storage: df, du, lsblk, lvs                                 +-> ai-safe-pkg
                 +-> Network: ss, ip, dig, ping, iptables -L                     |   (State Snapshot + Log)
                 +-> Logs: journalctl, dmesg, tail                               +-> ai-safe-svc
                 +-> Containers: docker ps/logs/inspect                          |   (Pre/Post Health Checks)
                 +-> Protected Readers: less, find [NOEXEC]                      |
                 |                                                               |
                 +-------------------------------+-------------------------------+
                                                 |
                                                 v
                         +-----------------------------------------------+
                         |           TRIPLE-LAYER AUDIT TRAIL            |
                         +-----------------------------------------------+
                         | Layer 1: Sudoers Session & I/O Logging        |
                         | Layer 2: Rsyslog & Logrotate Dedicated Logs  |
                         | Layer 3: Kernel auditd System Call Tracing    |
                         +-----------------------------------------------+
```

### Core Security Tenets

| Feature | Technical Implementation | Security Objective |
| :--- | :--- | :--- |
| **Whitelisting Only** | `sudoers.d/ai-agent` with exact binaries | Prevents privilege escalation and execution of unapproved utilities. |
| **Shell Escape Prevention** | `NOEXEC:NOPASSWD` on interactive tools (`less`, `find`) | Disallows breaking out into arbitrary subshells (e.g., `!bash` inside `less` or `-exec` flags). |
| **Tamper-Proof Backups** | Root-owned `/var/backups/ai-agent/` (0750) | Ensures backups are isolated and cannot be overwritten or wiped by the agent. |
| **Non-Repudiation** | `log_input`, `log_output`, `iolog_dir` | Enables exact replay of the agent's interactive terminal sessions via `sudoreplay`. |
| **Deep Kernel Auditing** | `auditd` rules tracking `execve`, `open`, `connect` | Catches unauthorized binary executions, hidden file access, or socket activity even if logs are redirected. |

---

## 3. Repository & Deployment Layout

```
ai-agent-system/
├── deploy.sh                     # Automated deployment and verification orchestrator
├── uninstall.sh                  # Safe de-provisioner (retains logs/backups)
├── README.md                     # Comprehensive architecture and technical documentation
├── SKILL.md                      # AI Agent Operating Manual (Behavioral System Prompt)
├── sudoers/
│   └── ai-agent                  # Production sudoers whitelist and security policy
├── scripts/
│   ├── ai-safe-edit.sh           # Atomic file editor with automated backup & rollback
│   ├── ai-safe-pkg.sh            # Safe package management wrapper with state tracking
│   └── ai-safe-svc.sh            # Systemd service manager with before/after assertions
├── logging/
│   ├── ai-agent-rsyslog.conf     # Syslog isolation rule for ai-agent tagging
│   └── ai-agent-logrotate.conf   # Log rotation policy (90-day retention with compression)
└── audit/
    └── ai-agent-audit.rules      # Kernel syscall interception rules (auditd)
```

---

## 4. Component Deep Dive

### 4.1 Sudoers Hardening (`sudoers/ai-agent`)

The file is provisioned to `/etc/sudoers.d/ai-agent` with permissions `0440` and validated using `visudo -cf`.

* **Execution Environment Hardening:**
  * `timestamp_timeout=0`: Disables credential caching; every execution is authenticated and evaluated independently.
  * `env_reset`: Strips all environment variables to block LD_PRELOAD and library hijacking.
  * `secure_path`: Overrides `PATH` to trusted directories (`/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`).
  * `log_input, log_output`: Records complete terminal streams into `/var/log/ai-agent/sudo-io/`.
  * `use_pty`: Forces all commands into an isolated pseudo-terminal, preventing TIOCSTI ioctl injection attacks.

* **Binary Classifications:**
  * **System & Diagnostic Monitoring:** Read-only utilities (`uptime`, `uname`, `lscpu`, `free`, `ps`, `top`, `vmstat`, `iostat`, `df`, `lsblk`, `ss`, `netstat`, `ip`, `traceroute`, `dig`).
  * **Service & Container Observability:** Query-only commands (`systemctl status/show/cat`, `docker ps/logs/inspect/stats`).
  * **Interactive & Potentially Risky Utilities:** Binary wrappers (`less`, `find`) are strictly guarded with `NOEXEC` to disable subshell spawns.
  * **Mutation Delegation:** All write permissions are scoped exclusively to `/usr/local/bin/ai-safe-*`.

---

### 4.2 Safe Mutation Wrappers (`scripts/`)

Direct root modifications to the filesystem are strictly forbidden. The AI agent interacts with the operating system through three POSIX-compliant, defensive bash utilities installed in `/usr/local/bin/`:

#### 1. `ai-safe-edit` (Atomic File Mutation & Rollback)
* **Pre-Flight Backup:** Before altering any file, copies the target to `/var/backups/ai-agent/<directory>/<filename>.<YYYYmmdd_HHMMSS>.bak`.
* **Metadata Preservation:** Replicates original ownership (`chown --reference`) and file permissions (`chmod --reference`).
* **Visual Verification:** Automatically displays a unified colored `diff` upon applying edits.
* **Commands:**
  ```bash
  # Apply modification (auto-backup created before overwriting)
  sudo ai-safe-edit /etc/nginx/nginx.conf /home/ai-agent/tmp/nginx.conf.new

  # Append content with automated backup
  sudo ai-safe-edit --append /etc/hosts /home/ai-agent/tmp/hosts.addon

  # Inspect difference against the latest backup
  sudo ai-safe-edit --diff /etc/nginx/nginx.conf

  # List all historical backups of a file
  sudo ai-safe-edit --list-backups /etc/nginx/nginx.conf

  # Instant rollback to a specific snapshot
  sudo ai-safe-edit --restore /var/backups/ai-agent/etc/nginx/nginx.conf.20261014_210000.bak /etc/nginx/nginx.conf
  ```

#### 2. `ai-safe-pkg` (Audited Package Management)
* **Pre-Change Snapshot:** Dumps a package list (`dpkg -l` or `rpm -qa`) before package additions or upgrades.
* **Engine Agnostic:** Supports Debian/Ubuntu (`apt-get`) and RHEL/CentOS/Alma/Rocky (`dnf`/`yum`).
* **Commands:**
  ```bash
  sudo ai-safe-pkg install htop iotop
  sudo ai-safe-pkg update
  sudo ai-safe-pkg history
  ```

#### 3. `ai-safe-svc` (Verified Service Orchestration)
* **State Capture & Health Check:** Records service status, PID, memory consumption, and unit logs before executing the action.
* **Post-Action Verification:** Waits 3 seconds and checks `is-active`. Emits an alert if the unit crashed or entered a failed state.
* **Commands:**
  ```bash
  sudo ai-safe-svc reload nginx
  sudo ai-safe-svc restart redis-server
  sudo ai-safe-svc status postgresql
  ```

---

### 4.3 Multi-Layer Auditing Infrastructure

All agent operations are captured across three distinct logging streams:

1. **Session Terminal Stream (Sudo I/O):**
   * Stored in `/var/log/ai-agent/sudo-io/`.
   * Captures every character typed and returned.
   * Can be replayed in real time using:
     ```bash
     sudoreplay -d /var/log/ai-agent/sudo-io -l ai-agent
     ```

2. **Application & Wrapper Logs (`/var/log/ai-agent/`):**
   * `actions.log`: High-level summary of every edit, backup, and restore.
   * `pkg-operations.log`: Detailed output of installations and repository updates.
   * `svc-operations.log`: Lifecycle records of service transitions and health verifications.
   * Managed via `ai-agent-logrotate.conf` (daily rotation, 90-day retention, GZIP compression).

3. **Kernel System Call Auditing (`auditd`):**
   * Rules loaded via `/etc/audit/rules.d/99-ai-agent.rules`.
   * Captures:
     * `execve` (All program invocations executed by the agent UID).
     * `open`, `openat`, `creat` (All file interactions).
     * `chmod`, `chown`, `unlink`, `rename` (Security violation monitoring).
     * Watch points on sensitive files (`/etc/sudoers`, `/etc/shadow`, `/etc/passwd`).

---

## 5. Step-by-Step Installation & Deployment

### Step 1: Transfer Assets to Target Machine
From your workstation, copy the system directory to the target server's `/tmp`:
```bash
scp -r ai-agent-system/ root@<PRODUCTION_SERVER_IP>:/tmp/
```

### Step 2: Ensure Audit Infrastructure Exists
SSH into the server and ensure `auditd` is present:
```bash
ssh root@<PRODUCTION_SERVER_IP>

# Debian / Ubuntu
apt update && apt install -y auditd audispd-plugins

# RHEL / CentOS / AlmaLinux / Rocky Linux
dnf install -y audit && systemctl enable --now auditd
```

### Step 3: Run the Automated Deployment Script
```bash
cd /tmp/ai-agent-system
chmod +x deploy.sh
sudo bash deploy.sh
```

The script will:
* Provision the `ai-agent` system account with locked password authentication.
* Create required working, backup, and log paths.
* Validate and install `/etc/sudoers.d/ai-agent`.
* Deploy wrapper scripts to `/usr/local/bin/`.
* Configure rsyslog, logrotate, and kernel audit rules.
* Install `SKILL.md` directly into `/home/ai-agent/SKILL.md` (read-only mode: `0440`).
* Run an 8-point automated sanity check.

### Step 4: Authorize AI Agent SSH Access
Append the public key used by your AI Agent runner or API client:
```bash
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... ai-model-runner" >> /home/ai-agent/.ssh/authorized_keys
chmod 600 /home/ai-agent/.ssh/authorized_keys
chown ai-agent:ai-agent /home/ai-agent/.ssh/authorized_keys
```

---

## 6. Verification & Smoke Testing

Run the following checks to confirm security policies are functioning as expected:

### 1. Test Read-Only Diagnostic Privilege (Must Succeed)
```bash
su - ai-agent -c "sudo uptime"
su - ai-agent -c "sudo ps aux | head -n 5"
su - ai-agent -c "sudo df -h"
```
*Expected Result:* Output returns cleanly without requesting a password.

### 2. Test Blacklisted Dangerous Operations (Must Fail)
```bash
# Direct deletion attempt
su - ai-agent -c "sudo rm /tmp/test.file"

# Direct shell escape or permission change
su - ai-agent -c "sudo chmod 777 /etc/hosts"

# System shutdown / reboot
su - ai-agent -c "sudo systemctl reboot"
```
*Expected Result:* Sudo responds with `Sorry, user ai-agent is not allowed to execute '...' as root`.

### 3. Test Safe Mutation Pipeline (Must Backup & Apply)
```bash
# Prepare mock payload in ai-agent scratch directory
su - ai-agent -c "echo '127.0.0.1 mock.local' > /home/ai-agent/tmp/test_entry.txt"

# Create a dummy target file
touch /tmp/test_target.txt

# Run safe edit wrapper
su - ai-agent -c "sudo ai-safe-edit /tmp/test_target.txt /home/ai-agent/tmp/test_entry.txt"
```
*Expected Result:* Backup is created in `/var/backups/ai-agent/tmp/`, diff is displayed, and edit is logged.

---

## 7. Operational Playbook for System Administrators

### Investigating What the AI Did

#### 1. Quick Summary of High-Level Actions
```bash
cat /var/log/ai-agent/actions.log
```

#### 2. Review Sudo Activity
```bash
# Check timestamped list of executed sudo commands
cat /var/log/ai-agent/sudo.log

# Replay an entire interactive session
sudoreplay -d /var/log/ai-agent/sudo-io -l ai-agent
```

#### 3. Inspect Kernel Audit Trail
```bash
# View all binaries executed by the AI agent today
ausearch -k ai-agent-exec -ts today --format text

# Check if the agent attempted unauthorized deletions or permission changes
ausearch -k ai-agent-delete --format text
ausearch -k ai-agent-perm --format text
```

#### 4. Managing File Backups
All file backups reside in `/var/backups/ai-agent/` mirroring the original file system hierarchy:
```bash
# List all backups made across the system
find /var/backups/ai-agent/ -type f -ls

# Revert a configuration file to a previous state
sudo ai-safe-edit --restore /var/backups/ai-agent/etc/nginx/nginx.conf.20261014_210000.bak /etc/nginx/nginx.conf
```

---

## 8. Decommissioning & Removal

To cleanly decommission the AI agent environment while preserving audit records and backups:
```bash
cd /tmp/ai-agent-system
sudo bash uninstall.sh
```
* Note: Logs (`/var/log/ai-agent/`) and backups (`/var/backups/ai-agent/`) are retained intentionally to maintain an audit trail. To purge them completely:
  ```bash
  rm -rf /var/log/ai-agent /var/backups/ai-agent
  ```
