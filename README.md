# cocoro-installer

工場キッティング用 Debian 13 自動インストール USB — miniPC 向けゼロタッチ OS セットアップ + cocoro-core デプロイ

## 概要

USB を挿して電源を入れるだけで、miniPC (Intel N95) に **cocoro OS** が自動インストールされます。

```
USB ブート → GRUB 自動選択(3秒) → Debian 無人インストール → 再起動 → Docker + cocoro-core セットアップ → 完了
```

## クイックスタート

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
| cocoro-core | `/opt/cocoro/core` にクローン |
| データディレクトリ | PostgreSQL (UID 999), Redis, backups, logs, config |
| カーネル最適化 | ip_forward, file-max, swappiness, somaxconn 等 |
| zram | RAM の 25% を圧縮スワップとして使用 |
| UFW | SSH, mDNS (5353), API (8080/8443) を許可 |
| avahi-daemon | mDNS (`cocoro.local`) による名前解決 |

## プロジェクト構成

```
cocoro-installer/
├── usb/                              # USB インストーラー関連
│   ├── preseed.cfg                   # Debian 自動応答設定
│   ├── cocoro/
│   │   ├── firstboot.sh              # 初回起動セットアップスクリプト
│   │   └── cocoro-firstboot.service  # systemd サービス定義
│   ├── build-iso.sh                  # カスタム ISO ビルドスクリプト
│   ├── deploy-to-usb.sh              # USB 直接配置スクリプト
│   └── isolinux-txt.cfg              # BIOS ブートメニュー設定
├── http/                             # Packer HTTP サーバー用 (レガシー)
│   ├── preseed.cfg
│   └── setup.sh
├── scripts/                          # Packer スクリプト (レガシー)
│   ├── setup.sh
│   └── firstboot.sh
├── build.pkr.hcl                     # Packer ビルド定義 (レガシー)
├── Makefile                          # ビルドコマンド
├── .gitattributes                    # LF 改行コード強制
└── .gitignore
```

## 工場キッティング手順

1. `build-iso.sh` でカスタム ISO を生成
2. Rufus で USB に書き込み
3. miniPC に USB を挿入
4. 電源 ON → USB ブート（BIOS で USB 優先に設定済みの前提）
5. **操作不要** — 自動でインストール完了
6. 再起動後、firstboot が Docker 等をセットアップ（約 20 秒）
7. USB を抜いて梱包

### 検品確認

```bash
ssh cocoro-admin@cocoro.local
# パスワード: cocoro-factory-2026

# 動作確認コマンド
docker --version
systemctl status docker
df -h
cat /etc/cocoro-release
```

## 対象ハードウェア

| 項目 | スペック |
|---|---|
| CPU | Intel N95 (Alder Lake-N) |
| SSD | 512GB NVMe |
| RAM | 8GB〜16GB |
| NIC | Intel I225-V (Ethernet) |
| ブート | UEFI |

## ライセンス

Private — MDL Systems
