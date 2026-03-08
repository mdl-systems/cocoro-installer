#!/bin/bash
# ============================================================================
# cocoro-installer: カスタム ISO ビルドスクリプト
# ============================================================================
# Debian 13 (Trixie) netinst ISO に preseed.cfg と cocoro ファイルを埋め込み、
# Rufus でそのまま書き込めるオリジナル ISO を生成する。
#
# 使い方:
#   ./build-iso.sh [元のISOファイルパス]
#
# 必要パッケージ:
#   sudo apt-get install -y xorriso isolinux
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# 設定
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
ORIGINAL_ISO="${1:-}"
CUSTOM_ISO="${PROJECT_DIR}/output/cocoro-os-installer.iso"
WORK_DIR="/tmp/cocoro-iso-build"
MOUNT_DIR="${WORK_DIR}/mnt"
EXTRACT_DIR="${WORK_DIR}/iso"

# ---------------------------------------------------------------------------
# ISO ファイルの検出
# ---------------------------------------------------------------------------
if [ -z "${ORIGINAL_ISO}" ]; then
  # Packer キャッシュから検索
  PACKER_CACHE="${HOME}/.cache/packer"
  if [ -d "${PACKER_CACHE}" ]; then
    ORIGINAL_ISO=$(find "${PACKER_CACHE}" -name "*.iso" -size +500M 2>/dev/null | head -1)
  fi
  # まだ見つからない場合
  if [ -z "${ORIGINAL_ISO}" ] || [ ! -f "${ORIGINAL_ISO}" ]; then
    echo "ERROR: ISO ファイルが見つかりません。"
    echo "使い方: $0 /path/to/debian-testing-amd64-netinst.iso"
    echo ""
    echo "ISO ダウンロード:"
    echo "  wget https://cdimage.debian.org/cdimage/weekly-builds/amd64/iso-cd/debian-testing-amd64-netinst.iso"
    exit 1
  fi
fi

echo "============================================"
echo "cocoro-installer: カスタム ISO ビルド"
echo "============================================"
echo "元 ISO: ${ORIGINAL_ISO}"
echo "出力先: ${CUSTOM_ISO}"
echo ""

# ---------------------------------------------------------------------------
# 必要パッケージの確認
# ---------------------------------------------------------------------------
for cmd in xorriso; do
  if ! command -v "${cmd}" &> /dev/null; then
    echo "ERROR: ${cmd} がインストールされていません。"
    echo "  sudo apt-get install -y xorriso isolinux"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# クリーンアップ
