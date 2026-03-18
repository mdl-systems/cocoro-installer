#!/bin/bash
# ============================================================================
# cocoro-installer: Cloudflare Tunnel Auto-Setup Script
# ============================================================================
# 用途:
#   各 miniPC ノードにユニーク ID を付与し、Cloudflare Tunnel を自動作成して
#   外部から https://{NODE_ID}.cocoro-os.com でアクセスできるようにする。
#
# 実行方法:
#   sudo ./scripts/setup-tunnel.sh [--email owner@example.com]
#
# オプション:
#   --email EMAIL   オーナーのメールアドレス。指定時に Cloudflare Access を自動設定する
#
# 環境変数（スクリプト内にデフォルト値設定済み、必要に応じて上書き可）:
#   CLOUDFLARE_API_TOKEN
#   CLOUDFLARE_ACCOUNT_ID
#   CLOUDFLARE_ZONE_ID
# ============================================================================
set -euo pipefail

# ============================================================================
# 引数パース
# ============================================================================
OWNER_EMAIL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      OWNER_EMAIL="${2:-}"
      shift 2
      ;;
    --email=*)
      OWNER_EMAIL="${1#--email=}"
      shift
      ;;
    -h|--help)
      echo "Usage: sudo $0 [--email owner@example.com]"
      echo ""
      echo "  --email EMAIL   オーナーのメールアドレス。指定時に Cloudflare Access を自動設定する"
      exit 0
      ;;
    *)
      echo "[WARN] 未知のオプション: $1"
      shift
      ;;
  esac
done

# ============================================================================
# 環境変数 — デフォルト値（出荷時設定）
# ============================================================================
: "${CLOUDFLARE_API_TOKEN:=oa2jiqhVwAeRXQAq69wpDBiqqVUAONt3OHN11mxh}"
: "${CLOUDFLARE_ACCOUNT_ID:=a7afb9e57e5be673e257d1f1ec174ff8}"
: "${CLOUDFLARE_ZONE_ID:=05b52de8db8056139270c3e329c070df}"

# ============================================================================
# 定数
# ============================================================================
readonly API_BASE="https://api.cloudflare.com/client/v4"
readonly DOMAIN="cocoro-os.com"
readonly CLOUDFLARED_CONFIG_DIR="/etc/cloudflared"
readonly LOG_FILE="/var/log/cocoro-tunnel-setup.log"

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*" | tee -a "${LOG_FILE}"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*" | tee -a "${LOG_FILE}"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" | tee -a "${LOG_FILE}"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" | tee -a "${LOG_FILE}" >&2; }
step()    { echo -e "\n${BOLD}${CYAN}▶ $*${RESET}" | tee -a "${LOG_FILE}"; }

# ============================================================================
# root チェック
# ============================================================================
if [ "$(id -u)" -ne 0 ]; then
  echo -e "${RED}[ERROR]${RESET} このスクリプトは root 権限で実行してください"
  echo -e "  sudo ./scripts/setup-tunnel.sh"
  exit 1
fi

echo "cocoro-tunnel-setup started: $(date)" >> "${LOG_FILE}"

# ============================================================================
# Step 1: ユニーク NODE_ID 生成
# ============================================================================
step "Step 1/7 — Generating unique Node ID"

if [ -f /etc/cocoro-node-id ]; then
  NODE_ID=$(cat /etc/cocoro-node-id)
  info "既存の NODE_ID を再利用します: ${NODE_ID}"
else
  NODE_ID=$(openssl rand -hex 3)
  echo "${NODE_ID}" > /etc/cocoro-node-id
  chmod 644 /etc/cocoro-node-id
  success "NODE_ID を生成しました: ${NODE_ID}"
fi

readonly TUNNEL_NAME="cocoro-${NODE_ID}"
readonly TUNNEL_HOSTNAME="${NODE_ID}.${DOMAIN}"
info "Tunnel 名   : ${TUNNEL_NAME}"
info "ホスト名    : ${TUNNEL_HOSTNAME}"

# ============================================================================
# Step 2: cloudflared を Debian にインストール
# ============================================================================
step "Step 2/7 — Installing cloudflared (Debian)"

