#!/bin/bash
# ============================================================================
# Cocoro OS — Full Stack Installer
# ============================================================================
# curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/install.sh | bash
#
# 自動インストール対象:
#   1. cocoro-network  (Dockerネットワーク)
#   2. cocoro-core     (メインAI / port 8000)
#   3. cocoro-agent    (専門職エージェント / port 8002)
#   4. cocoro-console  (UIコンソール / port 3000)
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

# ----------------------------------------------------------------------------
# ユーティリティ
# ----------------------------------------------------------------------------
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}"; }
hr()      { echo -e "${CYAN}$(printf '─%.0s' {1..60})${RESET}"; }

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
  echo -e "        ${BOLD}AI Personality OS Installer v1.0.0${RESET}"
  echo ""
}

# ----------------------------------------------------------------------------
# 前提チェック
# ----------------------------------------------------------------------------
check_prerequisites() {
  step "Prerequisites check"

  # OS
  if [[ "$(uname -s)" != "Linux" ]]; then
    error "Linux が必要です (現在: $(uname -s))"
    exit 1
  fi

  # Docker
  if ! command -v docker &>/dev/null; then
    warn "Docker が見つかりません。インストールします..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER" || true
    success "Docker をインストールしました"
  else
    success "Docker: $(docker --version | cut -d' ' -f3 | tr -d ',')"
  fi

  # Docker Compose
  if ! docker compose version &>/dev/null; then
    error "Docker Compose v2 が必要です"
    exit 1
  fi
  success "Docker Compose: $(docker compose version --short)"

  # curl
  if ! command -v curl &>/dev/null; then
    error "curl が必要です: sudo apt-get install -y curl"
    exit 1
  fi
  success "curl: $(curl --version | head -1 | cut -d' ' -f2)"

  # git
  if ! command -v git &>/dev/null; then
    warn "git が見つかりません。インストールします..."
    sudo apt-get install -y git
  fi
  success "git: $(git --version | cut -d' ' -f3)"
}

# ----------------------------------------------------------------------------
# インタラクティブセットアップ
# ----------------------------------------------------------------------------
interactive_setup() {
  step "Interactive setup — API keys & configuration"
  hr

  echo ""
  echo -e "${BOLD}Cocoro OS の設定を行います。${RESET}"
  echo -e "${YELLOW}これらの値は .env ファイルに保存されます。${RESET}"
  echo ""

  # GEMINI_API_KEY
  echo -e "${BOLD}GEMINI_API_KEY を入力してください：${RESET}"
  echo -e "${CYAN}  → Google AI Studio (https://aistudio.google.com) から取得${RESET}"
  read -r -p "  GEMINI_API_KEY: " GEMINI_API_KEY
  while [[ -z "${GEMINI_API_KEY}" ]]; do
    warn "GEMINI_API_KEY は必須です"
    read -r -p "  GEMINI_API_KEY: " GEMINI_API_KEY
  done

  echo ""

  # MINIPC_IP
  echo -e "${BOLD}miniPC の IP アドレス（例: 192.168.50.92）：${RESET}"
  echo -e "${CYAN}  → ip addr show | grep 'inet ' で確認できます${RESET}"
  read -r -p "  MINIPC_IP: " MINIPC_IP
  # デフォルト: 現在のマシンのIPを自動検出
  if [[ -z "${MINIPC_IP}" ]]; then
    MINIPC_IP=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "127.0.0.1")
    info "自動検出: ${MINIPC_IP}"
  fi

  echo ""

  # COCORO_API_KEY
  echo -e "${BOLD}API キーを設定してください（デフォルト: cocoro-2026）：${RESET}"
  echo -e "${CYAN}  → クライアントアプリからの接続に使用します${RESET}"
  read -r -p "  COCORO_API_KEY [cocoro-2026]: " COCORO_API_KEY
  COCORO_API_KEY="${COCORO_API_KEY:-cocoro-2026}"

  echo ""
  hr

  # 確認表示
  echo -e "\n${BOLD}設定確認：${RESET}"
  echo -e "  GEMINI_API_KEY : ${GREEN}${GEMINI_API_KEY:0:8}...（マスク済み）${RESET}"
  echo -e "  MINIPC_IP      : ${GREEN}${MINIPC_IP}${RESET}"
  echo -e "  COCORO_API_KEY : ${GREEN}${COCORO_API_KEY}${RESET}"
  echo ""
  read -r -p "この設定で続行しますか？ [Y/n]: " CONFIRM
  CONFIRM="${CONFIRM:-Y}"
  if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    info "インストールを中止しました"
    exit 0
  fi
}

# ----------------------------------------------------------------------------
# ディレクトリ・環境設定
# ----------------------------------------------------------------------------
readonly BASE_DIR="/opt/cocoro"
readonly NETWORK_DIR="${BASE_DIR}/network"
readonly CORE_DIR="${BASE_DIR}/core"
readonly AGENT_DIR="${BASE_DIR}/agent"
readonly CONSOLE_DIR="${BASE_DIR}/console"
readonly DATA_DIR="/data/cocoro"
readonly LOG_FILE="/var/log/cocoro-install.log"