# ---------------------------------------------------------------------------
cleanup() {
  echo "クリーンアップ中..."
  sudo umount "${MOUNT_DIR}" 2>/dev/null || true
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. ISO の展開
# ---------------------------------------------------------------------------
echo "[1/5] ISO をマウント・展開中..."
rm -rf "${WORK_DIR}"
mkdir -p "${MOUNT_DIR}" "${EXTRACT_DIR}"

sudo mount -o loop,ro "${ORIGINAL_ISO}" "${MOUNT_DIR}"
# ISO の内容をコピー (シンボリックリンクを保持)
rsync -a "${MOUNT_DIR}/" "${EXTRACT_DIR}/"
sudo umount "${MOUNT_DIR}"

# 書き込み権限を付与
chmod -R u+w "${EXTRACT_DIR}"

echo "  ✓ ISO 展開完了"

# ---------------------------------------------------------------------------
# 2. preseed.cfg の配置
# ---------------------------------------------------------------------------
echo "[2/5] preseed.cfg を配置中..."
cp "${SCRIPT_DIR}/preseed.cfg" "${EXTRACT_DIR}/preseed.cfg"
echo "  ✓ preseed.cfg"

# ---------------------------------------------------------------------------
# 3. cocoro ディレクトリの配置
# ---------------------------------------------------------------------------
echo "[3/5] cocoro ファイルを配置中..."
mkdir -p "${EXTRACT_DIR}/cocoro"
cp "${SCRIPT_DIR}/cocoro/firstboot.sh" "${EXTRACT_DIR}/cocoro/firstboot.sh"
cp "${SCRIPT_DIR}/cocoro/cocoro-firstboot.service" "${EXTRACT_DIR}/cocoro/cocoro-firstboot.service"
echo "  ✓ cocoro/"

# ---------------------------------------------------------------------------
# 4. ブート設定の更新
# ---------------------------------------------------------------------------
echo "[4/5] ブート設定を更新中..."

# ISOLINUX (BIOS ブート)
cat > "${EXTRACT_DIR}/isolinux/txt.cfg" << 'EOF'
label install
	menu label ^Install cocoro OS
	kernel /install.amd/vmlinuz
	append auto=true priority=critical preseed/file=/cdrom/preseed.cfg vga=788 initrd=/install.amd/initrd.gz --- quiet 
EOF

# ISOLINUX: デフォルトを install に設定 + タイムアウト短縮
sed -i 's/^timeout .*/timeout 30/' "${EXTRACT_DIR}/isolinux/isolinux.cfg"
sed -i 's/^default .*/default install/' "${EXTRACT_DIR}/isolinux/isolinux.cfg"

# GRUB (UEFI ブート) - preseed パスと自動起動の設定
if [ -f "${EXTRACT_DIR}/boot/grub/grub.cfg" ]; then
  # preseed パラメータを全 menuentry に追加（まだない場合）
  if ! grep -q "preseed/file=/cdrom/preseed.cfg" "${EXTRACT_DIR}/boot/grub/grub.cfg"; then
    sed -i 's|--- quiet|--- quiet auto=true priority=critical preseed/file=/cdrom/preseed.cfg|g' "${EXTRACT_DIR}/boot/grub/grub.cfg"
  fi
  # 既存の set default / set timeout を削除
  sed -i '/^set default=/d' "${EXTRACT_DIR}/boot/grub/grub.cfg"
  sed -i '/^set timeout=/d' "${EXTRACT_DIR}/boot/grub/grub.cfg"
  # 最初の menuentry の直前に default と timeout を挿入
  sed -i '0,/^menuentry/{s/^menuentry/set default="Install"\nset timeout=3\nmenuentry/}' "${EXTRACT_DIR}/boot/grub/grub.cfg"
  echo "  ✓ grub.cfg"
fi

echo "  ✓ isolinux/txt.cfg"

# ---------------------------------------------------------------------------
# 5. カスタム ISO の生成
# ---------------------------------------------------------------------------
echo "[5/5] カスタム ISO を生成中..."
mkdir -p "$(dirname "${CUSTOM_ISO}")"

# MD5 チェックサムを再生成
cd "${EXTRACT_DIR}"
find . -follow -type f ! -name md5sum.txt -print0 | xargs -0 md5sum > md5sum.txt 2>/dev/null || true
cd - > /dev/null

# xorriso で ISO 生成 (UEFI + BIOS デュアルブート対応)
xorriso -as mkisofs \
  -o "${CUSTOM_ISO}" \
  -V "cocoro-os-installer" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "${EXTRACT_DIR}"

echo ""
echo "============================================"
echo "✓ カスタム ISO ビルド完了！"
echo "============================================"
echo ""
echo "ISO ファイル: ${CUSTOM_ISO}"
echo "サイズ: $(du -h "${CUSTOM_ISO}" | cut -f1)"
echo ""
echo "次のステップ:"
echo "  1. Rufus を起動"
echo "  2. この ISO を選択して USB に書き込む"
echo "     パーティション構成: GPT"
echo "     ターゲット: UEFI (non CSM)"
echo "  3. USB を miniPC に挿して電源ON"
echo "  4. 自動インストールが開始される"
echo ""
echo "ログイン情報:"
echo "  ユーザー: cocoro-admin"
echo "  パスワード: cocoro-factory-2026"
echo "  SSH: ssh cocoro-admin@cocoro.local"
echo "============================================"
