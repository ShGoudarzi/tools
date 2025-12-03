#!/usr/bin/env bash
set -euo pipefail

########################################
# Config
########################################
CODENAME="focal"             # Ubuntu 20.04 codename
ARCHES="amd64"               # Architectures to mirror (e.g. "amd64 i386")
BASE_PATH="/var/spool/apt-mirror"
REPO_ROOT="/srv/repo"
SERVER_NAME="repo.local"     # DNS name or /etc/hosts entry for mirror server

ENABLE_DOCKER="yes"          # Mirror Docker APT repo by default
ENABLE_GITLAB_CE="yes"       # Mirror GitLab CE APT repo by default

SYNC_HOUR="02"               # Daily sync hour (0–23)
SYNC_MIN="00"                # Daily sync minute (0–59)
########################################

if [[ "${EUID}" -ne 0 ]]; then
  echo "[-] Please run this script as root."
  exit 1
fi

echo "[*] Installing required packages..."
apt update
apt install -y apt-mirror nginx ca-certificates gnupg

echo "[*] Creating repo-mirror config directories..."
mkdir -p /etc/repo-mirror/sources.d
mkdir -p /etc/repo-mirror
mkdir -p "${BASE_PATH}"
mkdir -p "${REPO_ROOT}"

########################################
# 1) Global apt-mirror header
########################################
echo "[*] Writing /etc/repo-mirror/header.conf ..."
cat > /etc/repo-mirror/header.conf <<EOF
set base_path    ${BASE_PATH}
set nthreads     10
set _tilde       0
set arch         ${ARCHES}
EOF

########################################
# 2) Default Docker repo fragment
########################################
if [[ "${ENABLE_DOCKER}" == "yes" ]]; then
  DOCKER_FRAGMENT="/etc/repo-mirror/sources.d/docker-${CODENAME}.list"
  if [[ ! -f "${DOCKER_FRAGMENT}" ]]; then
    echo "[*] Creating default Docker fragment: ${DOCKER_FRAGMENT}"
    cat > "${DOCKER_FRAGMENT}" <<EOF
############# Docker Ubuntu Repo #############
deb https://download.docker.com/linux/ubuntu ${CODENAME} stable

clean https://download.docker.com/linux/ubuntu
EOF
  else
    echo "[*] Docker fragment already exists, skipping."
  fi
fi

########################################
# 3) Default GitLab CE repo fragment
########################################
if [[ "${ENABLE_GITLAB_CE}" == "yes" ]]; then
  GITLAB_FRAGMENT="/etc/repo-mirror/sources.d/gitlab-ce-${CODENAME}.list"
  if [[ ! -f "${GITLAB_FRAGMENT}" ]]; then
    echo "[*] Creating GitLab CE fragment: ${GITLAB_FRAGMENT}"
    cat > "${GITLAB_FRAGMENT}" <<EOF
############# GitLab CE #############
deb https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu ${CODENAME} main

clean https://packages.gitlab.com/gitlab/gitlab-ce/ubuntu
EOF
  else
    echo "[*] GitLab fragment already exists, skipping."
  fi
fi

########################################
# 4) Generator script for /etc/apt/mirror.list
########################################
echo "[*] Creating /usr/local/bin/repo-mirror-generate-config.sh ..."
cat > /usr/local/bin/repo-mirror-generate-config.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

HEADER="/etc/repo-mirror/header.conf"
SOURCES_DIR="/etc/repo-mirror/sources.d"
TARGET="/etc/apt/mirror.list"

if [[ ! -f "${HEADER}" ]]; then
  echo "[-] Missing ${HEADER}"
  exit 1
fi