setup_directories() {
  step "Setting up directories"

  sudo mkdir -p "${BASE_DIR}" "${DATA_DIR}"/{postgresql/data,redis/data,backups,logs,config}

  # PostgreSQL (UID 999)
  sudo chown -R 999:999 "${DATA_DIR}/postgresql"
  sudo chmod 700 "${DATA_DIR}/postgresql/data"

  # Redis (UID 999)
  sudo chown -R 999:999 "${DATA_DIR}/redis"
  sudo chmod 755 "${DATA_DIR}/redis/data"

  # 管理ユーザー
  sudo chown -R "${USER}:${USER}" "${BASE_DIR}" "${DATA_DIR}/backups" "${DATA_DIR}/logs" "${DATA_DIR}/config"

  success "ディレクトリ作成完了: ${BASE_DIR}, ${DATA_DIR}"
}

# ----------------------------------------------------------------------------
# Step 1: cocoro-network (Dockerネットワーク作成)
# ----------------------------------------------------------------------------
install_network() {
  step "Step 1/4 — cocoro-network (Docker network)"

  # cocoro-net ネットワーク
  if docker network inspect cocoro-net &>/dev/null; then
    info "cocoro-net ネットワークは既に存在します"
  else
    docker network create \
      --driver bridge \
      --subnet 172.20.0.0/16 \
      --opt com.docker.network.bridge.name=cocoro-net \
      cocoro-net
    success "cocoro-net ネットワークを作成しました"
  fi

  # cocoro-network リポジトリのクローン（docker-compose.yml等）
  if [ ! -d "${NETWORK_DIR}/.git" ]; then
    git clone --depth 1 https://github.com/mdl-systems/cocoro-network "${NETWORK_DIR}" || {
      mkdir -p "${NETWORK_DIR}"
      warn "cocoro-network リポジトリのクローンをスキップしました"
    }
  else
    info "cocoro-network は既にクローン済みです"
  fi

  success "cocoro-network セットアップ完了"
}

# ----------------------------------------------------------------------------
# Step 2: cocoro-core (メインAI)
# ----------------------------------------------------------------------------
install_core() {
  step "Step 2/4 — cocoro-core (Main AI / port 8000)"

  # クローン
  if [ ! -d "${CORE_DIR}/.git" ]; then
    git clone --depth 1 https://github.com/mdl-systems/cocoro-core "${CORE_DIR}"
    success "cocoro-core をクローンしました"
  else
    info "cocoro-core は既にクローン済みです。更新します..."
    (cd "${CORE_DIR}" && git pull --ff-only) || true
  fi

  # .env 生成
  cat > "${CORE_DIR}/.env" <<EOF
# cocoro-core environment
# Generated by cocoro-installer on $(date -Iseconds)

GEMINI_API_KEY=${GEMINI_API_KEY}
COCORO_API_KEY=${COCORO_API_KEY}
MINIPC_IP=${MINIPC_IP}

# Database
DATABASE_URL=postgresql://cocoro:cocoro-db-2026@postgres:5432/cocoro
REDIS_URL=redis://redis:6379

# Paths
COCORO_DATA_DIR=${DATA_DIR}

# Network
NETWORK_NAME=cocoro-net
EOF
  success ".env を生成しました: ${CORE_DIR}/.env"

  # Docker起動
  if [ -f "${CORE_DIR}/docker-compose.yml" ] || [ -f "${CORE_DIR}/compose.yml" ]; then
    (cd "${CORE_DIR}" && docker compose up -d) && success "cocoro-core コンテナ起動"
  else
    warn "docker-compose.yml が見つかりません。手動で起動してください: cd ${CORE_DIR} && docker compose up -d"
  fi
}

# ----------------------------------------------------------------------------
# Step 3: cocoro-agent (専門職エージェント)
# ----------------------------------------------------------------------------
install_agent() {
  step "Step 3/4 — cocoro-agent (Specialist agents / port 8002)"

  # クローン
  if [ ! -d "${AGENT_DIR}/.git" ]; then
    git clone --depth 1 https://github.com/mdl-systems/cocoro-agent "${AGENT_DIR}"
    success "cocoro-agent をクローンしました"
  else
    info "cocoro-agent は既にクローン済みです。更新します..."
    (cd "${AGENT_DIR}" && git pull --ff-only) || true
  fi

  # .env 生成
  cat > "${AGENT_DIR}/.env" <<EOF
# cocoro-agent environment
# Generated by cocoro-installer on $(date -Iseconds)

GEMINI_API_KEY=${GEMINI_API_KEY}
COCORO_API_KEY=${COCORO_API_KEY}
COCORO_CORE_URL=http://cocoro-core:8000
MINIPC_IP=${MINIPC_IP}

# Network
NETWORK_NAME=cocoro-net
EOF
  success ".env を生成しました: ${AGENT_DIR}/.env"

  # Docker起動
  if [ -f "${AGENT_DIR}/docker-compose.yml" ] || [ -f "${AGENT_DIR}/compose.yml" ]; then
    (cd "${AGENT_DIR}" && docker compose up -d) && success "cocoro-agent コンテナ起動"
  else
    warn "docker-compose.yml が見つかりません。手動で起動してください: cd ${AGENT_DIR} && docker compose up -d"
  fi
}

