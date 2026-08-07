# nix-darwin

yui の macOS (nix-darwin + Home Manager) 設定。単一 flake / 単一マシン。

旧 `plural-reality/nix-darwin` の 2層 (upstream/downstream) 構成を統合し、
plural-reality への参照・依存を撤廃済み。経緯は `docs/consolidation-plan.md`。

## これは何か

このリポジトリ 1 つで、macOS の状態を宣言的に再現する:

- **CLI / GUI ツール** (git, zsh, neovim, AI agent 群, agent-browser など)
- **dotfiles** (Claude Code / Codex / Gemini / Cursor の設定・skills・MCP)
- **macOS のシステム設定** (defaults)
- **暗号化された secrets** (API keys 等; sops-nix で復号)

ターゲットは `aarch64-darwin` (Apple Silicon) の 1 マシン、設定名は
`Yuis-MacBook-Pro`。手で何かを `brew install` したり設定をいじる代わりに、
Nix がここに書かれた通りの状態へマシンを収束させる。

---

## ゼロからのインストール (Nix 未導入のマシン)

新しい Mac、または Nix が入っていないマシンを想定。上から順に実行する。

### 0. 前提

- Apple Silicon の macOS (Sonoma 以降を推奨)
- Xcode Command Line Tools: `xcode-select --install`

### 1. Nix 本体を入れる

本家の [NixOS/nix-installer](https://github.com/NixOS/nix-installer) を素のまま使う:

```bash
curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install
```

flakes (`nix-command` / `flakes`) の有効化はここでは**やらない**。永続的な
`experimental-features` は `flake.nix` の `nix.settings` が single source of
truth として持ち、初回 switch 時に nix-darwin が `/etc/nix/nix.conf` へ書く
(手順 4)。インストーラや手書き `nix.conf` で同じ設定を二重に持たせない。

インストール後、**ターミナルを開き直す** (PATH と daemon を読み込むため)。
確認:

```bash
nix --version
```

### 2. リポジトリを取得

正規の置き場所は `/private/etc/nix-darwin`。`apply` も flake 内のパス参照も
ここを前提にしている。

```bash
sudo mkdir -p /private/etc/nix-darwin
sudo chown "$(id -un)":staff /private/etc/nix-darwin
git clone git@github.com:yuidvg/nix-darwin.git /private/etc/nix-darwin
cd /private/etc/nix-darwin
```

### 3. SOPS の age 秘密鍵を配置する (secrets を使う場合は必須)

`personal.nix` は `secrets.yaml` を sops-nix で復号する。復号には
`.sops.yaml` の公開鍵
(`age1svzwe9nzx6cm6xy2ykpkalwp70u2xcf2st5efydc6ruf9ffjlsps9zxkw2`)
に対応する **age 秘密鍵** が必要。

鍵を次の場所へ置く (flake が参照するパス):

```bash
mkdir -p ~/.config/sops/age
# 既存マシンや 1Password 等から秘密鍵を取り出して配置する
cp /path/to/keys.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt
```

> 鍵が無いと secrets の復号に失敗する。secrets が不要なら、`flake.nix` の
> `secretsFile` を `null` にすれば sops モジュールごと無効化できる
> (API keys 系の機能は動かなくなる)。

### 4. 初回 bootstrap (`darwin-rebuild` がまだ無い)

まだ `darwin-rebuild` コマンドが無いので、`nix-darwin` を直接実行して
最初の世代を構築・適用する。flakes はまだ有効化していないので、**この 1 回だけ**
`--extra-experimental-features` で inline 有効化する (永続設定は switch 後に
nix-darwin が書くため、フラグはこのコマンドのスコープに閉じる):

```bash
sudo nix run --extra-experimental-features 'nix-command flakes' \
  nix-darwin/master#darwin-rebuild -- switch --flake .#Yuis-MacBook-Pro
```

これで `darwin-rebuild` 自体も含めて設定がインストールされ、以降
`/etc/nix/nix.conf` は nix-darwin 管理下になる。完了後、**ターミナルを開き直す**。

### 5. 以降の適用

2 回目からは付属の `apply` スクリプトを使う:

```bash
./apply        # = sudo darwin-rebuild switch --flake .#Yuis-MacBook-Pro
```

### 適用前の検証 (任意)

切り替えずにビルドだけ通るか確認したいとき:

```bash
nix build .#darwinConfigurations."Yuis-MacBook-Pro".system
```

---

## 構成

| パス | 役割 |
|---|---|
| `flake.nix` | 単一 `darwinConfigurations."Yuis-MacBook-Pro"`、inputs、perSystem (Haskell/packages) |
| `modules/base.nix` | programs (git, zsh, neovim 等)、env、macOS defaults、共通 CLI (`agent-browser` 含む) |
| `modules/claude-code.nix` | Claude Code / Codex / Gemini / Cursor の dotfiles・skills・MCP |
| `modules/shared-scripts.nix` | スクリプト群の home.packages 化 |
| `personal.nix` | SOPS secrets、個人パッケージ、codex/zsh/git 個人設定 |
| `prompt/` | AI プロンプト・skills (Claude/Codex 共有ソース) |
| `packages/` | codelayer / xcodebuildmcp / desktop-skills |
| `scripts/` | Haskell/Python/Shell ソース |
| `secrets.yaml`, `.sops.yaml` | sops-nix 暗号化 secrets |

## LLM システムプロンプトの detach (脳を空にする)

`modules/claude-code.nix` は本来、`prompt/` 配下の共有プロンプト
(`engineering.md` / `unix-principal.md` 等) を各エージェントの常時
システムプロンプトへ投影する。現在この**最終 wiring だけを detach**しており、
投影先を空文字列にしている:

| ファイル | 状態 |
|---|---|
| `~/.claude/CLAUDE.md` | 空 |
| `~/.codex/AGENTS.md` | 空 |
| `~/.gemini/GEMINI.md` | 空 |
| `~/.cursorrules` | 空 |

つまり Claude Code / Codex / Gemini / Cursor は、この repo からは常時
システムプロンプトを注入されず、各ツールの素の挙動で動く。

- **定義は温存**: `prompt/*.md` (本体・wrapper テンプレート) は一切変更していない。
  skills / agents / commands / MCP / settings も無影響。
- **再接続**: `mkAgentAttrs` の `{ "${instructionPath}".text = ""; }` を元の
  `expandTemplate` 投影に戻せば再 wiring される (`instructionTemplate` は
  agentProfiles に dormant な再接続ポイントとして残してある)。Gemini / Cursor は
  `home.file` の該当 `.text = ""` を元に戻す。

## 開発

```bash
nix develop    # HLS, fourmolu, cabal-gild, nixfmt
nix fmt        # nixfmt で整形
```

## トラブルシュート

- **`darwin-rebuild: command not found`**: 初回 bootstrap (手順 4) がまだ。
  または PATH 反映のためターミナルを開き直す。
- **`experimental feature 'nix-command'/'flakes' ... disabled`**: 初回 bootstrap で
  `--extra-experimental-features 'nix-command flakes'` を付け忘れている (手順 4)。
  switch が一度通れば以降は nix-darwin 管理の `/etc/nix/nix.conf` で有効化される。
- **secrets 復号エラー (sops)**: `~/.config/sops/age/keys.txt` が無い/鍵が
  公開鍵に対応していない。手順 3 を確認。
- **`Yuis-MacBook-Pro` という設定名で動くか**: 設定名は flake 内で固定なので、
  実機のホスト名と一致していなくても `--flake .#Yuis-MacBook-Pro` で適用できる。