if command -v cloudflared &>/dev/null; then
  local_ver=$(cloudflared --version 2>&1 | head -1 || echo "unknown")
  info "cloudflared は既にインストールされています: ${local_ver}"
else
  info "Cloudflare 公式 APT リポジトリを追加しています..."

  mkdir -p /etc/apt/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /etc/apt/keyrings/cloudflare-main.gpg

  echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared $(. /etc/os-release && echo "${VERSION_CODENAME:-bookworm}") main" \
    > /etc/apt/sources.list.d/cloudflared.list

  apt-get update -y -q
  apt-get install -y cloudflared

  installed_ver=$(cloudflared --version 2>&1 | head -1)
  success "cloudflared インストール完了: ${installed_ver}"
fi

# ============================================================================
# Step 3: Cloudflare API で Tunnel 作成
# POST /accounts/{ACCOUNT_ID}/cfd_tunnel
# ============================================================================
step "Step 3/7 — Creating Cloudflare Tunnel via API"

# 既存 Tunnel の確認（冪等性）
info "既存の Tunnel を確認しています..."
EXISTING_TUNNEL_ID=$(curl -fsSL \
  "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel?name=${TUNNEL_NAME}&is_deleted=false" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
result = data.get('result', [])
print(result[0]['id'] if result else '')
" 2>/dev/null || echo "")

if [ -n "${EXISTING_TUNNEL_ID}" ]; then
  TUNNEL_ID="${EXISTING_TUNNEL_ID}"
  info "既存の Tunnel を再利用します: ${TUNNEL_ID}"
else
  info "新規 Tunnel を作成しています: ${TUNNEL_NAME}"

  CREATE_RESPONSE=$(curl -fsSL -X POST \
    "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"name\": \"${TUNNEL_NAME}\",
      \"config_src\": \"cloudflare\"
    }")

  # レスポンス検証
  CF_SUCCESS=$(echo "${CREATE_RESPONSE}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

  if [ "${CF_SUCCESS}" != "True" ]; then
    error "Tunnel 作成に失敗しました"
    error "レスポンス: ${CREATE_RESPONSE}"
    exit 1
  fi

  TUNNEL_ID=$(echo "${CREATE_RESPONSE}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['result']['id'])")

  success "Tunnel 作成完了: ${TUNNEL_NAME}"
  info "Tunnel ID: ${TUNNEL_ID}"
fi

# TUNNEL_ID を保存
echo "${TUNNEL_ID}" > /etc/cocoro-tunnel-id
chmod 644 /etc/cocoro-tunnel-id

# ============================================================================
# Step 4: Tunnel トークンを API で取得
# GET /accounts/{ACCOUNT_ID}/cfd_tunnel/{TUNNEL_ID}/token
# ============================================================================
step "Step 4/7 — Retrieving Tunnel token"

TOKEN_RESPONSE=$(curl -fsSL \
  "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/token" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json")

CF_TOKEN_SUCCESS=$(echo "${TOKEN_RESPONSE}" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

if [ "${CF_TOKEN_SUCCESS}" != "True" ]; then
  error "Tunnel トークンの取得に失敗しました"
  error "レスポンス: ${TOKEN_RESPONSE}"
  exit 1
fi

TUNNEL_TOKEN=$(echo "${TOKEN_RESPONSE}" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['result'])")

# トークンをファイルに保存（systemd サービスから参照）
mkdir -p "${CLOUDFLARED_CONFIG_DIR}"
echo "${TUNNEL_TOKEN}" > "${CLOUDFLARED_CONFIG_DIR}/.tunnel-token"
chmod 600 "${CLOUDFLARED_CONFIG_DIR}/.tunnel-token"

success "Tunnel トークンを取得・保存しました"

# ============================================================================
# Step 5: DNS CNAME レコード自動作成
# POST /zones/{ZONE_ID}/dns_records
# ============================================================================
step "Step 5/7 — Creating DNS CNAME record"

# --- 既存レコードの確認 ---
info "既存の DNS レコードを確認しています: ${TUNNEL_HOSTNAME}"

EXISTING_DNS=$(curl -fsSL \
  "${API_BASE}/zones/${CLOUDFLARE_ZONE_ID}/dns_records?name=${NODE_ID}.${DOMAIN}&type=CNAME" \
  -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
  -H "Content-Type: application/json" \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
result = data.get('result', [])
print(result[0]['id'] if result else '')
" 2>/dev/null || echo "")

if [ -n "${EXISTING_DNS}" ]; then
  # 既存レコードが見つかった → スキップ
  success "DNS CNAME レコードは既に存在します（スキップ）: https://${TUNNEL_HOSTNAME}"
else
  # 存在しない → 新規作成
  info "DNS CNAME レコードを作成しています: ${TUNNEL_HOSTNAME} → ${TUNNEL_ID}.cfargotunnel.com"

  DNS_RESPONSE=$(curl -fsSL -X POST \
    "${API_BASE}/zones/${CLOUDFLARE_ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"type\": \"CNAME\",
      \"name\": \"${NODE_ID}.${DOMAIN}\",
      \"content\": \"${TUNNEL_ID}.cfargotunnel.com\",
      \"ttl\": 1,
      \"proxied\": true,
      \"comment\": \"Auto-created by cocoro-installer node=${NODE_ID}\"
    }" 2>/dev/null || echo '{"success":false,"errors":[{"message":"request failed"}]}')

  DNS_SUCCESS=$(echo "${DNS_RESPONSE}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

  if [ "${DNS_SUCCESS}" == "True" ]; then
    success "DNS CNAME レコードを作成しました: https://${TUNNEL_HOSTNAME}"
  else
    DNS_ERROR=$(echo "${DNS_RESPONSE}" | python3 -c \
      "import sys,json; r=json.load(sys.stdin).get('errors',[]); print(r[0].get('message','unknown') if r else 'unknown')" \
      2>/dev/null || echo "unknown")
    warn "DNS レコード作成エラー: ${DNS_ERROR}"
    warn "手動で CNAME ${NODE_ID} → ${TUNNEL_ID}.cfargotunnel.com を設定してください"
  fi
fi

# ============================================================================
# Step 6: Tunnel 設定ファイル作成
# /etc/cloudflared/config.yml
# ============================================================================
step "Step 6/7 — Creating Tunnel configuration"

mkdir -p "${CLOUDFLARED_CONFIG_DIR}"

cat > "${CLOUDFLARED_CONFIG_DIR}/config.yml" << EOF
# Cloudflare Tunnel configuration
# Auto-generated by cocoro-installer on $(date -Iseconds)
# Node: ${TUNNEL_NAME} — https://${TUNNEL_HOSTNAME}

tunnel: ${TUNNEL_ID}
credentials-file: ${CLOUDFLARED_CONFIG_DIR}/${TUNNEL_ID}.json

ingress:
  - hostname: ${TUNNEL_HOSTNAME}
    service: http://localhost:80
  - service: http_status:404
EOF

chmod 644 "${CLOUDFLARED_CONFIG_DIR}/config.yml"
success "設定ファイルを作成しました: ${CLOUDFLARED_CONFIG_DIR}/config.yml"

# ============================================================================
# Step 7: systemd サービス登録・起動
# トークンベース起動（config_src: cloudflare の場合はトークンで実行）
# ============================================================================
step "Step 7/7 — Registering and starting systemd service"

# cloudflared の systemd サービスを手動作成
# （config_src: cloudflare の場合は --token フラグで起動する）
cat > /etc/systemd/system/cloudflared.service << EOF
[Unit]
Description=Cloudflare Tunnel — ${TUNNEL_NAME} (${TUNNEL_HOSTNAME})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=notify
EnvironmentFile=-/etc/cloudflared/.tunnel-env
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token ${TUNNEL_TOKEN}
Restart=on-failure
RestartSec=5s
TimeoutStopSec=5
KillMode=process
NoNewPrivileges=yes
PrivateTmp=yes
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cloudflared

[Install]
WantedBy=multi-user.target
EOF

info "systemd サービスを有効化・起動しています..."
systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared || systemctl start cloudflared

# 起動確認（3秒待機）
sleep 3
if systemctl is-active --quiet cloudflared; then
  success "cloudflared サービスが正常に起動しました"
else
  warn "cloudflared サービスの起動確認に失敗しました"
  warn "ログを確認してください: journalctl -u cloudflared -n 50"
fi

# ============================================================================
# ノード情報の永続化
# ============================================================================
# /etc/cocoro-release に追記
if [ -f /etc/cocoro-release ]; then
  sed -i '/^COCORO_TUNNEL_\|^COCORO_NODE_ID/d' /etc/cocoro-release
fi
cat >> /etc/cocoro-release << EOF
COCORO_NODE_ID=${NODE_ID}
COCORO_TUNNEL_ID=${TUNNEL_ID}
COCORO_TUNNEL_NAME=${TUNNEL_NAME}
COCORO_TUNNEL_HOSTNAME=${TUNNEL_HOSTNAME}
COCORO_TUNNEL_URL=https://${TUNNEL_HOSTNAME}
EOF

# ノード情報 JSON
cat > /etc/cocoro-node.json << EOF
{
  "node_id": "${NODE_ID}",
  "tunnel_name": "${TUNNEL_NAME}",
  "tunnel_id": "${TUNNEL_ID}",
  "public_url": "https://${TUNNEL_HOSTNAME}",
  "domain": "${DOMAIN}",
  "setup_date": "$(date -Iseconds)"
}
EOF
chmod 644 /etc/cocoro-node.json

# ============================================================================
# Step 8: cocoro-console の起動確認・自動起動設定
# ============================================================================
step "Step 8/8 — Starting cocoro-console and verifying localhost:80"

readonly CONSOLE_COMPOSE="/home/cocoro-admin/cocoro-console/docker-compose.yml"
CONSOLE_OK=false

# 1. docker compose で cocoro-console を起動
if [ -f "${CONSOLE_COMPOSE}" ]; then
  info "cocoro-console を起動しています..."
  docker compose -f "${CONSOLE_COMPOSE}" up -d && \
    success "docker compose up -d 完了" || \
    warn "docker compose up -d でエラーが発生しました（続行）"
else
  warn "docker-compose.yml が見つかりません: ${CONSOLE_COMPOSE}"
  warn "cocoro-console が正しくインストールされているか確認してください"
fi

# 2. localhost:80 への疎通確認（最大30秒待機）
info "localhost:80 への疎通確認（最大30秒）..."
for i in $(seq 1 30); do
  if curl -sf --max-time 2 "http://localhost:80" > /dev/null 2>&1; then
    CONSOLE_OK=true
    break
  fi
  sleep 1
done

# 3. 疎通結果に応じてメッセージ表示
if $CONSOLE_OK; then
  success "localhost:80 への接続を確認しました ✅"
  success "Cloudflare Tunnel 経由で https://${TUNNEL_HOSTNAME} からアクセス可能です"
else
  warn "localhost:80 への接続を確認できませんでした ❌"
  warn "cocoro-console が起動していない可能性があります"
  warn "確認コマンド: docker compose -f ${CONSOLE_COMPOSE} logs"
fi

# ============================================================================
# Step 9: Cloudflare Access 自動設定（--email 指定時のみ実行）
# ============================================================================
if [[ -n "${OWNER_EMAIL}" ]]; then
  step "Step 9/9 — Configuring Cloudflare Access (owner-only policy)"
  info "オーナーメール: ${OWNER_EMAIL}"
  info "保護対象 : https://${TUNNEL_HOSTNAME}"

  # --------------------------------------------------------------------------
  # 9-1. Access Application を作成
  # POST /accounts/{ACCOUNT_ID}/access/apps
  # --------------------------------------------------------------------------
  info "Cloudflare Access Application を作成しています..."

  APP_RESPONSE=$(curl -fsSL -X POST \
    "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "{
      \"name\": \"Cocoro OS — ${TUNNEL_NAME}\",
      \"domain\": \"${TUNNEL_HOSTNAME}\",
      \"type\": \"self_hosted\",
      \"session_duration\": \"24h\",
      \"auto_redirect_to_identity\": false,
      \"http_only_cookie_attribute\": true,
      \"same_site_cookie_attribute\": \"strict\"
    }")

  APP_SUCCESS=$(echo "${APP_RESPONSE}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

  if [ "${APP_SUCCESS}" != "True" ]; then
    warn "Access Application の作成に失敗しました"
    warn "レスポンス: ${APP_RESPONSE}"
    warn "Step 9 をスキップします（後からダッシュボードで設定可能）"
  else
    APP_ID=$(echo "${APP_RESPONSE}" | python3 -c \
      "import sys,json; print(json.load(sys.stdin)['result']['id'])")
    success "Access Application 作成完了: ${APP_ID}"

    # ------------------------------------------------------------------------
    # 9-2. owner-only Policy を作成
    # POST /accounts/{ACCOUNT_ID}/access/policies
    # ------------------------------------------------------------------------
    info "owner-only ポリシーを作成しています..."

    POLICY_RESPONSE=$(curl -fsSL -X POST \
      "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/policies" \
      -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "{
        \"name\": \"Owner Only — ${TUNNEL_NAME}\",
        \"decision\": \"allow\",
        \"include\": [
          {
            \"email\": { \"email\": \"${OWNER_EMAIL}\" }
          }
        ],
        \"exclude\": [],
        \"require\": [],
        \"precedence\": 1
      }")

    POLICY_SUCCESS=$(echo "${POLICY_RESPONSE}" | python3 -c \
      "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

    if [ "${POLICY_SUCCESS}" != "True" ]; then
      warn "ポリシーの作成に失敗しました"
      warn "レスポンス: ${POLICY_RESPONSE}"
    else
      POLICY_ID=$(echo "${POLICY_RESPONSE}" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['result']['id'])")
      success "Policy 作成完了: ${POLICY_ID}"

      # ----------------------------------------------------------------------
      # 9-3. Application に Policy を紐付け
      # PUT /accounts/{ACCOUNT_ID}/access/apps/{APP_ID}
      # ----------------------------------------------------------------------
      info "Application に Policy を紐付けています..."

      BIND_RESPONSE=$(curl -fsSL -X PUT \
        "${API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/access/apps/${APP_ID}" \
        -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "{
          \"name\": \"Cocoro OS — ${TUNNEL_NAME}\",
          \"domain\": \"${TUNNEL_HOSTNAME}\",
          \"type\": \"self_hosted\",
          \"session_duration\": \"24h\",
          \"policies\": [
            { \"id\": \"${POLICY_ID}\" }
          ]
        }")

      BIND_SUCCESS=$(echo "${BIND_RESPONSE}" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('success', False))" 2>/dev/null || echo "False")

      if [ "${BIND_SUCCESS}" == "True" ]; then
        success "Policy を Application に紐付けました ✅"
        success "${TUNNEL_HOSTNAME} は ${OWNER_EMAIL} のみアクセス可能です"

        # Access 情報をノード JSON に追記
        python3 -c "
import json
try:
    with open('/etc/cocoro-node.json') as f:
        node = json.load(f)
except Exception:
    node = {}
node['access_app_id']   = '${APP_ID}'
node['access_policy_id'] = '${POLICY_ID}'
node['access_owner']     = '${OWNER_EMAIL}'
with open('/etc/cocoro-node.json', 'w') as f:
    json.dump(node, f, indent=2, ensure_ascii=False)
print('node.json updated')
" 2>/dev/null || true

      else
        warn "Policy 紐付けに失敗しました"
        warn "手動で Cloudflare ダッシュボードから紐付けてください"
      fi
    fi
  fi
else
  info "--email 未指定のため Cloudflare Access 設定をスキップします"
  info "後から追加する場合: sudo $0 --email your@email.com"
fi

# ============================================================================
# 完了メッセージ
# ============================================================================
echo ""
echo "=============================="
echo "Cocoro OS セットアップ完了！"
echo "あなたのURL: https://${TUNNEL_HOSTNAME}"
echo "=============================="
echo ""
echo -e "${BOLD}管理コマンド：${RESET}"
echo "  状態確認 : systemctl status cloudflared"
echo "  ログ確認 : journalctl -u cloudflared -f"
echo "  再起動   : systemctl restart cloudflared"
echo ""
