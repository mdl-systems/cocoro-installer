# ============================================================================
# cocoro-installer: Packer Build Definition
# ============================================================================
# Debian 13 (Trixie) カスタムインストール ISO ビルド定義
# 目的: 工場キッティング用ゼロタッチ自動インストール USB の作成
# ============================================================================

packer {
  required_version = ">= 1.9.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# ---------------------------------------------------------------------------
# 変数定義
# ---------------------------------------------------------------------------

variable "debian_version" {
  type        = string
  default     = "13"
  description = "Debian メジャーバージョン"
}

variable "debian_codename" {
  type        = string
  default     = "trixie"
  description = "Debian コードネーム"
}

variable "iso_url" {
  type        = string
  default     = "https://cdimage.debian.org/cdimage/weekly-builds/amd64/iso-cd/debian-testing-amd64-netinst.iso"
  description = "Debian 13 (Trixie) ネットインストール ISO の URL"
}

variable "iso_checksum" {
  type        = string
  default     = "none"
  description = "ISO ファイルの SHA256 チェックサム (none: チェックスキップ)"
}

variable "output_directory" {
  type        = string
  default     = "output"
  description = "ビルド成果物の出力先ディレクトリ"
}

# 注意: admin_username / admin_password は preseed.cfg 内で直接定義。
# communicator = "none" のため Packer 側での認証情報は不要。

variable "disk_size" {
  type        = string
  default     = "524288M"
  description = "仮想ディスクサイズ (テスト用: QEMU ビルド時)"
}

variable "memory" {
  type        = number
  default     = 2048
  description = "仮想マシンのメモリ (MB)"
}

variable "cpus" {
  type        = number
  default     = 2
  description = "仮想マシンの CPU 数"
}

variable "cocoro_core_repo" {
  type        = string
  default     = "https://github.com/mdl-systems/cocoro-core"
  description = "cocoro-core Git リポジトリ URL"
}

# ---------------------------------------------------------------------------
# ローカル変数
# ---------------------------------------------------------------------------

locals {
  build_timestamp = formatdate("YYYYMMDD-hhmm", timestamp())
  vm_name         = "cocoro-os-${var.debian_codename}-${local.build_timestamp}"
}

# ---------------------------------------------------------------------------
# ビルドソース: QEMU (ISO → カスタムイメージ)
# ---------------------------------------------------------------------------

source "qemu" "cocoro-os" {
  vm_name          = local.vm_name
  output_directory = "${var.output_directory}/${local.vm_name}"

  # ISO 設定
  iso_url      = var.iso_url
  iso_checksum = var.iso_checksum

  # 仮想マシン設定
  # 注意: OVMF_CODE_4M + pflash VARS の組み合わせが TianoCore 起動に必要
  disk_size    = "51200M"
  memory       = var.memory
  cpus         = var.cpus
  accelerator  = "kvm"
  machine_type = "q35"
  firmware     = "/usr/share/OVMF/OVMF_CODE_4M.fd"

  # ネットワーク設定
  net_device = "virtio-net"

  # ディスク設定
  disk_interface   = "virtio"
  disk_compression = true
  format           = "raw"

  # --------------------------------------------------------------------------
  communicator     = "none"
  shutdown_timeout = "60m"

  # ブートコマンド: Debian Installer に preseed ファイルを供給
  # OVMF は PXE → HTTP Boot を試行してから CD-ROM を検出する (約2-3分)
  # boot_wait + boot_command 内の wait で合計4分以上待機する
  http_directory = "http"
  boot_wait      = "4m"
  boot_command = [
    "<down><wait>e<wait>",
    "<down><down><down><end>",
    " auto=true",
    " priority=critical",
    " preseed/url=http://{{ .HTTPIP }}:{{ .HTTPPort }}/preseed.cfg",
    " locale=en_US.UTF-8",
    " keymap=us",
    " hostname=cocoro",
    " domain=local",
    " interface=auto",
    " --- quiet",
    "<f10>"
  ]

  # ヘッドレス設定 (CI/CD 向け)
  headless = true

  # QEMU 追加引数
  # pflash VARS ドライブを追加 (ブートエントリの永続化用)
  qemuargs = [
    ["-cpu", "host"],
    ["-drive", "if=pflash,format=raw,readonly=off,file=ovmf_vars.fd"]
  ]
}

# ---------------------------------------------------------------------------
# ビルドステップ
# ---------------------------------------------------------------------------

build {
  sources = ["source.qemu.cocoro-os"]

  # --------------------------------------------------------------------------
  # 注意: Packer provisioner (shell) は使用しない
  # --------------------------------------------------------------------------
  # preseed.cfg の最後で poweroff を実行するため、OS インストール完了後に
  # VM が即座にシャットダウンされる。そのため Packer の SSH provisioner は
  # 接続できずタイムアウトエラーになる。
  #
  # すべてのセットアップは preseed late_command → in-target setup.sh で完結させる。
  # --------------------------------------------------------------------------

  # ビルド完了後の後処理
  post-processor "shell-local" {
    inline = [
      "echo '=================================================='",
      "echo ' cocoro-installer: ビルド完了'",
      "echo ' 出力: ${var.output_directory}/${local.vm_name}'",
      "echo ' タイムスタンプ: ${local.build_timestamp}'",
      "echo '=================================================='",
      "echo ''",
      "echo 'USB への書き込み手順:'",
      "echo '  sudo dd if=${var.output_directory}/${local.vm_name}/${local.vm_name} of=/dev/sdX bs=4M status=progress oflag=sync'",
      "echo ''",
      "echo '※ /dev/sdX は USB デバイスのパスに置き換えてください'",
    ]
  }
}
