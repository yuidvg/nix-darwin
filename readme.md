# Nix-Darwin System Configuration

macOS のシステム設定および開発環境を宣言的に管理する Nix-Darwin 設定リポジトリ。
Infrastructure as Code (IaC) に基づき、再現可能な環境構築を実現する。

## 前提条件

- **Nix** がマルチユーザーインストール済みであること
- **Experimental Features** (`nix-command`, `flakes`) が有効であること

```bash
# 確認方法
nix --version
nix flake --help  # エラーが出なければ OK
```

## セットアップ手順

このリポジトリを Fork し、以下の手順で自分用に設定する。

### Step 1: Clone & 個人情報の設定

```bash
git clone <YOUR_FORKED_REPO_URL> ~/nix-config
cd ~/nix-config
```

`flake.nix` 冒頭の `userConfig` を自分の情報に書き換える:

```nix
userConfig = {
  username = "yui";        # whoami の出力
  hostname = "My-Mac";     # scutil --get LocalHostName の出力
  gitName = "Taro Yamada"; # Git コミット名
  gitEmail = "taro@ex.com";# Git Email
};
```

### Step 2: Age 鍵の生成

SOPS による秘密情報管理のため、自分用の Age 鍵ペアを生成する。

```bash
# ディレクトリ作成 & 鍵生成
mkdir -p ~/.config/sops/age
nix shell nixpkgs#age -c age-keygen -o ~/.config/sops/age/keys.txt
```

生成された公開鍵を控えておく（次のステップで使う）:

```bash
nix shell nixpkgs#age -c age-keygen -y ~/.config/sops/age/keys.txt
# => age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

### Step 3: `.sops.yaml` の公開鍵を差し替える

`.sops.yaml` にはリポジトリ作者の公開鍵がハードコードされている。
**自分の公開鍵に差し替えないと、自分で復号できないファイルが作られてしまう。**

```yaml
# .sops.yaml
creation_rules:
  - path_regex: secrets\.yaml(\.plain)?$
    age: >-
      age1xxxxxx...  # ← Step 2 で控えた自分の公開鍵に書き換える
```

### Step 4: シークレットの作成 & 暗号化

```bash
# テンプレートから作成し、自分の API キー等を記入
cp secrets.example.yaml secrets.yaml
vim secrets.yaml
```

暗号化する。**初回は `darwin-rebuild` 前なので `SOPS_AGE_KEY_FILE` を明示指定する:**

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt \
  nix run nixpkgs#sops -- --encrypt --in-place secrets.yaml
```

> [!IMPORTANT]
> `darwin-rebuild switch` 後は `SOPS_AGE_KEY_FILE` が `sessionVariables` により自動設定されるため、
> 以降は `nix run nixpkgs#sops -- secrets.yaml` だけで編集・再暗号化できる。

### Step 5: 設定の適用

```bash
darwin-rebuild switch --flake .
```

適用後、新しいシェルを開けば全設定が有効になる。

### Step 6: 動作確認

```bash
# シークレットが読めるか確認
echo $GEMINI_API_KEY

# sops で秘密情報を再編集（鍵パスの明示不要になっているはず）
nix run nixpkgs#sops -- secrets.yaml
```

## 開発環境

このリポジトリ自体のメンテナンスや Haskell スクリプト開発のための環境も Nix で定義されている。

### Direnv の有効化

```bash
cd ~/nix-config
direnv allow
```

ロード完了後、以下が利用可能になる:

- `cabal` — Haskell ビルドツール
- `haskell-language-server` — エディタ補完
- `fourmolu` — コードフォーマッタ

### VSCode を使う場合

direnv が提供する環境（HLS 等）を VSCode で利用するには、**direnv 拡張機能** が必要:

1. [direnv (mkhl.direnv)](https://marketplace.visualstudio.com/items?itemName=mkhl.direnv) をインストール
2. このリポジトリを VSCode で開く
3. `direnv allow` 済みであれば、HLS が自動で認識される

> [!TIP]
> Haskell 拡張 ([Haskell Language Server](https://marketplace.visualstudio.com/items?itemName=haskell.haskell)) も合わせてインストールすると補完・型表示が有効になる。

## カスタムツール

`home.nix` で定義され、PATH に自動追加されるユーティリティ群:

| ツール | 概要 |
|---|---|
| `gemini-rag` | Gemini API を使用した RAG ツール |
| `markthesedown` | 各種ファイル → Markdown 変換 |
| `urls-under` | 指定 URL 配下のリンク収集 |
| `urls2contents` | URL リストからコンテンツ抽出 |
| `download-slack-channel-files` | Slack チャンネルからファイル DL |
| `flatten-dir` | ディレクトリ構造の平坦化 |
| `cat-all` | ディレクトリ内ファイルの結合出力 |

## シークレット管理

機密情報は **SOPS** + **Age** で暗号化管理されている。

| 項目 | パス |
|---|---|
| 暗号化ファイル | `secrets.yaml` |
| 復号鍵 (秘密鍵) | `~/.config/sops/age/keys.txt` |
| SOPS 設定 | `.sops.yaml` |

API キーなどの環境変数は `sops-nix` により復号され、zsh 起動時に自動ロードされる。

## ディレクトリ構造

```
.
├── flake.nix          # エントリーポイント。依存関係と出力定義
├── home.nix           # Home Manager 設定。パッケージ・dotfiles 管理
├── scripts/           # カスタムスクリプト (TypeScript, Python, Haskell)
├── prompt/            # AI アシスタント用プロンプト定義
├── secrets.yaml       # 暗号化されたシークレット
├── secrets.example.yaml # シークレットのテンプレート
├── .sops.yaml         # SOPS 暗号化ルール (公開鍵定義)
└── .envrc             # direnv 設定 (use flake)
```

## トラブルシューティング

### `sops` 実行時に鍵が見つからない

`darwin-rebuild switch` 前、または別のシェルコンテキスト（direnv 環境内等）では
`SOPS_AGE_KEY_FILE` が未設定の場合がある。明示的に指定する:

```bash
SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt nix run nixpkgs#sops -- secrets.yaml
```

### `direnv` が遅い / 毎回評価される

`nix-direnv` が有効であれば評価結果はキャッシュされる。
初回のみ時間がかかるのは正常。`.direnv/` ディレクトリがキャッシュ。

### VSCode で HLS が動かない

1. `direnv` 拡張がインストールされているか確認
2. VSCode のターミナルで `which haskell-language-server` が解決できるか確認
3. `direnv allow` を再実行してみる
