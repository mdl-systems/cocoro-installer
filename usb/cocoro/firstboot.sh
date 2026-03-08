#!/bin/bash
# ============================================================================
# cocoro-installer: First Boot Setup Script
# ============================================================================
# 実行タイミング: cocoro-firstboot.service (初回起動時のみ)
# 目的: ネットワーク接続後に Docker, cocoro-core をセットアップ
# ============================================================================
set -euo pipefail
exec > /var/log/cocoro-firstboot.log 2>&1
echo "cocoro-core first boot: $(date)"

readonly COCORO_CORE_REPO="https://github.com/mdl-systems/cocoro-core"
readonly COCORO_INSTALL_DIR="/opt/cocoro/core"
readonly COCORO_DATA_DIR="/data/cocoro"
readonly ADMIN_USER="cocoro-admin"

# ---------------------------------------------------------------------------
# 0. ネットワーク待機
# ---------------------------------------------------------------------------
echo "[0/7] Waiting for network..."
for i in $(seq 1 60); do
  if host get.docker.com > /dev/null 2>&1 || ping -c 1 8.8.8.8 > /dev/null 2>&1; then
    echo "Network ready after ${i}s"
    break
  fi
  sleep 1
done

# ---------------------------------------------------------------------------
# 1. Docker のインストール
# ---------------------------------------------------------------------------
echo "[1/7] Installing Docker..."
curl -fsSL https://get.docker.com | sh
usermod -aG docker "${ADMIN_USER}"
systemctl enable docker

# Docker デーモン設定
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "live-restore": true,
  "default-address-pools": [
    {
      "base": "172.20.0.0/16",
      "size": 24
    }
  ]
}
EOF
systemctl restart docker

# ---------------------------------------------------------------------------
# 2. cocoro-core リポジトリのクローン
# ---------------------------------------------------------------------------
echo "[2/7] Cloning cocoro-core..."
mkdir -p "$(dirname "${COCORO_INSTALL_DIR}")"
if [ ! -d "${COCORO_INSTALL_DIR}/.git" ]; then
  git clone --depth 1 "${COCORO_CORE_REPO}" "${COCORO_INSTALL_DIR}" || {
    echo "WARNING: git clone failed. Creating directory only."
    mkdir -p "${COCORO_INSTALL_DIR}"
    echo "CLONE_FAILED=$(date -Iseconds)" > "${COCORO_INSTALL_DIR}/.clone_status"
  }
fi
chown -R "${ADMIN_USER}:${ADMIN_USER}" /opt/cocoro

# ---------------------------------------------------------------------------
# 3. データディレクトリの権限設定
# ---------------------------------------------------------------------------
echo "[3/7] Setting up data directories..."
mkdir -p "${COCORO_DATA_DIR}"/{postgresql,redis,backups,logs,config}

# PostgreSQL: Docker 公式イメージは UID 999 で動作
mkdir -p "${COCORO_DATA_DIR}/postgresql/data"
chown -R 999:999 "${COCORO_DATA_DIR}/postgresql"
chmod 700 "${COCORO_DATA_DIR}/postgresql/data"

# Redis: UID 999
mkdir -p "${COCORO_DATA_DIR}/redis/data"
chown -R 999:999 "${COCORO_DATA_DIR}/redis"
chmod 755 "${COCORO_DATA_DIR}/redis/data"

# 管理ディレクトリ
chown "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_DATA_DIR}/backups"
chown "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_DATA_DIR}/logs"
chown "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_DATA_DIR}/config"
chown "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_DATA_DIR}"

# ---------------------------------------------------------------------------
# 4. カーネルパラメータ最適化
# ---------------------------------------------------------------------------
echo "[4/7] Optimizing kernel parameters..."
cat > /etc/sysctl.d/99-cocoro.conf << 'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
fs.file-max = 65536
vm.swappiness = 10
vm.overcommit_memory = 1
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
EOF
sysctl --system 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. zram 設定
# ---------------------------------------------------------------------------
echo "[5/7] Configuring zram..."
if [ -f /etc/default/zramswap ]; then
  cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=25
PRIORITY=100
EOF
fi

# ---------------------------------------------------------------------------
# 6. ファイアウォール
# ---------------------------------------------------------------------------
echo "[6/7] Configuring firewall..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow ssh >/dev/null 2>&1
ufw allow 5353/udp comment "mDNS" >/dev/null 2>&1
ufw allow 8080/tcp comment "cocoro-core API" >/dev/null 2>&1
ufw allow 8443/tcp comment "cocoro-core API TLS" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 7. cocoro-core コンテナ起動
# ---------------------------------------------------------------------------
echo "[7/7] Starting cocoro-core..."
if [ -f "${COCORO_INSTALL_DIR}/docker-compose.yml" ] || [ -f "${COCORO_INSTALL_DIR}/compose.yml" ]; then
  (cd "${COCORO_INSTALL_DIR}" && docker compose up -d) || echo "WARNING: docker compose up failed"
fi

# ---------------------------------------------------------------------------
# インストーラー情報の保存
# ---------------------------------------------------------------------------
cat > /etc/cocoro-release << EOF
COCORO_OS_VERSION=1.0.0
COCORO_BUILD_DATE=$(date -Iseconds)
COCORO_BASE=debian-trixie
COCORO_INSTALLER_VERSION=1.0.0
COCORO_TARGET_HARDWARE=intel-n95-minipc
EOF

# ---------------------------------------------------------------------------
# systemd ジャーナルサイズ制限
# ---------------------------------------------------------------------------
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/cocoro.conf << 'EOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=30day
Compress=yes
EOF

# ---------------------------------------------------------------------------
# 完了
# ---------------------------------------------------------------------------
systemctl disable cocoro-firstboot.service
echo "========================================="
echo "cocoro-core: First boot setup complete!"
echo "========================================="
echo ""
echo "Access:"
echo "  SSH: ssh cocoro-admin@cocoro.local"
echo "  API: http://cocoro.local:8080"
echo ""
echo "Logs:"
echo "  cat /var/log/cocoro-firstboot.log"
echo "========================================="
echo "Done: $(date)"
