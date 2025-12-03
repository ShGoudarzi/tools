# repo-mirror

A small, opinionated APT repository mirroring setup for Ubuntu 20.04 using `apt-mirror` and `nginx`.

This version is optimized for:

- Mirroring **Docker** and **GitLab CE** repos by default
- Making it **trivial to add new repos later**:
  - You only need to create **one `.list` file** under `/etc/repo-mirror/sources.d/`
  - The rest (apt-mirror config + nginx symlinks) is generated automatically

> **Target platform:** Ubuntu 20.04 (focal).  
> It may work on newer releases, but this script is tuned for focal.

---

## What gets mirrored by default?

After running `setup-repo-mirror.sh` with defaults:

- Docker APT repo:

  - Upstream: `https://download.docker.com/linux/ubuntu focal stable`
  - Mirror storage:  
    `/var/spool/apt-mirror/mirror/download.docker.com/...`
  - Web path (auto-generated symlink):  
    `/srv/repo/docker-focal` → `/var/spool/apt-mirror/mirror/download.docker.com`
  - Client URL pattern:

    ```ini
    deb http://repo.local/docker-focal/linux/ubuntu focal stable
    ```

- GitLab CE APT repo:

  - Upstream: `https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu focal main`
  - Mirror storage:  
    `/var/spool/apt-mirror/mirror/packages.gitlab.com/...`
  - Web path (auto-generated symlink):  
    `/srv/repo/gitlab-ce-focal` → `/var/spool/apt-mirror/mirror/packages.gitlab.com`
  - Client URL pattern:

    ```ini
    deb http://repo.local/gitlab-ce-focal/gitlab/gitlab-ce/ubuntu focal main
    ```

You can disable either of them by editing the config block at the top of the script:

```bash
ENABLE_DOCKER="yes"
ENABLE_GITLAB_CE="yes"
```

Set to `"no"` to skip creating that default fragment.

---

## Design overview

The system is built around three main concepts:

1. **Config fragments for upstream repos**  
   Stored in `/etc/repo-mirror/sources.d/*.list`, each one matching a logical repo.

2. **Auto-generated `apt-mirror` config**  
   `/usr/local/bin/repo-mirror-generate-config.sh` combines:
   - `/etc/repo-mirror/header.conf`
   - all `sources.d/*.list`
   into `/etc/apt/mirror.list`.

3. **Auto-generated web symlinks for nginx**  
   `/usr/local/bin/repo-mirror-build-links.sh`:
   - Looks at every `.list` file in `/etc/repo-mirror/sources.d/`
   - Extracts the upstream host from the first `deb` line
   - Creates a symlink:

     ```text
     /srv/repo/<fragment-name> -> /var/spool/apt-mirror/mirror/<host>
     ```

   Where `<fragment-name>` is the `.list` filename without extension.

### Example: docker-focal.list

- Fragment file: `/etc/repo-mirror/sources.d/docker-focal.list`
- Name: `docker-focal`
- Upstream URL: `https://download.docker.com/linux/ubuntu`
  → Host: `download.docker.com`
- Symlink:

  ```text
  /srv/repo/docker-focal -> /var/spool/apt-mirror/mirror/download.docker.com
  ```

- Resulting APT source line on clients:

  ```ini
  deb http://repo.local/docker-focal/linux/ubuntu focal stable
  ```

No extra manual mapping is required.

---

## Files installed

- `/etc/repo-mirror/header.conf`  
  Global `apt-mirror` settings (base path, threads, architectures).

- `/etc/repo-mirror/sources.d/*.list`  
  Repository fragments (one per upstream repo), e.g.:

  - `docker-focal.list`
  - `gitlab-ce-focal.list`

- `/usr/local/bin/repo-mirror-generate-config.sh`  
  Generates `/etc/apt/mirror.list`.

- `/usr/local/bin/repo-mirror-build-links.sh`  
  Automatically builds nginx symlinks based on `.list` files.

- `/usr/local/bin/apt-mirror-sync.sh`  
  Orchestrates:

  1. Generate `mirror.list`
  2. Run `apt-mirror`
  3. Update symlinks

