# cocoro-installer

工場キッティング用 Debian 13 (Trixie) 自動インストール USB (Packer + Preseed)

## 概要

`cocoro-installer` は、人格AI OS「cocoro-core」を搭載する miniPC (Intel N95) に対し、
USB ブートから完全無人（ゼロタッチ）で OS をインストールするための自動構築システムです。

## ディレクトリ構成

```
cocoro-installer/
├── build.pkr.hcl       # Packer ビルド定義
├── http/
│   └── preseed.cfg     # Debian Installer 自動応答設定
├── scripts/
│   └── setup.sh        # Post-Installation セットアップスクリプト
├── Makefile            # ビルド用コマンド集
└── README.md           # 本ファイル
```

## 前提条件

- Linux ビルド環境（WSL2 or ネイティブ）
- [HashiCorp Packer](https://www.packer.io/) >= 1.9.0
- QEMU/KVM (ビルド用仮想マシン)
- OVMF (UEFI ファームウェア): `apt install ovmf`
- `mkpasswd` コマンド: `apt install whois`

## セットアップ

### 1. パスワードハッシュの生成

```bash
echo "your-password" | mkpasswd -s -m sha-512
```

生成されたハッシュを `http/preseed.cfg` の `passwd/user-password-crypted` に設定してください。

### 2. ビルド

```bash
# 定義ファイルの検証
make validate

# イメージのビルド
make build
```

### 3. USB への書き込み

```bash
make usb-write USB_DEV=/dev/sdb
```

## パーティション構成

| パーティション | サイズ | ファイルシステム | 用途 |
|---|---|---|---|
| `/boot/efi` | 512MB | FAT32 | EFI システムパーティション |
| `/` | 50GB | ext4 | ルートファイルシステム |
| `/var/lib/docker` | 100GB | ext4 | Docker イメージ・コンテナ |
| `/data/cocoro` | 残り全容量 | ext4 | PostgreSQL / Redis / バックアップ |

## インストール後の構成

- **ホスト名**: `cocoro` (`cocoro.local` で mDNS 解決可能)
- **管理者**: `cocoro-admin` (パスワードなし sudo)
- **Docker**: docker-ce + docker-compose-plugin
- **ファイアウォール**: UFW (SSH:22, mDNS:5353, API:8080/8443)
- **タイムゾーン**: Asia/Tokyo

## トラブルシューティング

### ビルドエラー

- QEMU が見つからない場合: `sudo apt install qemu-system-x86 qemu-utils`
- OVMF が見つからない場合: `sudo apt install ovmf`
- KVM 権限エラー: `sudo usermod -aG kvm $USER`

### インストールログの確認

インストール先の端末にて：
```bash
cat /var/log/cocoro-install.log
cat /var/log/cocoro-installer-syslog.log
```
