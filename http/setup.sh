#!/usr/bin/env bash
# ============================================================================
# cocoro-installer: Post-Installation Setup Script
# ============================================================================
# 実行タイミング: preseed late_command (in-target) 内
# 目的: Docker 環境構築 + cocoro-core リポジトリ配置
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 定数定義
# ---------------------------------------------------------------------------
readonly LOG_FILE="/var/log/cocoro-install.log"
readonly COCORO_CORE_REPO="https://github.com/mdl-systems/cocoro-core"
readonly COCORO_INSTALL_DIR="/opt/cocoro/core"
readonly COCORO_DATA_DIR="/data/cocoro"
readonly ADMIN_USER="cocoro-admin"
readonly POSTGRES_UID=999
readonly POSTGRES_GID=999

# ---------------------------------------------------------------------------
# ログ出力関数
# ---------------------------------------------------------------------------
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [cocoro-setup] $*" | tee -a "${LOG_FILE}"
}

log_error() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [cocoro-setup] [ERROR] $*" | tee -a "${LOG_FILE}" >&2
}

# ---------------------------------------------------------------------------
# エラーハンドリング
# ---------------------------------------------------------------------------
trap 'log_error "スクリプトがエラーで終了しました (行: ${LINENO}, コマンド: ${BASH_COMMAND})"' ERR

# ============================================================================
# メイン処理
# ============================================================================

log "========================================="
log "cocoro-installer: setup.sh 開始"
log "========================================="

# ---------------------------------------------------------------------------
# 1. Docker のインストール
# ---------------------------------------------------------------------------
log "[1/6] Docker のインストールを開始..."

# 既存の Docker パッケージを削除 (競合防止)
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  apt-get remove -y "${pkg}" 2>/dev/null || true
done

# Docker 公式 GPG キーの追加
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

# Docker APT リポジトリの追加
# Debian 13 (Trixie) の場合、安定版リリースまでは bookworm リポジトリを fallback として使用
DEBIAN_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-trixie}")
# Docker が trixie をサポートしていない場合の fallback
if ! curl -fsSL "https://download.docker.com/linux/debian/dists/${DEBIAN_CODENAME}/Release" > /dev/null 2>&1; then
  log "Docker リポジトリに ${DEBIAN_CODENAME} が存在しません。bookworm にフォールバックします。"
  DEBIAN_CODENAME="bookworm"
fi

cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${DEBIAN_CODENAME} stable
EOF

apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Docker の自動起動を有効化
systemctl enable docker
systemctl enable containerd

# 管理者ユーザーを docker グループに追加
usermod -aG docker "${ADMIN_USER}"

log "[1/6] Docker のインストール完了"

# ---------------------------------------------------------------------------
# 2. Docker デーモン設定
# ---------------------------------------------------------------------------
log "[2/6] Docker デーモン設定..."

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "data-root": "/var/lib/docker",
  "live-restore": true,
  "default-address-pools": [
    {
      "base": "172.20.0.0/16",
      "size": 24
    }
  ]
}
EOF

log "[2/6] Docker デーモン設定完了"

# ---------------------------------------------------------------------------
# 3. cocoro-core リポジトリの Clone
# ---------------------------------------------------------------------------
log "[3/6] cocoro-core リポジトリのクローン..."

mkdir -p "$(dirname "${COCORO_INSTALL_DIR}")"

if command -v git &> /dev/null; then
  if [ ! -d "${COCORO_INSTALL_DIR}/.git" ]; then
    git clone --depth 1 "${COCORO_CORE_REPO}" "${COCORO_INSTALL_DIR}" || {
      log_error "cocoro-core のクローンに失敗しました。ディレクトリのみ作成します。"
      mkdir -p "${COCORO_INSTALL_DIR}"
      echo "CLONE_FAILED=$(date -Iseconds)" > "${COCORO_INSTALL_DIR}/.clone_status"
    }
  else
    log "cocoro-core は既にクローン済みです。pull を実行します。"
    (cd "${COCORO_INSTALL_DIR}" && git pull) || true
  fi
else
  log_error "git が見つかりません。ディレクトリのみ作成します。"
  mkdir -p "${COCORO_INSTALL_DIR}"
fi

# リポジトリ所有権の設定
chown -R "${ADMIN_USER}:${ADMIN_USER}" /opt/cocoro

log "[3/6] cocoro-core リポジトリのクローン完了"

# ---------------------------------------------------------------------------
# 4. データディレクトリの権限設定
# ---------------------------------------------------------------------------
log "[4/6] データディレクトリの権限設定..."

# /data/cocoro 配下のサブディレクトリ構成
mkdir -p "${COCORO_DATA_DIR}"/{postgresql,redis,backups,logs,config}

# PostgreSQL データディレクトリ
# 重要: Docker 公式 PostgreSQL イメージは UID 999 (postgres) で動作する
#       ホストユーザー (cocoro-admin: UID 1000) が所有すると Permission Denied になる
mkdir -p "${COCORO_DATA_DIR}/postgresql/data"
chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "${COCORO_DATA_DIR}/postgresql"
chmod 700 "${COCORO_DATA_DIR}/postgresql/data"

# Redis データディレクトリ (Redis 公式イメージは UID 999 を使用)
mkdir -p "${COCORO_DATA_DIR}/redis/data"
chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "${COCORO_DATA_DIR}/redis"
chmod 755 "${COCORO_DATA_DIR}/redis/data"

