# Nix-Darwin System Configuration

このリポジトリは、macOSのシステム設定および開発環境を宣言的に管理するための Nix-Darwin 設定ファイル群です。
Infrastructure as Code (IaC) の原則に基づき、再現可能な環境構築を実現します。

## 前提条件 (Prerequisites)

*   **Nix**: マルチユーザーインストールが完了していること。
*   **Experimental Features**: `nix-command` および `flakes` が有効化されていること。

## 使い方 (Quick Start for Team Members)

このリポジトリはテンプレートとして機能します。自分のGitHubアカウントに Fork してから使用してください。

### 1. リポジトリの準備
```bash
# 1. Forkした自分のリポジトリをClone
git clone <YOUR_FORKED_REPO_URL> ~/nix-config
cd ~/nix-config

# 2. Configの書き換え (ここだけ変更すればOK！)
vim flake.nix
```
`flake.nix` の冒頭にある `userConfig` ブロックを、自分自身の情報に書き換えてください。
```nix
      userConfig = {
        username = "yui";        # 自分のユーザー名 ("whoami" で確認)
        hostname = "My-Mac";     # 自分のホスト名 ("scutil --get LocalHostName" で確認)
        gitName = "Taro Yamada"; # Gitコミット名
        gitEmail = "taro@ex.com";# Git Email
      };
```

### 2. シークレットの準備 (Sops)
APIキーなどの秘密情報は [Sops](https://github.com/mozilla/sops) で暗号化されています。
自分用の鍵で再暗号化（Re-encrypt）する必要があります。

> [!TIP]
> **再現性のために**: `nix shell` (特定の環境に入る) や `nix run` (特定コマンドを実行する) を使い分け、依存関係を明示的に指定して実行します。

```bash
# 1. 鍵の生成 (初回のみ)
# age-keygen は age パッケージの一部であるため、shell で環境に入って実行します
nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/keys.txt

# 2. シークレットファイルの作成
# テンプレートから secrets.yaml を作成し、自分のAPIキー等を記入します
cp secrets.example.yaml secrets.yaml
vim secrets.yaml

# 3. 暗号化して保存
# 公開鍵は age-keygen -y で自身の秘密鍵から導出します (grep依存の排除)
nix run nixpkgs#sops -- --encrypt --age $(nix shell nixpkgs#age -c age-keygen -y ~/.config/sops/age/keys.txt) secrets.yaml > secrets.enc.yaml
mv secrets.enc.yaml secrets.yaml

# 4. Commit
git add secrets.yaml
git commit -m "chore: setup my secrets"
```

### 3. 設定の適用 (Apply)
```bash
darwin-rebuild switch --flake .
```

## 開発環境 (Development Environment)

このリポジトリ自体のメンテナンスや、Haskellスクリプトの開発を行うための環境も Nix で定義されています。

### Direnv の有効化
ディレクトリに移動した直後に `direnv` を許可することで、必要なツールチェーン (GHC, HLS, Cabal など) が自動的にロードされます。

```bash
direnv allow
```

ロード完了後、以下のコマンドが利用可能になります：
*   `cabal`: Haskellビルドツール
*   `haskell-language-server`: エディタ補完用
*   `format`: コードフォーマッタ


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
