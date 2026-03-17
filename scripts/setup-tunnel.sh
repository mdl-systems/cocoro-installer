#!/bin/bash
# ============================================================================
# cocoro-installer: Cloudflare Tunnel Auto-Setup Script
# ============================================================================
# 用途:
#   Cloudflare Tunnel を自動作成し、Cocoro OS を外部から安全にアクセス可能にする。
#   各ノードにユニークなサブドメイン ({NODE_ID}.cocoro-os.com) を割り当てる。
#
# 実行方法:
#   sudo ./scripts/setup-tunnel.sh
#
# 必須環境変数（出荷前に /etc/cocoro-tunnel.env に記載）:
#   CLOUDFLARE_API_TOKEN    - Cloudflare API トークン
#   CLOUDFLARE_ACCOUNT_ID  - Cloudflare アカウント ID
#   CLOUDFLARE_ZONE_ID     - cocoro-os.com の Zone ID
#
# install.sh から呼び出す場合:
#   CLOUDFLARE_API_TOKEN=xxx \
#   CLOUDFLARE_ACCOUNT_ID=yyy \
#   CLOUDFLARE_ZONE_ID=zzz \
#   ./scripts/setup-tunnel.sh
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

# ----------------------------------------------------------------------------
# 定数
# ----------------------------------------------------------------------------
readonly TUNNEL_ENV_FILE="/etc/cocoro-tunnel.env"
readonly TUNNEL_CONFIG_DIR="/etc/cloudflared"
readonly TUNNEL_CREDENTIALS_DIR="/etc/cloudflared/credentials"
readonly TUNNEL_LOG_FILE="/var/log/cocoro-tunnel-setup.log"
readonly COCORO_DOMAIN="cocoro-os.com"
readonly ADMIN_USER="${SUDO_USER:-cocoro-admin}"

# ロギング
exec > >(tee -a "${TUNNEL_LOG_FILE}") 2>&1
echo "cocoro-tunnel-setup started: $(date)"

# ----------------------------------------------------------------------------
# エラーハンドリング
# ----------------------------------------------------------------------------
trap 'error "スクリプトがエラーで終了しました (行: ${LINENO}, コマンド: ${BASH_COMMAND})"' ERR

# ============================================================================
# 1. 環境変数の読み込みと検証
# ============================================================================
load_and_validate_env() {
  step "Step 1/6 — Loading configuration"

  # /etc/cocoro-tunnel.env が存在すれば読み込む（出荷時設定ファイル）
  if [ -f "${TUNNEL_ENV_FILE}" ]; then
    info "設定ファイルを読み込みます: ${TUNNEL_ENV_FILE}"
    # shellcheck source=/dev/null
    source "${TUNNEL_ENV_FILE}"
  fi

  # 必須変数チェック
  local missing=false
  for var in CLOUDFLARE_API_TOKEN CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_ZONE_ID; do
    if [ -z "${!var:-}" ]; then
      error "環境変数 ${var} が設定されていません"
      missing=true
    fi
  done

  if $missing; then
    echo ""
    error "必須環境変数が不足しています。以下のいずれかで設定してください："
    echo ""
    echo -e "  ${YELLOW}# 方法1: 環境変数として渡す${RESET}"
    echo -e "  CLOUDFLARE_API_TOKEN=xxxx \\"
    echo -e "  CLOUDFLARE_ACCOUNT_ID=yyyy \\"
    echo -e "  CLOUDFLARE_ZONE_ID=zzzz \\"
    echo -e "  sudo ./scripts/setup-tunnel.sh"
    echo ""
    echo -e "  ${YELLOW}# 方法2: 設定ファイルに保存（出荷時設定）${RESET}"
    echo -e "  sudo tee ${TUNNEL_ENV_FILE} << 'EOF'"
    echo -e "  CLOUDFLARE_API_TOKEN=xxxx"
    echo -e "  CLOUDFLARE_ACCOUNT_ID=yyyy"
    echo -e "  CLOUDFLARE_ZONE_ID=zzzz"
    echo -e "  EOF"
    echo ""
    exit 1
  fi

  success "設定読み込み完了"
}

# ============================================================================
# 2. ユニーク NODE_ID の生成
# ============================================================================
generate_node_id() {
  step "Step 2/6 — Generating unique Node ID"

  # 既存の NODE_ID があれば再利用（再実行対応）
  if [ -f "/etc/cocoro-node-id" ]; then
    NODE_ID=$(cat /etc/cocoro-node-id)
    info "既存の NODE_ID を使用します: ${NODE_ID}"
  else
    # /dev/urandom から 6文字の英小文字+数字を生成
    NODE_ID=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
    echo "${NODE_ID}" > /etc/cocoro-node-id
    chmod 644 /etc/cocoro-node-id
    success "NODE_ID を生成しました: ${NODE_ID}"
  fi

  # Tunnel 名とドメインを設定
  readonly TUNNEL_NAME="cocoro-${NODE_ID}"
  readonly TUNNEL_HOSTNAME="${NODE_ID}.${COCORO_DOMAIN}"

  info "Tunnel名    : ${TUNNEL_NAME}"
  info "サブドメイン: https://${TUNNEL_HOSTNAME}"
}

