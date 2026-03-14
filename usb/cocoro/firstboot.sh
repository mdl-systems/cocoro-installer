#!/bin/bash
# ============================================================================
# cocoro-installer: First Boot Setup Script
# ============================================================================
# 実行タイミング: cocoro-firstboot.service (初回起動時のみ)
# 目的: ネットワーク接続後に Docker + 全 Cocoro サービスをセットアップ
#
# インストール対象:
#   1. cocoro-network  (Dockerネットワーク)
#   2. cocoro-core     (メインAI / port 8000)
#   3. cocoro-agent    (専門職エージェント / port 8002)
#   4. cocoro-console  (UIコンソール / port 3000)
# ============================================================================
set -euo pipefail
exec > /var/log/cocoro-firstboot.log 2>&1
echo "Cocoro OS first boot: $(date)"

readonly COCORO_BASE_DIR="/opt/cocoro"
readonly COCORO_NETWORK_DIR="${COCORO_BASE_DIR}/network"
readonly COCORO_CORE_DIR="${COCORO_BASE_DIR}/core"
readonly COCORO_AGENT_DIR="${COCORO_BASE_DIR}/agent"
readonly COCORO_CONSOLE_DIR="${COCORO_BASE_DIR}/console"
readonly COCORO_DATA_DIR="/data/cocoro"
readonly ADMIN_USER="cocoro-admin"

# GitHub リポジトリ
readonly REPO_NETWORK="https://github.com/mdl-systems/cocoro-network"
readonly REPO_CORE="https://github.com/mdl-systems/cocoro-core"
readonly REPO_AGENT="https://github.com/mdl-systems/cocoro-agent"
readonly REPO_CONSOLE="https://github.com/mdl-systems/cocoro-console"

# ---------------------------------------------------------------------------
# 0. ネットワーク待機
# ---------------------------------------------------------------------------
echo "[0/9] Waiting for network..."
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
echo "[1/9] Installing Docker..."
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
# 2. ディレクトリセットアップ
# ---------------------------------------------------------------------------
echo "[2/9] Setting up directories..."
mkdir -p "${COCORO_BASE_DIR}" "${COCORO_DATA_DIR}"/{postgresql/data,redis/data,backups,logs,config}

# PostgreSQL: Docker 公式イメージは UID 999 で動作
chown -R 999:999 "${COCORO_DATA_DIR}/postgresql"
chmod 700 "${COCORO_DATA_DIR}/postgresql/data"

# Redis: UID 999
chown -R 999:999 "${COCORO_DATA_DIR}/redis"
chmod 755 "${COCORO_DATA_DIR}/redis/data"

# 管理ディレクトリ
chown "${ADMIN_USER}:${ADMIN_USER}" \
  "${COCORO_DATA_DIR}/backups" \
  "${COCORO_DATA_DIR}/logs" \
  "${COCORO_DATA_DIR}/config" \
  "${COCORO_DATA_DIR}" \
  "${COCORO_BASE_DIR}"

# ---------------------------------------------------------------------------
# 3. カーネルパラメータ最適化
# ---------------------------------------------------------------------------
echo "[3/9] Optimizing kernel parameters..."
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
# 4. zram 設定
# ---------------------------------------------------------------------------
echo "[4/9] Configuring zram..."
if [ -f /etc/default/zramswap ]; then
  cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=25
PRIORITY=100
EOF
fi

# ---------------------------------------------------------------------------
# 5. ファイアウォール
# ---------------------------------------------------------------------------
echo "[5/9] Configuring firewall..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow ssh >/dev/null 2>&1
ufw allow 5353/udp comment "mDNS" >/dev/null 2>&1
ufw allow 8000/tcp comment "cocoro-core API" >/dev/null 2>&1
ufw allow 8002/tcp comment "cocoro-agent API" >/dev/null 2>&1
ufw allow 3000/tcp comment "cocoro-console UI" >/dev/null 2>&1
# 後方互換
ufw allow 8080/tcp comment "cocoro-core API (legacy)" >/dev/null 2>&1
ufw allow 8443/tcp comment "cocoro-core API TLS (legacy)" >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 6. cocoro-network (Dockerネットワーク + リポジトリ)
# ---------------------------------------------------------------------------
echo "[6/9] Setting up cocoro-network..."

# Docker ネットワーク作成
if ! docker network inspect cocoro-net >/dev/null 2>&1; then
  docker network create \
    --driver bridge \
    --subnet 172.20.0.0/16 \
    --opt com.docker.network.bridge.name=cocoro-net \
    cocoro-net
  echo "  → cocoro-net ネットワークを作成しました"