{
  cat "${HEADER}"
  echo
  for f in "${SOURCES_DIR}"/*.list; do
    [[ -e "$f" ]] || continue
    echo
    cat "$f"
  done
} > "${TARGET}"

echo "[repo-mirror] Generated ${TARGET} from ${HEADER} + ${SOURCES_DIR}/*.list"
EOF

chmod +x /usr/local/bin/repo-mirror-generate-config.sh

########################################
# 5) Script to build symlinks for Nginx (auto from .list files)
########################################
echo "[*] Creating /usr/local/bin/repo-mirror-build-links.sh ..."
cat > /usr/local/bin/repo-mirror-build-links.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

BASE_PATH="{{BASE_PATH}}"
REPO_ROOT="{{REPO_ROOT}}"
SOURCES_DIR="/etc/repo-mirror/sources.d"

BASE_PATH="${BASE_PATH}"
REPO_ROOT="${REPO_ROOT}"

mkdir -p "${REPO_ROOT}"

# For each .list fragment:
# - derive a "name" from the filename (without extension)
# - find the first "deb" line
# - extract the upstream host from the URL
# - create a symlink: ${REPO_ROOT}/${name} -> ${BASE_PATH}/mirror/${host}
#
# This means on clients you will use:
#   deb http://repo.local/<name>/<rest-of-original-path> <distro> <components>
#
# Example:
#   original:
#     deb https://download.docker.com/linux/ubuntu focal stable
#   mirror layout:
#     ${BASE_PATH}/mirror/download.docker.com/linux/ubuntu
#   symlink:
#     ${REPO_ROOT}/docker-focal -> ${BASE_PATH}/mirror/download.docker.com
#   client source:
#     deb http://repo.local/docker-focal/linux/ubuntu focal stable

for f in "${SOURCES_DIR}"/*.list; do
  [[ -e "$f" ]] || continue

  fragment_name="$(basename "$f")"
  name="${fragment_name%.list}"

  # Find first 'deb' or 'deb-src' line
  deb_line=""
  while IFS= read -r line; do
    # Trim leading spaces
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      deb\ *|deb-src\ *)
        deb_line="$trimmed"
        break
        ;;
    esac
  done < "$f"

  if [[ -z "${deb_line}" ]]; then
    echo "[repo-mirror] WARNING: no 'deb' line found in ${f}, skipping."
    continue
  fi

  # Split deb line to extract URL
  # Format: deb [options] URL distro components...
  set -- $deb_line
  if [[ "$2" == \[*\] ]]; then
    url="$3"
  else
    url="$2"
  fi

  # Strip protocol
  proto_removed="${url#*://}"
  host="${proto_removed%%/*}"

  if [[ -z "${host}" ]]; then
    echo "[repo-mirror] WARNING: could not parse host from URL '${url}' in ${f}, skipping."
    continue
  fi

  src="${BASE_PATH}/mirror/${host}"
  dest="${REPO_ROOT}/${name}"

  if [[ ! -d "${src}" ]]; then
    echo "[repo-mirror] WARNING: source directory not found for ${name}: ${src}"
    continue
  fi

  mkdir -p "$(dirname "${dest}")"

  if [[ -e "${dest}" && ! -L "${dest}" ]]; then
    echo "[repo-mirror] WARNING: ${dest} exists and is not a symlink, skipping."
    continue
  fi

  rm -f "${dest}"
  ln -s "${src}" "${dest}"
  echo "[repo-mirror] Linked ${name}: ${dest} -> ${src}"
done
EOF

# Inject BASE_PATH and REPO_ROOT into the script
sed -i "s|{{BASE_PATH}}|${BASE_PATH}|g" /usr/local/bin/repo-mirror-build-links.sh
sed -i "s|{{REPO_ROOT}}|${REPO_ROOT}|g" /usr/local/bin/repo-mirror-build-links.sh

chmod +x /usr/local/bin/repo-mirror-build-links.sh

########################################
# 6) Main sync script
########################################
echo "[*] Creating /usr/local/bin/apt-mirror-sync.sh ..."
cat > /usr/local/bin/apt-mirror-sync.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/apt-mirror-sync.log"

mkdir -p "$(dirname "${LOG_FILE}")"

echo "=== $(date -Iseconds) : generating mirror config ===" >> "${LOG_FILE}"
/usr/local/bin/repo-mirror-generate-config.sh >> "${LOG_FILE}" 2>&1

echo "=== $(date -Iseconds) : apt-mirror sync started ===" >> "${LOG_FILE}"
/usr/bin/apt-mirror >> "${LOG_FILE}" 2>&1
echo "=== $(date -Iseconds) : apt-mirror sync finished ===" >> "${LOG_FILE}"

echo "=== $(date -Iseconds) : building nginx links ===" >> "${LOG_FILE}"
/usr/local/bin/repo-mirror-build-links.sh >> "${LOG_FILE}" 2>&1
echo "=== $(date -Iseconds) : links updated ===" >> "${LOG_FILE}"
EOF

chmod +x /usr/local/bin/apt-mirror-sync.sh

########################################
# 7) Systemd service + timer
########################################
echo "[*] Creating systemd service & timer..."

cat > /etc/systemd/system/apt-mirror.service <<EOF
[Unit]
Description=Run apt-mirror to sync APT repositories (managed by repo-mirror)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/apt-mirror-sync.sh
EOF

cat > /etc/systemd/system/apt-mirror.timer <<EOF
[Unit]
Description=Daily apt-mirror sync (managed by repo-mirror)

[Timer]
OnCalendar=*-*-* ${SYNC_HOUR}:${SYNC_MIN}:00
Persistent=true
Unit=apt-mirror.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now apt-mirror.timer

# Remove default cron job if present to avoid double runs
if [[ -f /etc/cron.d/apt-mirror ]]; then
  echo "[*] Removing default /etc/cron.d/apt-mirror to avoid double runs..."
  rm -f /etc/cron.d/apt-mirror
fi

########################################
# 8) Nginx config
########################################
echo "[*] Creating Nginx site for repo..."

cat > /etc/nginx/sites-available/repo <<EOF
server {
    listen 80;
    server_name ${SERVER_NAME};

    root ${REPO_ROOT};
    autoindex on;

    access_log /var/log/nginx/repo_access.log;
    error_log  /var/log/nginx/repo_error.log;

    location / {
        autoindex on;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default || true
ln -sf /etc/nginx/sites-available/repo /etc/nginx/sites-enabled/repo

nginx -t
systemctl reload nginx
systemctl enable nginx

########################################
# 9) Initial sync (first run)
########################################
echo "[*] Running initial apt-mirror sync (this may take a long time)..."
/usr/local/bin/apt-mirror-sync.sh

echo
echo "==============================================="
echo " Repo Mirror server setup finished."
echo "-----------------------------------------------"
echo " Base path:         ${BASE_PATH}"
echo " Web root:          ${REPO_ROOT}"
echo " Nginx URL:         http://${SERVER_NAME}/"
echo " Daily sync timer:  apt-mirror.timer at ${SYNC_HOUR}:${SYNC_MIN}"
echo " Sync log file:     /var/log/apt-mirror-sync.log"
echo "==============================================="
echo
echo "Default mirrored repos (if enabled):"
echo "  - Docker:     /etc/repo-mirror/sources.d/docker-${CODENAME}.list"
echo "  - GitLab CE:  /etc/repo-mirror/sources.d/gitlab-ce-${CODENAME}.list"
echo
echo "On clients, you will typically use URLs like:"
echo "  deb http://${SERVER_NAME}/docker-${CODENAME}/linux/ubuntu ${CODENAME} stable"
echo "  deb http://${SERVER_NAME}/gitlab-ce-${CODENAME}/gitlab/gitlab-ce/ubuntu ${CODENAME} main"
echo
echo "To add new repos later, just drop a new .list file into /etc/repo-mirror/sources.d"
echo "(no need to touch any other config), then run:"
echo "  sudo systemctl start apt-mirror.service"
echo
