# Nix-Darwin System Configuration

このリポジトリは、macOSのシステム設定および開発環境を宣言的に管理するための Nix-Darwin 設定ファイル群です。
Infrastructure as Code (IaC) の原則に基づき、再現可能な環境構築を実現します。

## 前提条件 (Prerequisites)

*   **Nix**: マルチユーザーインストールが完了していること。
*   **Experimental Features**: `nix-command` および `flakes` が有効化されていること。

## 使い方 (Usage)

### 設定の適用 (Apply Configuration)

以下のコマンドを実行して、最新の設定をシステムに適用します。

```bash
darwin-rebuild switch --flake .
```

初回実行時やホスト名が異なる場合は、Flake名 (Hostname) を指定してください。

```bash
darwin-rebuild switch --flake .#Yuis-MacBook-Pro
```

### 利用可能なカスタムツール (Custom Tools)

`home.nix` で定義され、システムの PATH に自動的に追加される独自のユーティリティツール群です。

*   **`gemini-rag`**: Gemini API を使用した RAG (Retrieval-Augmented Generation) ツール。
*   **`markthesedown`**: `markitdown` ライブラリを使用し、様々なファイルを Markdown に変換するツール。
*   **`urls-under`**: 指定した URL 配下のリンクを収集するスクレイピングツール。
*   **`urls2contents`**: URL リストからコンテンツを抽出するツール。
*   **`download-slack-channel-files`**: Slack チャンネルからファイルをダウンロードするツール。
*   **`flatten-dir`**: ディレクトリ構造を平坦化するユーティリティ。
*   **`cat-all`**: 指定ディレクトリ内のファイルを結合して出力するユーティリティ。

### シークレット管理 (Secrets Management)

機密情報 (APIキー等) は **[SOPS (Secrets OPerationS)](https://github.com/mozilla/sops)** と `sops-nix` を用いて暗号化・管理されています。

*   **暗号化ファイル**: `secrets.yaml`
*   **復号鍵**: `~/.config/sops/age/keys.txt` (手動配置が必要)

APIキーなどの環境変数は、`gemini-rag` などのラッパースクリプト内で自動的に読み込まれます。

## ディレクトリ構造 (Directory Structure)

*   `flake.nix`: エントリーポイント。システム全体の依存関係と出力定義。
*   `home.nix`: Home Manager 設定。ユーザー固有のパッケージや dotfiles 管理。
*   `scripts/`: カスタムスクリプトのソースコード (TypeScript, Python, Shell)。
*   `prompt/`: AI アシスタント用のプロンプト定義 (`antigravity.md` 等)。
*   `secrets.yaml`: 暗号化されたシークレットファイル。

## Antigravity Philosophy

このリポジトリは、"Antigravity" (重力＝既存の常識からの解放) の哲学に基づき管理されています。
AI アシスタントへの指示書 (`GEMINI.md`) も Nix を通じて宣言的に `~/.gemini/GEMINI.md` に配置されます。