- `/etc/systemd/system/apt-mirror.service`  
  One-shot sync unit.

- `/etc/systemd/system/apt-mirror.timer`  
  Daily timer for automatic sync.

- `/srv/repo`  
  Web root used by `nginx`.

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
   - Create `/etc/repo-mirror` config
   - Generate default fragments for Docker and GitLab CE (if enabled)
   - Configure `nginx` to serve `/srv/repo`
   - Create systemd service + timer
   - Run an initial sync (this can take a while)

3. Make sure `SERVER_NAME` in the script (default `repo.local`) resolves to the mirror server IP (via DNS or `/etc/hosts`).

---

## Using the mirror on clients

### Docker

On any client that should install Docker from the local mirror:

```bash
sudo tee /etc/apt/sources.list.d/docker-mirror.list >/dev/null <<EOF
deb http://repo.local/docker-focal/linux/ubuntu focal stable
EOF

sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io
```

### GitLab CE

On any client that should install GitLab CE from the local mirror:

```bash
sudo tee /etc/apt/sources.list.d/gitlab-mirror.list >/dev/null <<EOF
deb http://repo.local/gitlab-ce-focal/gitlab/gitlab-ce/ubuntu focal main
EOF

sudo apt update
sudo EXTERNAL_URL="https://gitlab.example.com" apt install gitlab-ce
```

> Note: Package signatures are still from the original upstream.  
> If you want signature validation, import the upstream GPG keys on each client.

---

## Configuration variables

At the top of `setup-repo-mirror.sh`:

```bash
CODENAME="focal"             # Ubuntu codename
ARCHES="amd64"               # Architectures to mirror
BASE_PATH="/var/spool/apt-mirror"
REPO_ROOT="/srv/repo"
SERVER_NAME="repo.local"

ENABLE_DOCKER="yes"          # Mirror Docker APT repo
ENABLE_GITLAB_CE="yes"       # Mirror GitLab CE APT repo

SYNC_HOUR="02"               # Daily sync hour
SYNC_MIN="00"                # Daily sync minute
```

Change these values before running the script if needed.

---

## Adding a new repository (only one step)

The goal is that **you only need to do “Step 1”** when adding a new repo.

### Step 1 – Create a `.list` file under `/etc/repo-mirror/sources.d/`

Example: mirror a hypothetical repo at `https://download.example.com/linux/ubuntu`:

```bash
sudo nano /etc/repo-mirror/sources.d/example-focal.list
```

```ini
############# Example Repo #############
deb https://download.example.com/linux/ubuntu focal main

clean https://download.example.com/linux/ubuntu
```

That’s it.

Next time `apt-mirror-sync` runs, it will:

1. Pick up `example-focal.list` into `/etc/apt/mirror.list`
2. Sync the repo into:

   ```text
   /var/spool/apt-mirror/mirror/download.example.com/...
   ```

3. Create an nginx symlink:

   ```text
   /srv/repo/example-focal -> /var/spool/apt-mirror/mirror/download.example.com
   ```

4. So the client-side source line becomes:

   ```ini
   deb http://repo.local/example-focal/linux/ubuntu focal main
   ```

### Run a manual sync (optional)

You can manually trigger a sync instead of waiting for the timer:

```bash
sudo systemctl start apt-mirror.service
```

---

## Logs & troubleshooting

- Sync log:

  ```text
  /var/log/apt-mirror-sync.log
  ```

- Systemd:

  ```bash
  systemctl status apt-mirror.service
  systemctl status apt-mirror.timer
  ```

- Nginx logs:

  ```text
  /var/log/nginx/repo_access.log
  /var/log/nginx/repo_error.log
  ```

- If you see:

  ```text
  [repo-mirror] WARNING: source directory not found for <name>: ...
  ```

  It usually means:

  - The repo has not completed its first sync yet, or
  - The upstream host in the `.list` file does not match the directory layout under `${BASE_PATH}/mirror/`

---

## License

MIT – feel free to adapt and extend.
