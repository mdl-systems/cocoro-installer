# cocoro-installer

工場キッティング用 Debian 13 自動インストール USB + フルスタック Cocoro OS セットアップ

## 概要

USB を挿して電源を入れるだけで、miniPC (Intel N95) に **cocoro OS** が全サービス自動インストールされます。

```
USB ブート → GRUB 自動選択(3秒) → Debian 無人インストール
  → 再起動 → Docker + 全 Cocoro サービス セットアップ → 完了
```

## ワンライナーインストール

既存の Debian/Ubuntu 環境に Cocoro OS をインストールする場合：

```bash
curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/install.sh | bash
```

インストール時に対話的に以下を設定します：

| 設定項目 | 説明 |
|---|---|
| `GEMINI_API_KEY` | Google AI Studio の API キー |
| `MINIPC_IP` | miniPC の IP アドレス (例: 192.168.50.92) |
| `COCORO_API_KEY` | クライアント接続用 API キー (デフォルト: cocoro-2026) |

## 管理スクリプト

| スクリプト | 用途 | コマンド |
|---|---|---|
| `install.sh` | 初回インストール | `curl -fsSL .../install.sh \| bash` |
| `update.sh` | 全サービス更新 | `curl -fsSL .../update.sh \| bash` |
| `uninstall.sh` | アンインストール | `curl -fsSL .../uninstall.sh \| bash` |
| `scripts/setup-tunnel.sh` | Cloudflare Tunnel 設定 | `sudo ./scripts/setup-tunnel.sh` |

### アップデート

```bash
curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/update.sh | bash
```

全リポジトリを `git pull` して `docker compose up -d --build` を実行します。

### アンインストール

```bash
# リポジトリ・コンテナ・イメージ・ボリュームを削除（データは保持）
curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/uninstall.sh | bash

# 永続データ (PostgreSQL, Redis) も含めて完全削除
curl -fsSL https://raw.githubusercontent.com/mdl-systems/cocoro-installer/main/uninstall.sh | bash -s -- --purge
```

## Cloudflare Tunnel（外部アクセス）

各ノードに `{NODE_ID}.cocoro-os.com` のユニークなサブドメインを自動割り当てします。

```bash
# インストール時に対話式で設定（install.sh が自動呼び出し）
# または後から手動で実行：
sudo CLOUDFLARE_API_TOKEN=xxxx \
     CLOUDFLARE_ACCOUNT_ID=yyyy \
     CLOUDFLARE_ZONE_ID=zzzz \
     ./scripts/setup-tunnel.sh
```

インストール後のアクセス例：

| エンドポイント | URL |
|---|---|
| コンソール (UI) | `https://a1b2c3.cocoro-os.com` |
| API | `https://api.a1b2c3.cocoro-os.com` |
| エージェント | `https://agent.a1b2c3.cocoro-os.com` |

**必要な環境変数（出荷時に `/etc/cocoro-tunnel.env` に設定）：**

```bash
CLOUDFLARE_API_TOKEN=     # Cloudflare API トークン
CLOUDFLARE_ACCOUNT_ID=    # Cloudflare アカウント ID
CLOUDFLARE_ZONE_ID=       # cocoro-os.com の Zone ID
```

管理コマンド：

```bash
systemctl status cloudflared      # Tunnel 状態確認
journalctl -u cloudflared -f      # ログ確認
cat /etc/cocoro-node.json         # ノード情報確認
```


## 自動インストールされるサービス

| サービス | ポート | 説明 |
|---|---|---|
| cocoro-network | — | Docker ブリッジネットワーク (cocoro-net) |
| cocoro-core | 8000 | メイン AI エンジン (Personality / Memory / Emotion) |
| cocoro-agent | 8002 | 専門職エージェント (ECHO, IRIS 等) |
| cocoro-console | 3000 | ブラウザ UI コンソール |

### インストール後のアクセス

1. ブラウザで `http://<miniPC の IP>` にアクセス
2. **Boot Wizard** で人格設定（40問）
3. AI と会話を始めよう！

### ヘルスチェック

```bash
curl http://localhost:8000/health   # cocoro-core  ✅
curl http://localhost:8002/health   # cocoro-agent ✅
curl http://localhost:3000          # cocoro-console ✅
```

## クイックスタート（USB インストーラー方式）

### 方法 1: カスタム ISO をビルド → Rufus で USB に書き込み（推奨）

```bash
# WSL (Ubuntu) で実行
sudo apt-get install -y xorriso isolinux rsync

# Debian 13 ISO をダウンロード (初回のみ)
wget -P ~/.cache/packer/ https://cdimage.debian.org/cdimage/weekly-builds/amd64/iso-cd/debian-testing-amd64-netinst.iso

# カスタム ISO をビルド
cd /mnt/c/Users/<ユーザー名>/Desktop/cocoro-installer
chmod +x usb/build-iso.sh
./usb/build-iso.sh
```