# ============================================================================
# 3. cloudflared のインストール（Debian/Ubuntu 対応）
# ============================================================================
install_cloudflared() {
  step "Step 3/6 — Installing cloudflared"

  # 既にインストール済みかチェック
  if command -v cloudflared &>/dev/null; then
    local version
    version=$(cloudflared --version 2>&1 | head -1 | awk '{print $3}')
    info "cloudflared は既にインストールされています: ${version}"
    return
  fi

  # OS 判別
  local arch
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "${arch}" in
    amd64|x86_64) arch="amd64" ;;
    arm64|aarch64) arch="arm64" ;;
    armhf|armv7l)  arch="arm"  ;;
    *)
      error "未対応のアーキテクチャ: ${arch}"
      exit 1
      ;;
  esac

  info "アーキテクチャ: ${arch}"

  if command -v apt-get &>/dev/null; then
    # Debian/Ubuntu — 公式パッケージリポジトリを使用
    info "Cloudflare 公式リポジトリを追加しています..."

    mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | tee /etc/apt/keyrings/cloudflare-main.gpg >/dev/null

    echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared $(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}") main" \
      | tee /etc/apt/sources.list.d/cloudflared.list

    apt-get update -y -q
    apt-get install -y cloudflared
    success "cloudflared をパッケージからインストールしました"

  else
    # フォールバック: バイナリ直接ダウンロード
    info "バイナリを直接ダウンロードしています..."
    local bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    curl -fsSL "${bin_url}" -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
    success "cloudflared をバイナリとしてインストールしました"
  fi

  # バージョン確認
  local version
  version=$(cloudflared --version 2>&1 | head -1)
  success "cloudflared インストール完了: ${version}"
}

