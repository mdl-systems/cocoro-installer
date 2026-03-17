#!/bin/bash
# ============================================================================
# cocoro-installer: Cloudflare Tunnel Auto-Setup Script
# ============================================================================
# 用途:
#   各 miniPC ノードにユニーク ID を付与し、Cloudflare Tunnel を自動作成して
#   外部から https://{NODE_ID}.cocoro-os.com でアクセスできるようにする。
#
# 実行方法:
#   sudo ./scripts/setup-tunnel.sh
#
# 環境変数（スクリプト内にデフォルト値設定済み、必要に応じて上書き可）:
#   CLOUDFLARE_API_TOKEN
#   CLOUDFLARE_ACCOUNT_ID
#   CLOUDFLARE_ZONE_ID
# ============================================================================
set -euo pipefail

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
  NODE_ID=$(cat /dev/urandom | tr -dc 'a-z0-9' | head -c 6)
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
echo "${TUNNEL_TOKEN}" > "${CLOUDFLARED_CONFIG_DIR}/.tunnel-token"
chmod 600 "${CLOUDFLARED_CONFIG_DIR}/.tunnel-token"

success "Tunnel トークンを取得・保存しました"

# ============================================================================
# Step 5: DNS CNAME レコード自動作成
# POST /zones/{ZONE_ID}/dns_records
# ============================================================================
step "Step 5/7 — Creating DNS CNAME record"

info "CNAME レコードを作成しています: ${TUNNEL_HOSTNAME} → ${TUNNEL_ID}.cfargotunnel.com"

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

  if echo "${DNS_ERROR}" | grep -qi "already exists"; then
    warn "DNS レコードは既に存在します（スキップ）"
  else
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
