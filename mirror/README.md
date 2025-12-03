# repo-mirror

A small, opinionated APT repository mirroring setup for Ubuntu 20.04 using `apt-mirror` and `nginx`.

This project installs and configures:

- `apt-mirror` to sync:
  - Ubuntu base repositories (for a given codename / architecture)
  - Optionally GitLab CE packages
- `nginx` to serve mirrored repositories over HTTP
- A `systemd` service + timer to run daily syncs
- A simple, extensible configuration layout in `/etc/repo-mirror/` so you can easily add more repos later.

> **Target platform:** Ubuntu 20.04 (focal).  
> It may work on newer releases, but this script is tuned for focal.

---

## Features

- Single setup script: `setup-repo-mirror.sh`
- Declarative config for mirrored repos:
  - A global header: `/etc/repo-mirror/header.conf`
  - One `.list` fragment per repo: `/etc/repo-mirror/sources.d/*.list`
  - A mapping file for web paths: `/etc/repo-mirror/repos.conf`
- Mirror config generated automatically into `/etc/apt/mirror.list`
- Symlinks under `/srv/repo` to provide clean URLs for `nginx`
- Daily sync controlled by `systemd` timer, not cron
- Optional GitLab CE mirror for installing GitLab from your local repo

---

## Repository layout (on the mirror server)

- `/etc/repo-mirror/header.conf`  
  Base configuration for `apt-mirror` (paths, threads, architectures, etc).

- `/etc/repo-mirror/sources.d/*.list`  
  Each file describes one logical upstream repo to mirror. Example:
    - `ubuntu-focal.list`
    - `gitlab-ce-focal.list`

- `/etc/repo-mirror/repos.conf`  
  Maps each logical repo name to:
  - Source path (relative to `${BASE_PATH}/mirror/`)
  - Web path (relative to `${REPO_ROOT}`)

- `/usr/local/bin/repo-mirror-generate-config.sh`  
  Generates `/etc/apt/mirror.list` from `header.conf` + all `sources.d/*.list`.

- `/usr/local/bin/repo-mirror-build-links.sh`  
  Builds symlinks under `${REPO_ROOT}` based on `repos.conf`.

- `/usr/local/bin/apt-mirror-sync.sh`  
  Orchestrates:
  1. Generating `mirror.list`
  2. Running `apt-mirror`
  3. Building web symlinks

- `/etc/systemd/system/apt-mirror.service`  
  One-shot unit that runs the sync script.

- `/etc/systemd/system/apt-mirror.timer`  
  Triggers the service daily at the configured time.

- `/srv/repo`  
  Web root served by `nginx`. This will contain symlinks like:
    - `ubuntu` → `${BASE_PATH}/mirror/archive.ubuntu.com/ubuntu`
    - `ubuntu-security` → `${BASE_PATH}/mirror/security.ubuntu.com/ubuntu`
    - `gitlab/gitlab-ce/ubuntu` → `${BASE_PATH}/mirror/packages.gitlab.com/gitlab/gitlab-ce/ubuntu`

---

## Installation

1. Copy `setup-repo-mirror.sh` to your mirror server (Ubuntu 20.04):

   ```bash
   scp setup-repo-mirror.sh root@mirror-server:/root/
   ```

