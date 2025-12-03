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
ENABLE_GITLAB_CE="yes"       # Set to "no" if you don't want to mirror GitLab CE
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
# 2) Default Ubuntu focal repo fragment
########################################
UBUNTU_FRAGMENT="/etc/repo-mirror/sources.d/ubuntu-${CODENAME}.list"
if [[ ! -f "${UBUNTU_FRAGMENT}" ]]; then
  echo "[*] Creating default Ubuntu fragment: ${UBUNTU_FRAGMENT}"
  cat > "${UBUNTU_FRAGMENT}" <<EOF
############# Ubuntu ${CODENAME} #############
deb http://archive.ubuntu.com/ubuntu ${CODENAME} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${CODENAME}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${CODENAME}-security main restricted universe multiverse

clean http://archive.ubuntu.com/ubuntu
clean http://security.ubuntu.com/ubuntu
EOF
else
  echo "[*] Ubuntu fragment already exists, skipping."
fi

########################################
# 3) Optional GitLab CE repo fragment
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
# 4) repos.conf mapping (symlink config)
########################################
echo "[*] Writing /etc/repo-mirror/repos.conf ..."
cat > /etc/repo-mirror/repos.conf <<EOF
# name            source_relative_path                                          web_path
# -----------------------------------------------------------------------------------------------
ubuntu           archive.ubuntu.com/ubuntu                                      ubuntu
ubuntu-security  security.ubuntu.com/ubuntu                                     ubuntu-security
EOF

if [[ "${ENABLE_GITLAB_CE}" == "yes" ]]; then
  cat >> /etc/repo-mirror/repos.conf <<EOF
gitlab-ce        packages.gitlab.com/gitlab/gitlab-ce/ubuntu                    gitlab/gitlab-ce/ubuntu
EOF
fi

########################################
# 5) Generator script for /etc/apt/mirror.list
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
# 6) Script to build symlinks for Nginx
########################################
echo "[*] Creating /usr/local/bin/repo-mirror-build-links.sh ..."
cat > /usr/local/bin/repo-mirror-build-links.sh <<EOF
#!/usr/bin/env bash
set -euo pipefail

BASE_PATH="${BASE_PATH}"
REPO_ROOT="${REPO_ROOT}"
CONF="/etc/repo-mirror/repos.conf"

mkdir -p "\${REPO_ROOT}"

if [[ ! -f "\${CONF}" ]]; then
  echo "[-] repos.conf not found: \${CONF}"
  exit 1
fi

while read -r name src_rel web_path; do
  # Skip empty lines and comments
  [[ -z "\${name:-}" ]] && continue
  [[ "\${name}" =~ ^# ]] && continue

  src="\${BASE_PATH}/mirror/\${src_rel}"
  dest="\${REPO_ROOT}/\${web_path}"

  if [[ ! -d "\${src}" ]]; then
    echo "[repo-mirror] WARNING: source directory not found: \${src} (for \${name})"
    continue
  fi

  mkdir -p "\$(dirname "\${dest}")"

  if [[ -e "\${dest}" && ! -L "\${dest}" ]]; then
    echo "[repo-mirror] WARNING: \${dest} exists and is not a symlink, skipping."
    continue
  fi

  rm -f "\${dest}"
  ln -s "\${src}" "\${dest}"
  echo "[repo-mirror] Linked \${name}: \${dest} -> \${src}"
done < "\${CONF}"
EOF

chmod +x /usr/local/bin/repo-mirror-build-links.sh

########################################
# 7) Main sync script
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
# 8) Systemd service + timer
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
# 9) Nginx config
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
# 10) Initial sync (first run)
########################################
echo "[*] Running initial apt-mirror sync (this may take a long time)..."
/usr/local/bin/apt-mirror-sync.sh

echo
echo "==============================================="
echo " Repo Mirror server setup finished."
echo "-----------------------------------------------"
echo " Mirror base path:   ${BASE_PATH}"
echo " Web root:           ${REPO_ROOT}"
echo " Nginx URL:          http://${SERVER_NAME}/"
echo " Daily sync timer:   apt-mirror.timer at ${SYNC_HOUR}:${SYNC_MIN}"
echo " Sync log file:      /var/log/apt-mirror-sync.log"
echo "==============================================="
echo
echo "Example client config (Ubuntu ${CODENAME}):"
echo "  deb http://${SERVER_NAME}/ubuntu ${CODENAME} main restricted universe multiverse"
echo "  deb http://${SERVER_NAME}/ubuntu ${CODENAME}-updates main restricted universe multiverse"
echo "  deb http://${SERVER_NAME}/ubuntu-security ${CODENAME}-security main restricted universe multiverse"
echo
echo "If GitLab CE is enabled, client source:"
echo "  deb http://${SERVER_NAME}/gitlab/gitlab-ce/ubuntu ${CODENAME} main"
echo
echo "To extend with new repos, see comments in /etc/repo-mirror/sources.d and /etc/repo-mirror/repos.conf"
echo
