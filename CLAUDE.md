# CLAUDE.md — cocoro-installer

> このrepoはCocoro OSの工場キッティング用自動インストーラーです。
> プロジェクト全体の概要は cocoro-docs/CLAUDE.md を参照してください。

---

## このrepoの役割

**工場キッティング用 Debian 13 自動インストール USB**
USBを挿して電源を入れるだけで、miniPC (Intel N95) に cocoro OS が全自動インストールされます。

```
USB ブート → GRUB 自動選択(3秒) → Debian 無人インストール
  → 再起動 → Docker + 全 Cocoro サービス セットアップ → 完了（約5分）
```

- **言語**: Shell
- **対象OS**: Debian 13 (testing)
- **対象HW**: Intel N95 / 512GB NVMe / 8〜16GB RAM / UEFI

---

## 対象ハードウェア

| 項目 | スペック |
|------|---------|
| CPU | Intel N95 (Alder Lake-N) |
| SSD | 512GB NVMe |
| RAM | 8GB〜16GB |
| NIC | Intel I225-V (Ethernet) |
| ブート | UEFI |

---

## ログイン情報（インストール後）

| 項目 | 値 |
|------|----|
| ホスト名 | `cocoro` |
| mDNS | `cocoro.local` |
| ユーザー | `cocoro-admin` |
| パスワード | `cocoro-factory-2026` |
| SSH | `ssh cocoro-admin@cocoro.local` |

---

## パーティション構成

| マウントポイント | サイズ | 用途 |
|----------------|--------|------|
| `/boot/efi` | 512MB | EFI System Partition |
| `/` | 50GB | ルートファイルシステム |
| `/var/lib/docker` | 100GB | Dockerイメージ・コンテナ |
| swap | 4GB | スワップ領域 |
| `/data/cocoro` | 残り全部 | 永続データ (PostgreSQL, Redis) |

---

## よく使うコマンド

### ISOビルド（WSL / Ubuntu）

```bash
# 依存パッケージインストール
sudo apt-get install -y xorriso isolinux rsync

# Debian 13 ISOダウンロード（初回のみ）
wget -P ~/.cache/packer/ \
  https://cdimage.debian.org/cdimage/weekly-builds/amd64/iso-cd/debian-testing-amd64-netinst.iso

# カスタムISOビルド
cd /mnt/c/Users/<ユーザー名>/Desktop/cocoro-installer
chmod +x usb/build-iso.sh
./usb/build-iso.sh
# → output/cocoro-os-installer.iso が生成される
```

### USB に直接配置

```bash
chmod +x usb/deploy-to-usb.sh
./usb/deploy-to-usb.sh /mnt/d   # USBのマウントポイント
```

### 検品確認（インストール後）

```bash
ssh cocoro-admin@cocoro.local
# パスワード: cocoro-factory-2026

docker --version
systemctl status docker
df -h
cat /etc/cocoro-release
```

---

## Rufus 書き込み設定

| 設定項目 | 値 |
|---------|-----|
| パーティション構成 | GPT |
| ターゲットシステム | UEFI (non CSM) |
| 書き込みモード | ISO イメージモード |

---

## firstbootで自動セットアップされるもの

| コンポーネント | 詳細 |
|--------------|------|
| Docker CE | 最新版 (get.docker.com 経由) |
| cocoro-network | Docker ブリッジネットワーク (172.20.0.0/16) |
| cocoro-core | `/opt/cocoro/core` にクローン・起動 |
| cocoro-agent | `/opt/cocoro/agent` にクローン・起動 |
| cocoro-console | `/opt/cocoro/console` にクローン・起動 |
| データディレクトリ | PostgreSQL (UID 999), Redis, backups, logs, config |
| カーネル最適化 | ip_forward, file-max, swappiness, somaxconn 等 |
| zram | RAM の 25% を圧縮スワップとして使用 |
| UFW | SSH, mDNS (5353), API (8000/8002/3000) を許可 |
| avahi-daemon | mDNS (`cocoro.local`) による名前解決 |

---

## 工場キッティング手順

1. `build-iso.sh` でカスタムISO生成
2. Rufus（GPT / UEFI / ISOイメージモード）でUSBに書き込み
3. miniPCにUSB挿入
4. 電源ON → USBブート（BIOS設定でUSB優先の前提）
5. **操作不要** — 自動でインストール完了
6. 再起動後、firstbootがDockerをセットアップ（約20秒）
7. 検品確認（上記コマンド参照）
8. USBを抜いて梱包

---

## ディレクトリ構成

```
cocoro-installer/
├── install.sh                        # ワンライナーインストーラー ★メイン
├── update.sh                         # 全サービスアップデーター
├── uninstall.sh                      # アンインストーラー
├── usb/
│   ├── preseed.cfg                   # Debian 自動応答設定
│   ├── cocoro/
│   │   ├── firstboot.sh              # 初回起動セットアップスクリプト（全サービス対応）
│   │   └── cocoro-firstboot.service  # systemd サービス定義
│   ├── build-iso.sh                  # カスタムISOビルドスクリプト
│   ├── deploy-to-usb.sh              # USB直接配置スクリプト
│   └── isolinux-txt.cfg              # BIOSブートメニュー設定
├── http/                             # Packer HTTPサーバー用（レガシー）
├── scripts/                          # Packerスクリプト（レガシー）
│   ├── setup.sh                      # Packerセットアップ（レガシー）
│   ├── firstboot.sh                  # Packer firstboot（レガシー）
│   └── setup-tunnel.sh               # Cloudflare Tunnel 自動セットアップ
├── build.pkr.hcl                     # Packerビルド定義（レガシー）
├── Makefile
└── .gitattributes                    # LF改行コード強制
```

> `http/` `scripts/` `build.pkr.hcl` はレガシーファイル。現在は `install.sh` `update.sh` `uninstall.sh` および `usb/` 配下を使用。

---

## 開発時の注意事項

- **Debian/Shell依存のため他OS環境（Windows/Mac）では直接テスト不可**
- テストはWSL (Ubuntu) または実機miniPCで行うこと
- `preseed.cfg` を変更した場合は必ず実機で動作確認
- LF改行コードを強制（`.gitattributes` 設定済み）。Windowsで編集する場合は注意
- `cocoro-core` のデプロイパスは `/opt/cocoro/core`（`firstboot.sh` と一致させること）

---

## 更新履歴

| 日付 | 更新内容 |
|------|---------|
| 2026-03-08 | 初版作成 |
| 2026-03-14 | フルスタック対応: install.sh 追加、firstboot.sh を全サービス対応に更新 |
| 2026-03-14 | v1.0.0 リリース: update.sh ・ uninstall.sh 追加、バナー・完了画面を最終仕上げ |
| 2026-03-17 | Cloudflare Tunnel 自動セットアップ: scripts/setup-tunnel.sh 追加 |