fi

# cocoro-network リポジトリ
if [ ! -d "${COCORO_NETWORK_DIR}/.git" ]; then
  git clone --depth 1 "${REPO_NETWORK}" "${COCORO_NETWORK_DIR}" || {
    echo "  WARNING: cocoro-network クローン失敗"
    mkdir -p "${COCORO_NETWORK_DIR}"
  }
fi
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_NETWORK_DIR}" || true

# ---------------------------------------------------------------------------
# 7. cocoro-core (メインAI)
# ---------------------------------------------------------------------------
echo "[7/9] Setting up cocoro-core..."
if [ ! -d "${COCORO_CORE_DIR}/.git" ]; then
  git clone --depth 1 "${REPO_CORE}" "${COCORO_CORE_DIR}" || {
    echo "  WARNING: cocoro-core クローン失敗"
    mkdir -p "${COCORO_CORE_DIR}"
    echo "CLONE_FAILED=$(date -Iseconds)" > "${COCORO_CORE_DIR}/.clone_status"
  }
fi
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_CORE_DIR}"

# cocoro-core の起動
if [ -f "${COCORO_CORE_DIR}/docker-compose.yml" ] || [ -f "${COCORO_CORE_DIR}/compose.yml" ]; then
  (cd "${COCORO_CORE_DIR}" && docker compose up -d) || \
    echo "  WARNING: cocoro-core docker compose up 失敗"
fi

# ---------------------------------------------------------------------------
# 8. cocoro-agent + cocoro-console
# ---------------------------------------------------------------------------
echo "[8/9] Setting up cocoro-agent and cocoro-console..."

# cocoro-agent
if [ ! -d "${COCORO_AGENT_DIR}/.git" ]; then
  git clone --depth 1 "${REPO_AGENT}" "${COCORO_AGENT_DIR}" || {
    echo "  WARNING: cocoro-agent クローン失敗"
    mkdir -p "${COCORO_AGENT_DIR}"
  }
fi
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_AGENT_DIR}" || true

if [ -f "${COCORO_AGENT_DIR}/docker-compose.yml" ] || [ -f "${COCORO_AGENT_DIR}/compose.yml" ]; then
  (cd "${COCORO_AGENT_DIR}" && docker compose up -d) || \
    echo "  WARNING: cocoro-agent docker compose up 失敗"
fi

# cocoro-console
if [ ! -d "${COCORO_CONSOLE_DIR}/.git" ]; then
  git clone --depth 1 "${REPO_CONSOLE}" "${COCORO_CONSOLE_DIR}" || {
    echo "  WARNING: cocoro-console クローン失敗"
    mkdir -p "${COCORO_CONSOLE_DIR}"
  }
fi
chown -R "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_CONSOLE_DIR}" || true

if [ -f "${COCORO_CONSOLE_DIR}/docker-compose.yml" ] || [ -f "${COCORO_CONSOLE_DIR}/compose.yml" ]; then
  (cd "${COCORO_CONSOLE_DIR}" && docker compose up -d) || \
    echo "  WARNING: cocoro-console docker compose up 失敗"
fi

# ---------------------------------------------------------------------------
# 9. インストーラー情報の保存
# ---------------------------------------------------------------------------
echo "[9/9] Finalizing..."
cat > /etc/cocoro-release << EOF
COCORO_OS_VERSION=2.0.0
COCORO_BUILD_DATE=$(date -Iseconds)
COCORO_BASE=debian-trixie
COCORO_INSTALLER_VERSION=2.0.0
COCORO_TARGET_HARDWARE=intel-n95-minipc
COCORO_SERVICES=network,core,agent,console
EOF

# systemd ジャーナルサイズ制限
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
echo "Cocoro OS: First boot setup complete! 🎉"
echo "========================================="
echo ""
echo "Services:"
echo "  🤖 cocoro-core    : http://cocoro.local:8000"
echo "  🦾 cocoro-agent   : http://cocoro.local:8002"
echo "  🖥️  cocoro-console : http://cocoro.local:3000"
echo ""
echo "Health check:"
echo "  curl http://localhost:8000/health   # cocoro-core"
echo "  curl http://localhost:8002/health   # cocoro-agent"
echo "  curl http://localhost:3000          # cocoro-console"
echo ""
echo "Logs:"
echo "  cat /var/log/cocoro-firstboot.log"
echo "========================================="
echo "Done: $(date)"
