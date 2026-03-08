#!/usr/bin/env bash
# ============================================================================
# cocoro-core: First Boot Setup Script
# ============================================================================
# 実行タイミング: cocoro-firstboot.service (初回起動時のみ)
# 目的: chroot 環境では実行できない初期設定を、実際の OS 起動後に行う
# ============================================================================

set -euo pipefail

readonly LOG_FILE="/var/log/cocoro-firstboot.log"

# ---------------------------------------------------------------------------
# ログ出力関数
# ---------------------------------------------------------------------------
log() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [cocoro-firstboot] $*" | tee -a "${LOG_FILE}"
}

log_error() {
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[${timestamp}] [cocoro-firstboot] [ERROR] $*" | tee -a "${LOG_FILE}" >&2
}

trap 'log_error "スクリプトがエラーで終了しました (行: ${LINENO}, コマンド: ${BASH_COMMAND})"' ERR

# ============================================================================
# メイン処理
# ============================================================================

log "========================================="
log "cocoro-core: 初回起動セットアップ開始"
log "========================================="

# ---------------------------------------------------------------------------
# 1. UFW ファイアウォールの有効化
# ---------------------------------------------------------------------------
# setup.sh でルール定義済み。chroot では D-Bus 不在のため有効化できなかった。
log "[1/4] UFW ファイアウォールを有効化..."

if command -v ufw &> /dev/null; then
  echo "y" | ufw enable
  ufw status verbose | tee -a "${LOG_FILE}"
  log "UFW ファイアウォール有効化完了"
else
  log_error "ufw が見つかりません。スキップします。"
fi

# ---------------------------------------------------------------------------
# 2. Docker サービスの起動確認
# ---------------------------------------------------------------------------
log "[2/4] Docker サービスの確認..."

if systemctl is-active --quiet docker; then
  log "Docker は正常に稼働しています"
  docker --version | tee -a "${LOG_FILE}"
  docker compose version 2>/dev/null | tee -a "${LOG_FILE}" || true
else
  log_error "Docker が起動していません。起動を試みます。"
  systemctl start docker || log_error "Docker の起動に失敗しました"
fi

# ---------------------------------------------------------------------------
# 3. cocoro-core のセットアップ (リポジトリが存在する場合)
# ---------------------------------------------------------------------------
log "[3/4] cocoro-core の初期セットアップ..."

COCORO_DIR="/opt/cocoro/core"
if [ -f "${COCORO_DIR}/docker-compose.yml" ] || [ -f "${COCORO_DIR}/compose.yml" ]; then
  log "docker compose ファイルを検出。コンテナを起動します。"
  (cd "${COCORO_DIR}" && docker compose up -d) || {
    log_error "cocoro-core コンテナの起動に失敗しました"
  }
elif [ -f "${COCORO_DIR}/.clone_status" ]; then
  log_error "cocoro-core のクローンに失敗しています。手動でのセットアップが必要です。"
  cat "${COCORO_DIR}/.clone_status" | tee -a "${LOG_FILE}"
else
  log "cocoro-core の docker compose ファイルが見つかりません。手動セットアップが必要です。"
fi

# ---------------------------------------------------------------------------
# 4. sysctl パラメータの反映
# ---------------------------------------------------------------------------
log "[4/4] kernel パラメータを反映..."

sysctl --system 2>/dev/null | tail -5 | tee -a "${LOG_FILE}" || true

# ============================================================================
# 完了
# ============================================================================
log "========================================="
log "cocoro-core: 初回起動セットアップ完了"
log "========================================="
log ""
log "アクセス方法:"
log "  SSH: ssh cocoro-admin@cocoro.local"
log "  API: http://cocoro.local:8080"
log ""
log "ログ確認:"
log "  cat /var/log/cocoro-firstboot.log"
log "  cat /var/log/cocoro-install.log"
log "========================================="

exit 0
