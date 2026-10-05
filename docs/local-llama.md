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

定義元は `modules/local-llama.nix`。127.0.0.1:43127、alias `local-qwen`、GPU全レイヤー要求、context 65536（64K）、parallel 1、Jinja、Flash Attention auto。
host/portは一箇所で定義し、サーバー・pi・Kilo・SwiftBarで共有する。
43127は2026-10-05時点でIANA未割当・手元で未使用、macOSの一時ポート範囲49152–65535の外を選択した。将来の占有は起動時にも確認する。
KVキャッシュ量子化は指定しない。ローカルGGUFをofflineでロードし、サーバー起動に伴うダウンロードは行わない。
`--sleep-idle-seconds -1` で自動sleepを無効にする。ロードしたモデルは手動でアンロードするまで保持する。
SwiftBarの「ロード（ON）」でサーバーを起動して読み込み、「アンロード（OFF・メモリ解放）」でサーバーを終了し、モデル・KV・GPUバッファを解放する。
どちらもメニューを一回選択するだけ。ロード完了までの時間はモデル容量やストレージに依存し、瞬時とは限らない。
アンロード後はAPIも停止する。再接続する前にロードを選ぶ。推論中のアンロードは進行中の応答を中断する。

推論サーバーのRunAtLoad/KeepAliveはfalse。ログイン時の自動起動・終了後の自動再起動はしない。
stdout/stderrは `/dev/null` で、prompt・コード・推論ログを永続保存しない。
SwiftBarだけはログイン時に起動する軽量なUIで、推論サーバーとは別のjob。
5秒ごと、またはメニューを開いたときに状態を更新する。

| 表示 | 意味 |
|---|---|
| ON | サーバーが動作し、モデルがメモリに載っている |
| OFF | 推論サーバーが終了し、モデル・KV・GPUバッファを解放済み |
| 読込中 | 起動中でAPI応答を待っている |
| モデル未選択／エラー／未適用 | GGUF未選択、job終了失敗、設定が未適用 |

メニューからロード、アンロード、状態更新、モデル保存場所、Web UIを操作できる。
状態確認は公式 `GET /props` を使う。
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
公開conversion logのqwen35構造、採用ソースのqwen35/Q4_K/Jinja実装は確認済みだが、上記の公式27B GGUF自体のロード・template・36GB機でのメモリ適合は未検証。

## pi / Kilo

導入済みpi 1.0.2、Kilo CLI (`kilocode`) 7.8.3。
確認したVS Code/Cursorの拡張ディレクトリにはKilo拡張はなかった。
provider `local-llama`、モデル `local-qwen`、API `http://127.0.0.1:43127/v1`、context 65536、出力上限4096。
ローカル専用ダミー値 `local-only-unused` を使い、認証ファイルは変更しない。
適用時にmodels.jsonとkilo.json[c]へproviderを追加する。既存設定・JSONCコメントを保持し、初回のみ `.before-local-llama` へバックアップする。
同名providerは、それ以外の内容が宣言と一致するときだけローカル接続先のポート、context、生成したモデル表示名の変更を反映し、既存コメント・認証値を保持する。それ以外の差異や管理されたsymlinkの場合は変更を拒否する。

piの `~/.pi/agent/settings.json` には、モデル別の圧縮設定も追加する。
`compaction.modelOverrides["local-llama/local-qwen"]` の `reserveTokens = 8192`、`keepRecentTokens = 16384` をNixで管理する。
64Kのうち8Kを新規入力・ツール結果と4Kの応答用に確保し、入力が56Kを超えたら古い履歴を要約して直近約16Kを保持する。
以前の16K設定にpi既定の予約16K・保持20Kを組み合わせると、開始直後から圧縮対象になり、`Nothing to compact (session too small)` が出たため、モデル別に予算を指定している。
他モデルの圧縮設定、グローバル設定、テーマなどの既存値は保持する。settings.jsonは通常の編集可能なJSONのままで、追加時に整形・バックアップする。
起動中のpiには再起動で反映する。保存済みの会話を続ける場合は、同じ作業ディレクトリで下記コマンドに `--resume` を付け、`--no-session` を外して対象の会話を選ぶ。
入力と応答の合計が64Kを超える場合は、この調整でも収まらない。入力を絞るか、メモリを確認してサーバーとクライアントのcontextを一緒に増やす。容量の増加は処理の高速化を意味しない。

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
- piのモデル別圧縮設定: 既存のグローバル設定・他モデルの予算・テーマの保持、バックアップ、再実行、symlink・不正な設定の拒否を確認。
- 小型モデルでMetal MTL0 / Apple M3 Max、全29/29レイヤーoffload、推論中swapは0MiBで増加なし。
- 手動ロード／アンロードを専用の一時launchd job、127.0.0.1:43127、Qwen3-0.6Bで検証: ロードからAPI応答まで約0.81秒、アンロードからプロセス終了まで約0.14秒。alias、メニュー出力、ポート解放も確認。27Bの所要時間は未測定。
- SwiftBar用ON/OFFメニュー出力、モデル未選択の拒否を確認。
- 一時サーバーとjobは停止・削除済み。モデル選択・クライアント認証は変更していない。

