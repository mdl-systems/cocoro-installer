#!/bin/bash
# ============================================================================
# Cocoro OS — Updater
# ============================================================================
# curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/update.sh | bash
#
# 更新対象:
#   - cocoro-network  (git pull)
#   - cocoro-core     (git pull + docker compose up -d --build)
#   - cocoro-agent    (git pull + docker compose up -d --build)
#   - cocoro-console  (git pull + docker compose up -d --build)
# ============================================================================
set -euo pipefail

# ----------------------------------------------------------------------------
# カラー定義
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }
hr()      { echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"; }

readonly BASE_DIR="/opt/cocoro"
readonly NETWORK_DIR="${BASE_DIR}/network"
readonly CORE_DIR="${BASE_DIR}/core"
readonly AGENT_DIR="${BASE_DIR}/agent"
readonly CONSOLE_DIR="${BASE_DIR}/console"
readonly LOG_FILE="/var/log/cocoro-update.log"

# ----------------------------------------------------------------------------
# バナー
# ----------------------------------------------------------------------------
print_banner() {
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo " ██████╗ ██████╗  ██████╗ ██████╗  ██████╗"
  echo "██╔════╝██╔═══██╗██╔════╝██╔═══██╗██╔═══██╗"
  echo "██║     ██║   ██║██║     ██║   ██║██║   ██║"
  echo "██║     ██║   ██║██║     ██║   ██║██║   ██║"
  echo "╚██████╗╚██████╔╝╚██████╗╚██████╔╝╚██████╔╝"
  echo " ╚═════╝ ╚═════╝  ╚═════╝ ╚═════╝  ╚═════╝"
  echo -e "${RESET}"
  echo -e "        ${BOLD}AI Personality OS Updater v1.0.0${RESET}"
  echo ""
}

# ----------------------------------------------------------------------------
# 前提チェック
# ----------------------------------------------------------------------------
check_prerequisites() {
  step "Prerequisites check"

  if ! command -v docker &>/dev/null; then
    error "Docker が見つかりません。先にインストールしてください"
    exit 1
  fi
  success "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"

  if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 が必要です"
    exit 1
  fi
  success "Docker Compose: $(docker compose version --short)"

  if ! command -v git &>/dev/null; then
    error "git が見つかりません"
    exit 1
  fi
  success "git: $(git --version | cut -d' ' -f3)"

  if [ ! -d "${BASE_DIR}" ]; then
    error "Cocoro OS がインストールされていません: ${BASE_DIR} が見つかりません"
    error "先にインストールしてください: curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/install.sh | bash"
    exit 1
  fi
}

# ----------------------------------------------------------------------------
# サービスアップデート関数
# ----------------------------------------------------------------------------
update_service() {
  local name="$1"
  local dir="$2"

  step "Updating ${name}"

  if [ ! -d "${dir}/.git" ]; then
    warn "${name}: リポジトリが見つかりません (${dir})"
    warn "スキップします。必要なら install.sh を再実行してください"
    return
  fi

  # git pull
  info "git pull: ${dir}"
  local before_hash after_hash
  before_hash=$(git -C "${dir}" rev-parse --short HEAD 2>/dev/null || echo "unknown")

  if git -C "${dir}" pull --ff-only 2>/dev/null; then
    after_hash=$(git -C "${dir}" rev-parse --short HEAD 2>/dev/null || echo "unknown")

    if [[ "${before_hash}" == "${after_hash}" ]]; then
      info "${name}: 既に最新です (${before_hash})"
    else
      success "${name}: 更新完了 ${before_hash} → ${after_hash}"
    fi
  else
    warn "${name}: git pull 失敗 (ローカル変更がある可能性). stash して再試行します..."
    git -C "${dir}" stash 2>/dev/null || true
    git -C "${dir}" pull --ff-only 2>/dev/null || warn "${name}: git pull スキップ"
    after_hash=$(git -C "${dir}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  fi

  # docker compose up -d --build
  if [ -f "${dir}/docker-compose.yml" ] || [ -f "${dir}/compose.yml" ]; then
    info "docker compose up -d --build: ${name}"
    (cd "${dir}" && docker compose up -d --build) && \
      success "${name}: コンテナを更新・再起動しました" || \
      warn "${name}: docker compose up --build 失敗。ログを確認してください"
  else
    info "${name}: docker-compose.yml が見つからないためコンテナ更新をスキップ"
  fi
}

# ----------------------------------------------------------------------------
# ヘルスチェック
# ----------------------------------------------------------------------------
health_check() {
  step "Health check — verifying all services after update"
  hr

  info "サービスの起動を待機しています... (15秒)"
  sleep 15

  local all_ok=true

  # cocoro-core
  echo -n -e "  cocoro-core  (http://localhost:8000/health) ... "
  if curl -sf --max-time 10 "http://localhost:8000/health" &>/dev/null; then
    echo -e "${GREEN}✅  UP${RESET}"
  else
    echo -e "${RED}❌  DOWN${RESET}"
    all_ok=false
  fi

  # cocoro-agent
  echo -n -e "  cocoro-agent (http://localhost:8002/health) ... "
  if curl -sf --max-time 10 "http://localhost:8002/health" &>/dev/null; then
    echo -e "${GREEN}✅  UP${RESET}"
  else
    echo -e "${RED}❌  DOWN${RESET}"
    all_ok=false
  fi

  # cocoro-console
  echo -n -e "  cocoro-console (http://localhost:3000)       ... "
  if curl -sf --max-time 10 "http://localhost:3000" &>/dev/null; then
    echo -e "${GREEN}✅  UP${RESET}"
  else
    echo -e "${RED}❌  DOWN${RESET}"
    all_ok=false
  fi

  echo ""

  if $all_ok; then
    success "全サービスが正常に動作しています 🎉"
  else
    warn "一部のサービスが起動していません"
    warn "ログ確認: docker compose -f ${CORE_DIR}/docker-compose.yml logs --tail=50"
  fi
}

# ----------------------------------------------------------------------------
# 完了メッセージ
# ----------------------------------------------------------------------------
print_summary() {
  local node_ip
  node_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "localhost")

  hr
  echo ""
  echo -e "${BOLD}${GREEN}✅ Cocoro OS のアップデートが完了しました${RESET}"
  echo ""
  echo -e "${BOLD}📍 アクセス方法：${RESET}"
  echo -e "   ブラウザ: ${CYAN}http://${node_ip}${RESET}       (cocoro-console)"
  echo -e "   API:     ${CYAN}http://${node_ip}:8000${RESET}   (cocoro-core)"
  echo -e "   Agent:   ${CYAN}http://${node_ip}:8002${RESET}   (cocoro-agent)"
  echo ""
  echo -e "${BOLD}📚 ドキュメント: ${CYAN}https://docs.cocoro.ai${RESET}"
  echo -e "${BOLD}🐙 GitHub:       ${CYAN}https://github.com/mdl-systems${RESET}"
  echo ""
  echo -e "${BOLD}管理コマンド：${RESET}"
  echo -e "  コンテナ状態確認 : ${YELLOW}docker ps${RESET}"
  echo -e "  core ログ確認   : ${YELLOW}docker compose -f ${CORE_DIR}/docker-compose.yml logs -f${RESET}"
  echo ""
  echo -e "  アップデートログ : ${CYAN}${LOG_FILE}${RESET}"
  hr
}

# ----------------------------------------------------------------------------
# メイン
# ----------------------------------------------------------------------------
main() {
  print_banner

  # ログ設定
  exec > >(tee -a "${LOG_FILE:-/tmp/cocoro-update.log}") 2>&1
  echo "cocoro-updater started: $(date)"

  check_prerequisites

  # 全サービスをアップデート
  update_service "cocoro-network"  "${NETWORK_DIR}"
  update_service "cocoro-core"     "${CORE_DIR}"
  update_service "cocoro-agent"    "${AGENT_DIR}"
  update_service "cocoro-console"  "${CONSOLE_DIR}"

  # 古いイメージのクリーンアップ
  step "Cleaning up old images"
  docker image prune -f 2>/dev/null && success "古いイメージをクリーンアップしました" || true

  health_check
  print_summary
}

main "$@"
