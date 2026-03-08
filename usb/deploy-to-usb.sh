#!/bin/bash
# ============================================================================
# cocoro-installer: USB 書き込み・構成スクリプト
# ============================================================================
# 既存の Debian インストーラー USB に cocoro-installer のファイルを配置する
# 
# 使い方:
#   1. Debian 13 (Trixie) の ISO を USB に書き込む
#   2. このスクリプトを実行して preseed.cfg + cocoro ディレクトリを配置
#
# 前提: D:\ に Debian インストーラー USB がマウントされていること
# ============================================================================
set -euo pipefail

USB_MOUNT="${1:-/mnt/d}"  # WSL のデフォルトは /mnt/d

echo "============================================"
echo "cocoro-installer: USB セットアップ"
echo "============================================"
echo "USB マウントポイント: ${USB_MOUNT}"

# USB がマウントされているか確認
if [ ! -f "${USB_MOUNT}/install.amd/vmlinuz" ]; then
  echo "ERROR: ${USB_MOUNT} に Debian インストーラーが見つかりません。"
  echo "USB ドライブが正しくマウントされているか確認してください。"
  exit 1
fi

# スクリプトのディレクトリ
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --------------------------------------------------------------------------
# 1. preseed.cfg の配置
# --------------------------------------------------------------------------
echo "[1/4] preseed.cfg を配置中..."
cp "${SCRIPT_DIR}/preseed.cfg" "${USB_MOUNT}/preseed.cfg"
echo "  ✓ ${USB_MOUNT}/preseed.cfg"

# --------------------------------------------------------------------------
# 2. cocoro ディレクトリの配置
# --------------------------------------------------------------------------
echo "[2/4] cocoro ディレクトリを配置中..."
mkdir -p "${USB_MOUNT}/cocoro"
cp "${SCRIPT_DIR}/cocoro/firstboot.sh" "${USB_MOUNT}/cocoro/firstboot.sh"
cp "${SCRIPT_DIR}/cocoro/cocoro-firstboot.service" "${USB_MOUNT}/cocoro/cocoro-firstboot.service"
# setup.sh が存在する場合はコピー (オプション)
if [ -f "${SCRIPT_DIR}/cocoro/setup.sh" ]; then
  cp "${SCRIPT_DIR}/cocoro/setup.sh" "${USB_MOUNT}/cocoro/setup.sh"
fi
echo "  ✓ ${USB_MOUNT}/cocoro/"

# --------------------------------------------------------------------------
# 3. GRUB 設定の更新 (UEFI ブート用)
# --------------------------------------------------------------------------
echo "[3/4] GRUB 設定を更新中..."
GRUB_CFG="${USB_MOUNT}/boot/grub/grub.cfg"
if [ -f "${GRUB_CFG}" ]; then
  # preseed/file パスを更新
  sed -i 's|preseed/file=/cdrom/preseed.cfg|preseed/file=/cdrom/preseed.cfg|g' "${GRUB_CFG}"
  # default を Install に設定
  sed -i 's/^set default=.*/set default="Install"/' "${GRUB_CFG}"
  # timeout を短く
  sed -i 's/^set timeout=.*/set timeout=3/' "${GRUB_CFG}"
  echo "  ✓ ${GRUB_CFG}"
else
  echo "  ⚠ grub.cfg が見つかりません (BIOS ブートのみ?)"
fi

# --------------------------------------------------------------------------
# 4. ISOLINUX 設定の更新 (BIOS ブート用)
# --------------------------------------------------------------------------
echo "[4/4] ISOLINUX 設定を確認中..."
TXT_CFG="${USB_MOUNT}/isolinux/txt.cfg"
if [ -f "${TXT_CFG}" ]; then
  echo "  ✓ ${TXT_CFG} (既存の設定を維持)"
else
  echo "  ⚠ txt.cfg が見つかりません"
fi

echo ""
echo "============================================"
echo "✓ USB セットアップ完了！"
echo "============================================"
echo ""
echo "次のステップ:"
echo "  1. USB を miniPC に挿入"
echo "  2. 電源を入れて USB から起動"
echo "  3. 自動インストールが開始される"
echo "  4. 完了後、ssh cocoro-admin@cocoro.local で接続"
echo ""
echo "パスワード: cocoro-factory-2026"
echo "============================================"
