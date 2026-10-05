# ローカル llama.cpp

## 管理の分担

- Nix/Home Manager: llama.cpp、固定起動条件、launchd、SwiftBarとメニュー、pi/Kiloのprovider追加。
- 公式 `llama download`: Hugging Faceからのモデル取得とキャッシュ。
- GGUF本体・現在のモデル選択: Nix store/Git外。モデル切り替えにrebuildは不要。

独自の `local-llama-server` 起動wrapperとflake package出力は削除した。
launchdのProgramArgumentsに公式 `llama-server` と起動条件を指定する。
`llama-control` はlaunchdの状態確認・ON/OFFとSwiftBar表示だけを担当し、推論の起動引数・ダウンロード処理は持たない。
Home Manager標準のNix store待機処理を除き、独自の推論launcherは使わない。

採用版: **llama.cpp v0.5.0 / build 11146 / 7fe450e**、**SwiftBar 2.0.1**。
2026-10-05に公式最新安定版との一致、aarch64-darwin、Metal有効、公式CLI同梱を確認。
追加input、lock更新、Homebrew管理は不要。

## 起動設定とメニューバー

定義元は `modules/local-llama.nix`。127.0.0.1:8080、alias `local-qwen`、GPU全レイヤー要求、context 16384、parallel 1、Jinja、Flash Attention auto。
KVキャッシュ量子化は指定しない。ローカルGGUFをofflineでロードし、サーバー起動に伴うダウンロードは行わない。
`--sleep-idle-seconds 300` により、5分間使わなければモデルとKVをメモリから解放する。
次の推論リクエストで読み直すため、復帰時にはロード待ちがある。

推論サーバーのRunAtLoad/KeepAliveはfalse。ログイン時の自動起動・終了後の自動再起動はしない。
stdout/stderrは `/dev/null` で、prompt・コード・推論ログを永続保存しない。
SwiftBarだけはログイン時に起動する軽量なUIで、推論サーバーとは別のjob。
5秒ごと、またはメニューを開いたときに状態を更新する。

| 表示 | 意味 |
|---|---|
| ON | サーバーが動作し、モデルがメモリに載っている |
| 待機中 | APIは待受中、モデルとKVは自動解放済み |
| OFF | 推論サーバーを停止している |
| 読込中 | 起動中でAPI応答を待っている |
| モデル未選択／エラー／未適用 | GGUF未選択、job終了失敗、設定が未適用 |

メニューからON、OFF、状態更新、モデル保存場所、Web UIを操作できる。
状態確認は公式 `GET /props` を使い、モデルを起こさずidle timerもリセットしない。
専用jobが動作中の場合だけAPIへ問い合わせ、モデルパスも照合する。HTTP proxyは使わない。
ON時は使用中のポートを拒否する。OFFは専用jobだけを停止し、他のプロセスを止めない。

```sh
llama-on
llama-status
llama-off
# aliasがないシェルでも使える:
llama-control on
llama-control status --json
llama-control off
```

pluginは `~/.config/swiftbar/local-llama.5s.py` へNixから投影する。
SwiftBarのplugin保存先も宣言し、アプリの自動更新は無効化する。更新はNixで行う。

## モデルの取得・選択・切り替え

`~/.local/share/llama.cpp/active.gguf` というリンクで現在のモデルを選ぶ。
初期状態ではリンクも27Bの重みも作らない。モデルを選択してからONにする。

```sh
llama-off
ln -sfn /absolute/path/model.gguf ~/.local/share/llama.cpp/active.gguf
llama-on
```

Hugging Faceから取得する場合も公式CLIを使う。以下の明示実行時だけダウンロードする。
`--no-mmproj` で未検証の画像用sidecar取得を避ける。

```sh
MODEL_PATH=$(llama download \
  -hf ggml-org/Qwen3.8-27B-GGUF \
  -hff Qwen3.8-27B-Q4_K_M.gguf \
  --no-mmproj)
llama-off
ln -sfn "$MODEL_PATH" ~/.local/share/llama.cpp/active.gguf
llama-on
```