# ----------------------------------------------------------------------------
# Step 4: cocoro-console (UIコンソール)
# ----------------------------------------------------------------------------
install_console() {
  step "Step 4/4 — cocoro-console (UI Console / port 3000)"

  # クローン
  if [ ! -d "${CONSOLE_DIR}/.git" ]; then
    git clone --depth 1 https://github.com/mdl-systems/cocoro-console "${CONSOLE_DIR}"
    success "cocoro-console をクローンしました"
  else
    info "cocoro-console は既にクローン済みです。更新します..."
    (cd "${CONSOLE_DIR}" && git pull --ff-only) || true
  fi

  # .env 生成
  cat > "${CONSOLE_DIR}/.env" <<EOF
# cocoro-console environment
# Generated by cocoro-installer on $(date -Iseconds)

COCORO_API_KEY=${COCORO_API_KEY}
COCORO_CORE_URL=http://cocoro-core:8000
COCORO_AGENT_URL=http://cocoro-agent:8002
NEXT_PUBLIC_API_BASE=http://${MINIPC_IP}

# Network
NETWORK_NAME=cocoro-net
EOF
  success ".env を生成しました: ${CONSOLE_DIR}/.env"

  # Docker起動
  if [ -f "${CONSOLE_DIR}/docker-compose.yml" ] || [ -f "${CONSOLE_DIR}/compose.yml" ]; then
    (cd "${CONSOLE_DIR}" && docker compose up -d) && success "cocoro-console コンテナ起動"
  else
    warn "docker-compose.yml が見つかりません。手動で起動してください: cd ${CONSOLE_DIR} && docker compose up -d"
  fi
}

# ----------------------------------------------------------------------------
# ヘルスチェック
# ----------------------------------------------------------------------------
health_check() {
  step "Health check — verifying all services"
  hr

  # 少し待機してコンテナが起動するのを確認
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
    warn "一部のサービスが起動していません。"
    warn "ログを確認: docker compose -f ${CORE_DIR}/docker-compose.yml logs"
    warn "対象のサービスが docker-compose.yml を持っているか確認してください。"
  fi
}

# ----------------------------------------------------------------------------
# 完了メッセージ
# ----------------------------------------------------------------------------
print_summary() {
  local node_ip
  node_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "${MINIPC_IP}")

  hr
  echo ""
  echo -e "${BOLD}${GREEN}✅ インストール完了！${RESET}"
  echo ""
  echo -e "${BOLD}📍 アクセス方法：${RESET}"
  echo -e "   ブラウザ: ${CYAN}http://${node_ip}${RESET}       (cocoro-console)"
  echo -e "   API:     ${CYAN}http://${node_ip}:8000${RESET}   (cocoro-core)"
  echo -e "   Agent:   ${CYAN}http://${node_ip}:8002${RESET}   (cocoro-agent)"
  echo ""
  echo -e "${BOLD}🚀 次のステップ：${RESET}"
  echo -e "   1. ブラウザでアクセス → ${CYAN}http://${node_ip}${RESET}"
  echo -e "   2. Boot Wizard で人格設定（40問）"
  echo -e "   3. AI と会話を始めよう！"
  echo ""
  echo -e "${BOLD}📚 ドキュメント: ${CYAN}https://docs.cocoro.ai${RESET}"
  echo -e "${BOLD}🐙 GitHub:       ${CYAN}https://github.com/mdl-systems${RESET}"
  echo ""
  echo -e "${BOLD}管理コマンド：${RESET}"
  echo -e "  全サービス状態確認 : ${YELLOW}docker ps${RESET}"
  echo -e "  アップデート       : ${YELLOW}curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/update.sh | bash${RESET}"
  echo -e "  アンインストール   : ${YELLOW}curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/uninstall.sh | bash${RESET}"
  echo ""
  hr
}

# ----------------------------------------------------------------------------
# メイン
# ----------------------------------------------------------------------------
main() {
  print_banner

  # ログ設定（tee でファイルにも出力）
  exec > >(tee -a "${LOG_FILE:-/tmp/cocoro-install.log}") 2>&1
  echo "cocoro-installer started: $(date)"

  check_prerequisites
  interactive_setup
  setup_directories

  install_network
  install_core
  install_agent
  install_console

  health_check
  print_summary
}

main "$@"