2. SSH into the server and run:

   ```bash
   chmod +x setup-repo-mirror.sh
   sudo ./setup-repo-mirror.sh
   ```

   The script will:

   - Install required packages (`apt-mirror`, `nginx`, etc.)
   - Create [`/etc/repo-mirror`](#repository-layout-on-the-mirror-server) config
   - Configure `nginx` to serve `/srv/repo`
   - Create systemd service + timer for daily sync
   - Run an initial sync (this **can take a long time** and lots of disk space)

3. Make sure DNS or `/etc/hosts` maps your mirror server name (default: `repo.local`) to the correct IP.

---

## Using the mirror on clients

On each client (Ubuntu 20.04):

1. Backup the default sources:

   ```bash
   sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
   ```

2. Replace `/etc/apt/sources.list` with:

   ```ini
   deb http://repo.local/ubuntu focal main restricted universe multiverse
   deb http://repo.local/ubuntu focal-updates main restricted universe multiverse
   deb http://repo.local/ubuntu-security focal-security main restricted universe multiverse
   ```

   Adjust `repo.local` to your actual mirror hostname.

3. Update:

   ```bash
   sudo apt update
   ```

### Installing GitLab CE from the mirror (optional)

If `ENABLE_GITLAB_CE="yes"` in the script:

1. On the client, add a dedicated source list:

   ```bash
   sudo tee /etc/apt/sources.list.d/gitlab_gitlab-ce.list >/dev/null <<EOF
   deb http://repo.local/gitlab/gitlab-ce/ubuntu focal main
   EOF
   ```

2. Install GitLab CE (example):

   ```bash
   sudo apt update
   sudo EXTERNAL_URL="https://gitlab.example.com" apt install gitlab-ce
   ```

> If you need package signature checking, you will still need to import the GitLab GPG key on the client, because packages are signed by GitLab, not by your local mirror.

---

## Configuration variables

At the top of `setup-repo-mirror.sh`:

```bash
CODENAME="focal"             # Ubuntu 20.04 codename
ARCHES="amd64"               # Architectures to mirror (e.g. "amd64 i386")
BASE_PATH="/var/spool/apt-mirror"
REPO_ROOT="/srv/repo"
SERVER_NAME="repo.local"     # DNS name or /etc/hosts entry for mirror server
ENABLE_GITLAB_CE="yes"       # Set to "no" to disable GitLab CE mirror
SYNC_HOUR="02"               # Daily sync hour
SYNC_MIN="00"                # Daily sync minute
```

Adjust them to your environment **before** running the script.

---

## Extending the mirror with new repositories

The design goal is to make adding repositories as simple as possible:

### 1. Add a new apt-mirror source fragment

Create a new fragment file in `/etc/repo-mirror/sources.d/`:

```bash
sudo nano /etc/repo-mirror/sources.d/myrepo-focal.list
```

Example content:

```ini
############# My Custom Repo #############
deb https://download.example.com/linux/ubuntu focal main

clean https://download.example.com/linux/ubuntu
```

This is basically what you would put into `/etc/apt/sources.list`, but used by `apt-mirror` instead of `apt`.

Next time the sync runs, this will be included automatically in `/etc/apt/mirror.list`.

### 2. Map the source path to a web path

Edit `/etc/repo-mirror/repos.conf`:

```bash
sudo nano /etc/repo-mirror/repos.conf
```

Add a new line:

```text
myrepo          download.example.com/linux/ubuntu                      myrepo/ubuntu
```

Interpretation:

- `download.example.com/linux/ubuntu`  
  = relative path under `${BASE_PATH}/mirror/` where `apt-mirror` stores this repo.  
  For example, it will end up at:  
  `/var/spool/apt-mirror/mirror/download.example.com/linux/ubuntu`

- `myrepo/ubuntu`  
  = how it will be exposed under the web root:  
  `/srv/repo/myrepo/ubuntu` → `http://repo.local/myrepo/ubuntu`

### 3. Run a sync

Either wait for the daily timer, or trigger it manually:

```bash
sudo systemctl start apt-mirror.service
```

When it finishes, `repo-mirror-build-links.sh` will update the symlinks, and your new repo will be accessible.

### 4. Use it on clients

On clients, reference your mirror instead of the upstream:

```ini
deb http://repo.local/myrepo/ubuntu focal main
```

---

## Logs and troubleshooting

- Sync log: `/var/log/apt-mirror-sync.log`
- Systemd units:
  - `apt-mirror.service`
  - `apt-mirror.timer`
- Check status:

  ```bash
  systemctl status apt-mirror.service
  systemctl status apt-mirror.timer
  ```

- Nginx logs:
  - Access: `/var/log/nginx/repo_access.log`
  - Error: `/var/log/nginx/repo_error.log`

If you see `WARNING: source directory not found` in logs, it usually means:

- The repo has not been synced yet
- Or the path in `repos.conf` does not match the actual directory layout under `${BASE_PATH}/mirror/`

---

## License

MIT – feel free to adapt this to your environment.