配布元: <https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF>
ファイル: `Qwen3.8-27B-Q4_K_M.gguf`、18,973,870,528 bytes（約19.0GB / 17.7GiB）、2026-10-05確認。
`LLAMA_CACHE` はNixから `~/.cache/llama.cpp/` へ設定する。GGUFやHF_TOKENをGit/Nix storeへ入れない。
削除するときはOFFにして対象GGUFだけを削除する。nix-collect-garbageはこの置き場を管理しない。
公開conversion logのqwen35構造、採用ソースのqwen35/Q4_K/Jinja実装は確認済みだが、27Bのロード・template・36GB機でのメモリ適合は未検証。

## pi / Kilo

導入済みpi 1.0.0、現行lockのビルド対象pi 1.0.2、Kilo CLI (`kilocode`) 7.8.3。
確認したVS Code/Cursorの拡張ディレクトリにはKilo拡張はなかった。
provider `local-llama`、モデル `local-qwen`、API `http://127.0.0.1:8080/v1`、context 16384、出力上限4096。
ローカル専用ダミー値 `local-only-unused` を使い、認証ファイルは変更しない。
適用時にmodels.jsonとkilo.json[c]へproviderを追加する。既存設定・JSONCコメントを保持し、初回のみ `.before-local-llama` へバックアップする。
同名providerが異なる設定で既にある場合や管理されたsymlinkの場合は変更を拒否する。

```sh
pi --provider local-llama --model local-qwen --no-tools --no-session
kilocode --model local-llama/local-qwen
```

27Bのreasoning・画像・tool callingは未検証。reasoning/画像を有効化せず、Kiloのtool_callはfalse。
piにはモデルごとのtool能力スイッチがないので、未検証段階は `--no-tools` を使う。
思考量・思考履歴の引き継ぎも未検証。小型モデルの成功を27Bへ自動転用しない。

## 検証・適用・戻し方

2026-10-05、M3 Max / 36GBで確認。

- 対象hostの評価・システムビルド、nix fmt、生成plist: 成功。
- provider追加処理: 実設定の一時コピーで既存値/JSONCコメント保持、再実行、衝突拒否を確認。
- 小型Qwen3-0.6B-Q4_0でalias、通常応答、ストリーミング、tool call→無害な結果→最終応答: 成功。
- pi 1.0.2の一時ディレクトリ内のファイル作成、Kilo 7.8.3のread→最終応答: 成功。
- 小型モデルでMetal MTL0 / Apple M3 Max、全29/29レイヤーoffload、推論中swapは0MiBで増加なし。
- 新しいON/OFF処理を専用の一時launchd label/portで検証: 初期OFF、ON、自動sleep、状態確認で起こさない、推論で再ロード、OFF、再起動: 成功。idle timerだけ試験用に1秒へ短縮し、通常の宣言は300秒。
- SwiftBar用ON/OFFメニュー出力、モデル未選択の拒否を確認。
- 一時サーバーとjobは停止・削除済み。本番の設定・モデル選択・クライアント認証は未変更。

**未検証**: 適用後の実メニューバー表示・クリック、27Bのロード・GPU offload・chat template・16K実入力・tool calling・メモリ適合、画像、思考制御・思考履歴。

ユーザー確認まではswitchしない。適用後はサーバーを起動せず、メニューバーだけが起動する。

```sh
nix build '.#darwinConfigurations.Yuis-MacBook-Pro.system' --no-link
# 確認後のみ:
sudo darwin-rebuild switch --flake /private/etc/nix-darwin
```

停止だけならメニューOFFか `llama-off`。導入を戻す場合はOFFにし、flakeのlocal-llama importを外して再ビルド・確認後に適用する。
実クライアント設定からlocal-llama providerだけ削除すれば後続編集を保持できる。
後続編集がない場合だけバックアップを戻す。GGUFは別管理なので残る。

参照: [公式CLI](https://github.com/ggml-org/llama.cpp/blob/v0.5.0/README.md)、[自動sleep](https://github.com/ggml-org/llama.cpp/blob/v0.5.0/tools/server/README.md#sleeping-on-idle)、[SwiftBar](https://github.com/swiftbar/SwiftBar)。