# ============================================================================
# 4. Cloudflare API 経由で Tunnel 自動作成
# ============================================================================
create_tunnel() {
  step "Step 4/6 — Creating Cloudflare Tunnel via API"

  local api_base="https://api.cloudflare.com/client/v4"
  local auth_header="Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"

  # ディレクトリ準備
  mkdir -p "${TUNNEL_CONFIG_DIR}" "${TUNNEL_CREDENTIALS_DIR}"
  chmod 700 "${TUNNEL_CREDENTIALS_DIR}"

  # --- 4a. 既存 Tunnel の確認 ---
  info "既存の Tunnel を確認しています..."

  local existing_id
  existing_id=$(curl -fsSL -X GET \
    "${api_base}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" \
    -H "${auth_header}" \
    -H "Content-Type: application/json" \
    | python3 -c "import sys,json; r=json.load(sys.stdin)['result']; print(r[0]['id'] if r else '')" \
    2>/dev/null || echo "")

  if [ -n "${existing_id}" ]; then
    TUNNEL_ID="${existing_id}"
    info "既存の Tunnel を再利用します: ${TUNNEL_ID}"
  else
    # --- 4b. 新規 Tunnel 作成 ---
    info "新規 Tunnel を作成しています: ${TUNNEL_NAME}"

    # Tunnel シークレット（32バイトのランダム値をBase64エンコード）
    local tunnel_secret
    tunnel_secret=$(openssl rand -base64 32)

    local create_response
    create_response=$(curl -fsSL -X POST \
      "${api_base}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" \
      -H "${auth_header}" \
      -H "Content-Type: application/json" \
      --data "{
        \"name\": \"${TUNNEL_NAME}\",
        \"tunnel_secret\": \"${tunnel_secret}\"
      }")

    # レスポンス検証
    local success_flag
    success_flag=$(echo "${create_response}" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

    if [ "${success_flag}" != "True" ]; then
      error "Tunnel 作成に失敗しました"
      error "レスポンス: ${create_response}"
      exit 1
    fi

    TUNNEL_ID=$(echo "${create_response}" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['result']['id'])")

    # Credentials ファイルを保存
    local cred_file="${TUNNEL_CREDENTIALS_DIR}/${TUNNEL_ID}.json"
    echo "${create_response}" | python3 -c \
      "import sys,json; r=json.load(sys.stdin)['result']; print(json.dumps({'AccountTag': r.get('account_tag',''), 'TunnelID': r['id'], 'TunnelName': r['name'], 'TunnelSecret': '${tunnel_secret}'}))" \
      > "${cred_file}"
    chmod 600 "${cred_file}"

    success "Tunnel 作成完了: ${TUNNEL_NAME} (ID: ${TUNNEL_ID})"
  fi

  # Tunnel ID を保存
  echo "${TUNNEL_ID}" > /etc/cocoro-tunnel-id
  chmod 644 /etc/cocoro-tunnel-id

  # --- 4c. DNS CNAME レコードの作成 ---
  info "DNS CNAME レコードを設定しています: ${TUNNEL_HOSTNAME}"

  local cname_response
  cname_response=$(curl -fsSL -X POST \
    "${api_base}/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
    -H "${auth_header}" \
    -H "Content-Type: application/json" \
    --data "{
      \"type\": \"CNAME\",
      \"name\": \"${NODE_ID}\",
      \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
      \"ttl\": 1,
      \"proxied\": true,
      \"comment\": \"Auto-created by cocoro-installer for node ${NODE_ID}\"
    }" 2>/dev/null || echo '{"success":false}')

  local dns_success
  dns_success=$(echo "${cname_response}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

  if [ "${dns_success}" == "True" ]; then
    success "DNS レコード作成完了: ${TUNNEL_HOSTNAME}"
  else
    # 既存レコードの場合はエラーでなく警告
    local cname_error
    cname_error=$(echo "${cname_response}" | python3 -c \
      "import sys,json; r=json.load(sys.stdin).get('errors',[]); print(r[0].get('message','') if r else '')" \
      2>/dev/null || echo "")
    if echo "${cname_error}" | grep -qi "already exists"; then
      warn "DNS レコードは既に存在します（スキップ）"
    else
      warn "DNS レコード作成に失敗しました: ${cname_error}"
      warn "手動で CNAME ${NODE_ID} → ${TUNNEL_ID}.cfargotunnel.com を設定してください"
    fi
  fi
}

# ============================================================================
# 5. cloudflared 設定ファイルの作成と systemd 登録
# ============================================================================
configure_and_register() {
  step "Step 5/6 — Configuring cloudflared and registering systemd service"

  local cred_file="${TUNNEL_CREDENTIALS_DIR}/${TUNNEL_ID}.json"
  local config_file="${TUNNEL_CONFIG_DIR}/config.yml"

  # --- 5a. cloudflared 設定ファイル ---
  cat > "${config_file}" << EOF
# cloudflared configuration
# Auto-generated by cocoro-installer on $(date -Iseconds)
# Node: ${TUNNEL_NAME} (${TUNNEL_HOSTNAME})

tunnel: ${TUNNEL_ID}
credentials-file: ${cred_file}

ingress:
  # cocoro-console (Primary UI)
  - hostname: ${TUNNEL_HOSTNAME}
    service: http://localhost:3000

  # cocoro-core API
  - hostname: api.${TUNNEL_HOSTNAME}
    service: http://localhost:8000

  # cocoro-agent API
  - hostname: agent.${TUNNEL_HOSTNAME}
    service: http://localhost:8002

  # Catch-all: 404
  - service: http_status:404
EOF

  chmod 644 "${config_file}"
  success "設定ファイルを作成しました: ${config_file}"

  # --- 5b. cloudflared の所有者設定 ---
  chown -R root:root "${TUNNEL_CONFIG_DIR}"
  chmod 755 "${TUNNEL_CONFIG_DIR}"
  chmod 700 "${TUNNEL_CREDENTIALS_DIR}"
  [ -f "${cred_file}" ] && chmod 600 "${cred_file}"

  # --- 5c. systemd サービスのインストール ---
  info "systemd サービスを登録しています..."

  # cloudflared 公式の systemd インストールコマンドを使用
  cloudflared service install 2>/dev/null || true

  # 公式コマンドが失敗した場合の手動フォールバック
  if [ ! -f /etc/systemd/system/cloudflared.service ]; then
    cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel — Cocoro OS (${TUNNEL_NAME})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=notify
ExecStart=/usr/local/bin/cloudflared tunnel --config ${config_file} run
Restart=on-failure
RestartSec=5s
TimeoutStopSec=5
KillMode=process
NoNewPrivileges=yes
PrivateTmp=yes

# ログ
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cloudflared

[Install]
WantedBy=multi-user.target
EOF
  fi

  # サービス有効化・起動
  systemctl daemon-reload
  systemctl enable cloudflared
  systemctl restart cloudflared || systemctl start cloudflared

  # 起動確認
  sleep 3
  if systemctl is-active cloudflared &>/dev/null; then
    success "cloudflared サービスが正常に起動しました"
  else
    warn "cloudflared サービスの起動を確認できませんでした"
    warn "ログを確認: journalctl -u cloudflared -n 50"
  fi
}

# ============================================================================
# 6. UFW ファイアウォール更新（outbound only、cloudflare tunnel は outbound）
# ============================================================================
update_firewall() {
  step "Step 6/6 — Updating firewall rules"

  if command -v ufw &>/dev/null; then
    # cloudflared は outbound 接続のみ使用するため inbound ルール不要
    # QUIC (UDP 7844) outbound を明示的に許可
    ufw allow out 7844/udp comment "cloudflared QUIC" >/dev/null 2>&1 || true
    ufw allow out 443/tcp comment "cloudflared HTTPS" >/dev/null 2>&1 || true
    success "UFW outbound ルールを更新しました"
  else
    info "UFW が見つかりません（スキップ）"
  fi
}

# ============================================================================
# 設定情報の永続化
# ============================================================================
save_tunnel_info() {
  # /etc/cocoro-release に追記
  if [ -f /etc/cocoro-release ]; then
    # 既存の TUNNEL_ 行を削除してから追記
    sed -i '/^COCORO_TUNNEL_/d' /etc/cocoro-release
  fi
  cat >> /etc/cocoro-release << EOF
COCORO_TUNNEL_ENABLED=true
COCORO_TUNNEL_ID=${TUNNEL_ID}
COCORO_TUNNEL_NAME=${TUNNEL_NAME}
COCORO_TUNNEL_HOSTNAME=${TUNNEL_HOSTNAME}
COCORO_NODE_ID=${NODE_ID}
EOF

  # ノード情報ファイル（管理ツール用）
  cat > /etc/cocoro-node.json << EOF
{
  "node_id": "${NODE_ID}",
  "tunnel_name": "${TUNNEL_NAME}",
  "tunnel_id": "${TUNNEL_ID}",
  "public_url": "https://${TUNNEL_HOSTNAME}",
  "api_url": "https://api.${TUNNEL_HOSTNAME}",
  "agent_url": "https://agent.${TUNNEL_HOSTNAME}",
  "setup_date": "$(date -Iseconds)"
}
EOF
  chmod 644 /etc/cocoro-node.json

  success "ノード情報を保存しました: /etc/cocoro-node.json"
}

# ============================================================================
# 完了メッセージ
# ============================================================================
print_summary() {
  hr
  echo ""
  echo -e "${BOLD}${GREEN}✅ Cloudflare Tunnel セットアップ完了！${RESET}"
  echo ""
  echo -e "${BOLD}${CYAN}あなたの Cocoro OS にアクセス：${RESET}"
  echo ""
  echo -e "  🌐 コンソール : ${BOLD}${GREEN}https://${TUNNEL_HOSTNAME}${RESET}"
  echo -e "  🤖 API        : ${CYAN}https://api.${TUNNEL_HOSTNAME}${RESET}"
  echo -e "  🦾 エージェント: ${CYAN}https://agent.${TUNNEL_HOSTNAME}${RESET}"
  echo ""
  echo -e "${BOLD}ノード情報：${RESET}"
  echo -e "  NODE_ID    : ${YELLOW}${NODE_ID}${RESET}"
  echo -e "  Tunnel名   : ${YELLOW}${TUNNEL_NAME}${RESET}"
  echo -e "  Tunnel ID  : ${CYAN}${TUNNEL_ID}${RESET}"
  echo ""
  echo -e "${BOLD}管理コマンド：${RESET}"
  echo -e "  状態確認    : ${YELLOW}systemctl status cloudflared${RESET}"
  echo -e "  ログ確認    : ${YELLOW}journalctl -u cloudflared -f${RESET}"
  echo -e "  再起動      : ${YELLOW}systemctl restart cloudflared${RESET}"
  echo ""
  echo -e "${BOLD}📚 ドキュメント: ${CYAN}https://docs.cocoro.ai${RESET}"
  hr
}

# ============================================================================
# メイン
# ============================================================================
main() {
  echo ""
  echo -e "${CYAN}${BOLD}"
  echo " ██████╗ ██████╗  ██████╗ ██████╗  ██████╗"
  echo "██╔════╝██╔═══██╗██╔════╝██╔═══██╗██╔═══██╗"
  echo "██║     ██║   ██║██║     ██║   ██║██║   ██║"
  echo "██║     ██║   ██║██║     ██║   ██║██║   ██║"
  echo "╚██████╗╚██████╔╝╚██████╗╚██████╔╝╚██████╔╝"
  echo " ╚═════╝ ╚═════╝  ╚═════╝ ╚═════╝  ╚═════╝"
  echo -e "${RESET}"
  echo -e "    ${BOLD}Cloudflare Tunnel Setup — Cocoro OS v1.0.0${RESET}"
  echo ""

  # root チェック
  if [ "$(id -u)" -ne 0 ]; then
    error "このスクリプトは root 権限で実行してください"
    error "sudo ./scripts/setup-tunnel.sh"
    exit 1
  fi

  load_and_validate_env
  generate_node_id
  install_cloudflared
  create_tunnel
  configure_and_register
  update_firewall
  save_tunnel_info
  print_summary
}

main "$@"