以前の16K設定の検証では、利用者がロード済みの `Qwen3.8-27B-Uncensored-HauhauCS-Aggressive-Q4_K_P.gguf` に対し、pi 1.0.2の通常応答2往復を確認。
隔離した一時ディレクトリで人工的な履歴を増やし、約11.6Kまでは通常応答を確認した。約14.3Kでは `stopReason: length` となり、その後の要約・回復は4分の検証期限内に完了しなかった。長い履歴の自動圧縮からの復帰は未確認で、短い会話の成功とは区別する。
`settings.json` のローカルモデル用予算だけを一般ユーザー権限で反映し、既存値、models.json、Kilo、認証ファイルの保持を確認した。
Nixにも同じ設定を保存して対象hostをビルド済み。sudo switchは実行していない。検証用piは終了し、利用者が起動していたサーバーは維持する。

64Kへの変更では、同じ手元の27B GGUFを一時サーバー（127.0.0.1:43128）で検証した。
二重ロードを避けるため、待機中の既存16K jobを一時停止し、検証後に元のjobへ戻した。

- `/props` の `n_ctx = 65536`、`/v1/models` の `local-qwen`、通常応答: 確認。
- pi 1.0.2に64Kの一時設定を渡し、応答とストリーミング（26更新）: 確認。
- 起動ログでApple M3 Max / Metal MTL0、全66/66レイヤーoffload、Flash Attention有効、KV 4096 MiBを確認。
- Metalモデルバッファ16810 MiB、計算バッファ417 MiB。これらは64Kを割り当てた起動時の値で、64K全量の入力ベンチマークではない。
- 短い推論中のメモリプレッシャーは正常（level 1）。既存swapは約3912 MiBで増加なし。
- 実設定のコピーで16K→64K→16Kを往復し、JSONCコメントも含め元の内容への復帰、他provider・認証値の保持、再実行、カスタム設定の衝突拒否を確認。
- 一時サーバーは終了、既存16Kサーバーは復帰。実クライアント設定はハッシュで未変更を確認。64Kの恒久適用は確認待ち。

**未検証**: 適用後の実メニューバー表示・クリック、公式候補27Bのロード、64K上限までの実入力・長文圧縮・27Bのtool calling・同時使用アプリを増やした際のメモリ適合、画像、思考制御・思考履歴。

ユーザー確認まではswitchしない。適用後はサーバーを起動せず、メニューバーだけが起動する。

```sh
nix build '.#darwinConfigurations.Yuis-MacBook-Pro.system' --no-link
# 確認後のみ:
sudo darwin-rebuild switch --flake /private/etc/nix-darwin
```

停止だけならメニューOFFか `llama-off`。導入を戻す場合はOFFにし、flakeのlocal-llama importを外して再ビルド・確認後に適用する。
実クライアント設定からlocal-llama providerだけ削除すれば後続編集を保持できる。
piの `settings.json` から `compaction.modelOverrides["local-llama/local-qwen"]` だけ削除すると、今回のモデル別圧縮設定も戻せる。
64Kから16Kへ戻す場合は、`settings.context = 16384`、piの `reserveTokens = 4096` / `keepRecentTokens = 4096` に変更して再ビルド・確認後に適用する。サーバーとpiを再起動する。provider移行処理はcontextの縮小にも対応する。
後続編集がない場合だけバックアップを戻す。GGUFは別管理なので残る。

参照: [公式CLI](https://github.com/ggml-org/llama.cpp/blob/v0.5.0/README.md)、[サーバー設定](https://github.com/ggml-org/llama.cpp/blob/v0.5.0/tools/server/README.md)、[SwiftBar](https://github.com/swiftbar/SwiftBar)。
