#!/bin/bash
# ============================================================================
# Cocoro OS — Uninstaller
# ============================================================================
# curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/uninstall.sh | bash
#
# 削除対象:
#   - 全 Cocoro Docker コンテナ
#   - 全 Cocoro Docker イメージ
#   - Docker ボリューム (cocoro-*) 
#   - Docker ネットワーク (cocoro-net)
#   - /opt/cocoro/ 配下のリポジトリ
#
# ⚠️  /data/cocoro/ の永続データは削除しません（--purge で削除可能）
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
readonly DATA_DIR="/data/cocoro"

# ----------------------------------------------------------------------------
# バナー
# ----------------------------------------------------------------------------
print_banner() {
  echo ""
  echo -e "${RED}${BOLD}"
  echo " ██████╗ ██████╗  ██████╗ ██████╗  ██████╗"
  echo "██╔════╝██╔═══██╗██╔════╝██╔═══██╗██╔═══██╗"
  echo "██║     ██║   ██║██║     ██║   ██║██║   ██║"
  echo "██║     ██║   ██║██║     ██║   ██║██║   ██║"
  echo "╚██████╗╚██████╔╝╚██████╗╚██████╔╝╚██████╔╝"
  echo " ╚═════╝ ╚═════╝  ╚═════╝ ╚═════╝  ╚═════╝"
  echo -e "${RESET}"
  echo -e "        ${BOLD}${RED}Cocoro OS — Uninstaller v1.0.0${RESET}"
  echo ""
}

# ----------------------------------------------------------------------------
# 確認プロンプト
# ----------------------------------------------------------------------------
confirm_uninstall() {
  step "Uninstall confirmation"
  hr

  echo ""
  echo -e "${YELLOW}${BOLD}⚠️  以下を削除します：${RESET}"
  echo -e "  • Cocoro Docker コンテナ (cocoro-core, cocoro-agent, cocoro-console 等)"
  echo -e "  • Cocoro Docker イメージ"
  echo -e "  • Cocoro Docker ボリューム (cocoro-*)"
  echo -e "  • Docker ネットワーク (cocoro-net)"
  echo -e "  • ${BASE_DIR}/ 配下のリポジトリ"
  echo ""

  # --purge オプションの確認
  PURGE_DATA=false
  if [[ "${1:-}" == "--purge" ]]; then
    PURGE_DATA=true
    echo -e "${RED}${BOLD}  ⚠️  --purge モード: ${DATA_DIR}/ の永続データも削除されます！${RESET}"
    echo ""
  else
    echo -e "${GREEN}  ✅ ${DATA_DIR}/ の永続データは保持されます${RESET}"
    echo -e "${CYAN}  → 完全削除: uninstall.sh --purge${RESET}"
    echo ""
  fi

  read -r -p "本当に削除しますか？ [y/N]: " CONFIRM
  if [[ ! "${CONFIRM}" =~ ^[Yy]$ ]]; then
    info "アンインストールを中止しました"
    exit 0
  fi
}

# ----------------------------------------------------------------------------
# Cocoro コンテナ停止・削除
# ----------------------------------------------------------------------------
remove_containers() {
  step "Stopping and removing Cocoro containers"

  # cocoro-* パターンのコンテナを検索して停止・削除
  local containers
  containers=$(docker ps -a --filter "name=cocoro" --format "{{.Names}}" 2>/dev/null || true)

  if [[ -z "${containers}" ]]; then
    info "削除対象のコンテナが見つかりません"
    return
  fi

  echo -e "${containers}" | while read -r container; do
    if [[ -n "${container}" ]]; then
      docker stop "${container}" 2>/dev/null && \
        docker rm "${container}" 2>/dev/null && \
        success "コンテナ削除: ${container}" || \
        warn "コンテナ削除エラー: ${container}"
    fi
  done

  # docker compose で起動したサービスも停止
  for dir in "${BASE_DIR}"/{core,agent,console,network}; do
    if [ -f "${dir}/docker-compose.yml" ] || [ -f "${dir}/compose.yml" ]; then
      info "docker compose down: ${dir}"
      (cd "${dir}" && docker compose down --remove-orphans 2>/dev/null) || true
    fi
  done

  success "コンテナ削除完了"
}

