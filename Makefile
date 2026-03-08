# ============================================================================
# cocoro-installer: Makefile
# ============================================================================
# ビルド・テスト・書き込み用コマンド集
# ============================================================================

.PHONY: help build validate clean usb-write test

# デフォルトターゲット
help: ## ヘルプを表示
	@echo ""
	@echo "  cocoro-installer - 工場キッティング用 Debian 13 自動インストール USB"
	@echo ""
	@echo "  使用方法:"
	@echo "    make validate   - Packer 定義ファイルを検証"
	@echo "    make build      - カスタムインストールイメージをビルド"
	@echo "    make clean      - ビルド成果物を削除"
	@echo "    make usb-write  - USB メモリにイメージを書き込み (要: USB_DEV=xxx)"
	@echo "    make hash       - preseed パスワードハッシュを生成"
	@echo ""

# ---------------------------------------------------------------------------
# ビルド
# ---------------------------------------------------------------------------

validate: ## Packer 定義ファイルの検証
	packer init .
	packer validate .
	packer fmt -check .
	@echo "✓ 検証完了: すべての定義ファイルが有効です"

build: validate ## カスタムインストールイメージのビルド
	@echo "OVMF_VARS.fd をコピー中..."
	cp /usr/share/OVMF/OVMF_VARS_4M.fd ovmf_vars.fd
	@echo "setup.sh を http/ に同期中..."
	cp scripts/setup.sh http/setup.sh
	packer build -force .
	@echo "✓ ビルド完了"

build-debug: ## デバッグモードでビルド (ログ詳細出力)
	cp /usr/share/OVMF/OVMF_VARS_4M.fd ovmf_vars.fd
	cp scripts/setup.sh http/setup.sh
	PACKER_LOG=1 packer build -force -on-error=ask .

# ---------------------------------------------------------------------------
# USB 書き込み
# ---------------------------------------------------------------------------

USB_DEV ?=
usb-write: ## USB にイメージを書き込み (make usb-write USB_DEV=/dev/sdX)
ifndef USB_DEV
	$(error USB_DEV が未指定です。例: make usb-write USB_DEV=/dev/sdb)
endif
	@echo "⚠️  警告: $(USB_DEV) の全データが消去されます"
	@echo "続行しますか？ [y/N] " && read ans && [ $${ans:-N} = y ]
	sudo dd if=$$(ls -t output/cocoro-os-*/cocoro-os-* | head -1) \
		of=$(USB_DEV) bs=4M status=progress oflag=sync
	sync
	@echo "✓ USB 書き込み完了: $(USB_DEV)"

# ---------------------------------------------------------------------------
# ユーティリティ
# ---------------------------------------------------------------------------

hash: ## preseed 用のパスワードハッシュを生成
	@echo "パスワードを入力してください:"
	@read -s password; echo "$$password" | mkpasswd -s -m sha-512

clean: ## ビルド成果物を削除
	rm -rf output/
	rm -rf packer_cache/
	rm -f ovmf_vars.fd
	@echo "✓ クリーンアップ完了"

lint: ## シェルスクリプトの構文チェック
	shellcheck scripts/setup.sh
	shellcheck scripts/firstboot.sh
	@echo "✓ Lint 完了"

tree: ## プロジェクト構成を表示
	@echo ""
	@echo "cocoro-installer/"
	@find . -not -path './output/*' -not -path './.git/*' -not -path './packer_cache/*' | \
		sort | sed 's|[^/]*/|  |g'
	@echo ""