# バックアップディレクトリ (管理者ユーザーが操作)
chmod 750 "${COCORO_DATA_DIR}/backups"
chown "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_DATA_DIR}/backups"

# ログディレクトリ
chmod 755 "${COCORO_DATA_DIR}/logs"
chown "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_DATA_DIR}/logs"

# 設定ファイルディレクトリ
chmod 755 "${COCORO_DATA_DIR}/config"
chown "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_DATA_DIR}/config"

# トップレベルディレクトリの所有権
chown "${ADMIN_USER}:${ADMIN_USER}" "${COCORO_DATA_DIR}"

log "[4/6] データディレクトリの権限設定完了"

# ---------------------------------------------------------------------------
# 5. システム設定の最終調整
# ---------------------------------------------------------------------------
log "[5/6] システム設定の最終調整..."

# --- 5a. ファイアウォール (UFW) の設定ファイルのみ作成 ---
# 重要: chroot (in-target) 環境では D-Bus が動いていないため
#       ufw enable はカーネルと通信できず失敗する。
#       ルール定義のみ行い、有効化は firstboot.sh に委譲する。
if command -v ufw &> /dev/null; then
  # UFW ルールの定義 (有効化はしない)
  ufw default deny incoming 2>/dev/null || true
  ufw default allow outgoing 2>/dev/null || true
  ufw allow 22/tcp comment "SSH" 2>/dev/null || true
  ufw allow 5353/udp comment "mDNS (avahi)" 2>/dev/null || true
  ufw allow 8080/tcp comment "cocoro-core API" 2>/dev/null || true
  ufw allow 8443/tcp comment "cocoro-core API (TLS)" 2>/dev/null || true
  log "UFW ルール定義完了 (有効化は初回起動時に実行)"
fi

# --- 5b. systemd の最適化 ---
# ジャーナルのサイズ制限
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/cocoro.conf << 'EOF'
[Journal]
SystemMaxUse=500M
SystemKeepFree=1G
MaxRetentionSec=30day
Compress=yes
EOF

# --- 5c. kernel パラメータの最適化 ---
cat > /etc/sysctl.d/99-cocoro.conf << 'EOF'
# Docker / コンテナ向け最適化
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1

# ファイルディスクリプタ上限
fs.file-max = 65536

# メモリ管理
vm.swappiness = 10
vm.overcommit_memory = 1

# ネットワークバッファ
net.core.somaxconn = 1024
net.ipv4.tcp_max_syn_backlog = 1024
EOF

# --- 5d. zram (圧縮スワップ) の導入 ---
# Swap パーティションは未設定のため、zram-tools で圧縮メモリスワップを提供
# PostgreSQL / Docker のメモリバースト対策
apt-get install -y zram-tools 2>/dev/null || true
if [ -f /etc/default/zramswap ]; then
  cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=25
PRIORITY=100
EOF
  log "zram-tools 設定完了 (RAM の 25% を圧縮スワップとして使用)"
fi

# --- 5e. cocoro-core 初回起動用 systemd サービス ---
cat > /etc/systemd/system/cocoro-firstboot.service << 'EOF'
[Unit]
Description=cocoro-core First Boot Setup
After=network-online.target docker.service
Wants=network-online.target
ConditionPathExists=!/var/lib/cocoro/.firstboot-complete

[Service]
Type=oneshot
ExecStart=/opt/cocoro/core/scripts/firstboot.sh
ExecStartPost=/bin/touch /var/lib/cocoro/.firstboot-complete
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/lib/cocoro
systemctl enable cocoro-firstboot.service 2>/dev/null || true

# --- 5f. cocoro-installer 情報の保存 ---
cat > /etc/cocoro-release << EOF
COCORO_OS_VERSION=1.0.0
COCORO_BUILD_DATE=$(date -Iseconds)
COCORO_BASE=debian-trixie
COCORO_INSTALLER_VERSION=1.0.0
COCORO_TARGET_HARDWARE=intel-n95-minipc
EOF

log "[5/6] システム設定の最終調整完了"

# ---------------------------------------------------------------------------
# 6. クリーンアップ
# ---------------------------------------------------------------------------
log "[6/6] クリーンアップ..."

# APT キャッシュの削除
apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*

# 一時ファイルの削除
rm -f /tmp/setup.sh

log "[6/6] クリーンアップ完了"

# ============================================================================
# 完了
# ============================================================================
log "========================================="
log "cocoro-installer: setup.sh 正常完了"
log "========================================="
log "パーティション構成:"
log "  /boot/efi      : 512MB  (EFI)"
log "  /               : 50GB   (ext4)"
log "  /var/lib/docker : 100GB  (ext4)"
log "  /data/cocoro    : 残り    (ext4)"
log ""
log "インストール済みコンポーネント:"
log "  - Docker CE + Compose Plugin"
log "  - cocoro-core (${COCORO_INSTALL_DIR})"
log "  - avahi-daemon (cocoro.local)"
log "  - UFW ファイアウォール"
log ""
log "次のステップ:"
log "  1. USB を抜き取る"
log "  2. 電源を入れて SSD から起動"
log "  3. ssh cocoro-admin@cocoro.local で接続"
log "========================================="

exit 0