# ----------------------------------------------------------------------------
# Cocoro Docker イメージ削除
# ----------------------------------------------------------------------------
remove_images() {
  step "Removing Cocoro Docker images"

  # cocoro-* パターンのイメージを削除
  local images
  images=$(docker images --filter "reference=*cocoro*" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || true)
  images+=$'\n'
  images+=$(docker images --filter "reference=mdl-systems/*" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null || true)

  if [[ -z "$(echo "${images}" | tr -d '[:space:]')" ]]; then
    info "削除対象のイメージが見つかりません"
  else
    echo -e "${images}" | grep -v '^$' | while read -r image; do
      if [[ -n "${image}" ]]; then
        docker rmi "${image}" 2>/dev/null && \
          success "イメージ削除: ${image}" || \
          warn "イメージ削除エラー (使用中の可能性): ${image}"
      fi
    done
  fi

  # ダングリングイメージのクリーンアップ
  docker image prune -f 2>/dev/null && info "ダングリングイメージをクリーンアップしました" || true

  success "イメージ削除完了"
}

# ----------------------------------------------------------------------------
# Cocoro Docker ボリューム削除
# ----------------------------------------------------------------------------
remove_volumes() {
  step "Removing Cocoro Docker volumes"

  local volumes
  volumes=$(docker volume ls --filter "name=cocoro" --format "{{.Name}}" 2>/dev/null || true)

  if [[ -z "${volumes}" ]]; then
    info "削除対象のボリュームが見つかりません"
    return
  fi

  echo -e "${volumes}" | while read -r volume; do
    if [[ -n "${volume}" ]]; then
      docker volume rm "${volume}" 2>/dev/null && \
        success "ボリューム削除: ${volume}" || \
        warn "ボリューム削除エラー: ${volume}"
    fi
  done

  success "ボリューム削除完了"
}

# ----------------------------------------------------------------------------
# Cocoro Docker ネットワーク削除
# ----------------------------------------------------------------------------
remove_network() {
  step "Removing Cocoro Docker network"

  if docker network inspect cocoro-net &>/dev/null; then
    docker network rm cocoro-net 2>/dev/null && \
      success "ネットワーク削除: cocoro-net" || \
      warn "ネットワーク削除エラー (使用中のコンテナがある可能性があります)"
  else
    info "cocoro-net ネットワークは存在しません"
  fi
}

# ----------------------------------------------------------------------------
# /opt/cocoro/ リポジトリ削除
# ----------------------------------------------------------------------------
remove_repos() {
  step "Removing Cocoro repositories from ${BASE_DIR}/"

  if [ -d "${BASE_DIR}" ]; then
    sudo rm -rf "${BASE_DIR}"
    success "削除完了: ${BASE_DIR}/"
  else
    info "${BASE_DIR}/ は存在しません"
  fi
}

# ----------------------------------------------------------------------------
# 永続データ削除 (--purge のみ)
# ----------------------------------------------------------------------------
remove_data() {
  step "Removing persistent data from ${DATA_DIR}/ (--purge)"

  if [ -d "${DATA_DIR}" ]; then
    sudo rm -rf "${DATA_DIR}"
    success "削除完了: ${DATA_DIR}/"
    warn "PostgreSQL・Redis のデータはすべて削除されました"
  else
    info "${DATA_DIR}/ は存在しません"
  fi
}

# ----------------------------------------------------------------------------
# 完了メッセージ
# ----------------------------------------------------------------------------
print_summary() {
  hr
  echo ""
  echo -e "${BOLD}${GREEN}✅ Cocoro OS のアンインストールが完了しました${RESET}"
  echo ""

  if [[ "${PURGE_DATA}" == "false" ]]; then
    echo -e "${BOLD}保持されたデータ：${RESET}"
    echo -e "  📁 ${DATA_DIR}/ (PostgreSQL, Redis データ)"
    echo ""
    echo -e "${CYAN}再インストール時にデータを引き継ぐことができます。${RESET}"
    echo -e "${CYAN}完全削除する場合: sudo rm -rf ${DATA_DIR}${RESET}"
  fi

  echo ""
  echo -e "${BOLD}再インストール：${RESET}"
  echo -e "  ${YELLOW}curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/install.sh | bash${RESET}"
  echo ""
  hr
}

# ----------------------------------------------------------------------------
# メイン
# ----------------------------------------------------------------------------
main() {
  print_banner
  confirm_uninstall "${1:-}"

  remove_containers
  remove_images
  remove_volumes
  remove_network
  remove_repos

  if [[ "${PURGE_DATA}" == "true" ]]; then
    remove_data
  fi

  print_summary
}

main "$@"