`output/cocoro-os-installer.iso` が生成されます。Rufus で USB に書き込んでください。

| Rufus 設定 | 値 |
|---|---|
| パーティション構成 | GPT |
| ターゲットシステム | UEFI (non CSM) |
| 書き込みモード | ISO イメージモード |

### 方法 2: 既存の Debian USB を書き換え

```bash
chmod +x usb/deploy-to-usb.sh
./usb/deploy-to-usb.sh /mnt/d  # USB のマウントポイント
```

## インストール仕様

### ログイン情報

| 項目 | 値 |
|---|---|
| ホスト名 | `cocoro` |
| mDNS | `cocoro.local` |
| ユーザー | `cocoro-admin` |
| パスワード | `cocoro-factory-2026` |
| SSH | `ssh cocoro-admin@cocoro.local` |

### パーティション構成

| マウントポイント | サイズ | 用途 |
|---|---|---|
| `/boot/efi` | 512MB | EFI System Partition |
| `/` | 50GB | ルートファイルシステム |
| `/var/lib/docker` | 100GB | Docker イメージ・コンテナ |
| swap | 4GB | スワップ領域 |
| `/data/cocoro` | 残り全部 | 永続データ (PostgreSQL, Redis) |

### firstboot で自動セットアップされるもの

| コンポーネント | 詳細 |
|---|---|
| Docker CE | 最新版 (get.docker.com 経由) |
| cocoro-network | Docker ブリッジネットワーク (172.20.0.0/16) |
| cocoro-core | `/opt/cocoro/core` にクローン・起動 |
| cocoro-agent | `/opt/cocoro/agent` にクローン・起動 |
| cocoro-console | `/opt/cocoro/console` にクローン・起動 |
| データディレクトリ | PostgreSQL (UID 999), Redis, backups, logs, config |
| カーネル最適化 | ip_forward, file-max, swappiness, somaxconn 等 |
| zram | RAM の 25% を圧縮スワップとして使用 |
| UFW | SSH, mDNS, API (8000/8002/3000) を許可 |
| avahi-daemon | mDNS (`cocoro.local`) による名前解決 |

## プロジェクト構成

```
cocoro-installer/
├── install.sh                        # ワンライナーインストーラー ★メイン
├── update.sh                         # 全サービスアップデート
├── uninstall.sh                      # アンインストーラー
├── usb/                              # USB インストーラー関連
│   ├── preseed.cfg                   # Debian 自動応答設定
│   ├── cocoro/
│   │   ├── firstboot.sh              # 初回起動セットアップスクリプト（全サービス対応）
│   │   └── cocoro-firstboot.service  # systemd サービス定義
│   ├── build-iso.sh                  # カスタム ISO ビルドスクリプト
│   ├── deploy-to-usb.sh              # USB 直接配置スクリプト
│   └── isolinux-txt.cfg              # BIOS ブートメニュー設定
├── http/                             # Packer HTTP サーバー用 (レガシー)
├── scripts/                          # Packer スクリプト (レガシー)
├── build.pkr.hcl                     # Packer ビルド定義 (レガシー)
├── Makefile
├── .gitattributes                    # LF 改行コード強制
└── .gitignore
```

## 工場キッティング手順

1. `build-iso.sh` でカスタム ISO を生成
2. Rufus で USB に書き込み
3. miniPC に USB を挿入
4. 電源 ON → USB ブート（BIOS で USB 優先に設定済みの前提）
5. **操作不要** — 自動でインストール完了
6. 再起動後、firstboot が全 Cocoro サービスをセットアップ（約 5 分）
7. 検品確認（下記コマンド参照）
8. USB を抜いて梱包

### 検品確認

```bash
ssh cocoro-admin@cocoro.local
# パスワード: cocoro-factory-2026

# 基本確認
docker --version
systemctl status docker
df -h
cat /etc/cocoro-release

# サービス確認
docker ps
curl http://localhost:8000/health   # cocoro-core
curl http://localhost:8002/health   # cocoro-agent
curl http://localhost:3000          # cocoro-console
```

## 対象ハードウェア

| 項目 | スペック |
|---|---|
| CPU | Intel N95 (Alder Lake-N) |
| SSD | 512GB NVMe |
| RAM | 8GB〜16GB |
| NIC | Intel I225-V (Ethernet) |
| ブート | UEFI |

## リンク

- 📚 ドキュメント: [https://docs.cocoro.ai](https://docs.cocoro.ai)
- 🐙 GitHub: [https://github.com/mdl-systems](https://github.com/mdl-systems)

## ライセンス

Private — MDL Systems
