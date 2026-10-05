# ローカル llama.cpp

## 構成

Home Managerが`llama-cpp`と`local-llama-server`を導入する。常駐・自動起動はしない。
固定済みnixpkgsのllama.cpp **v0.5.0 / build 11146 / 7fe450e**を採用。
2026-10-05に公式最新安定版との一致、aarch64-darwin、Metal有効、server同梱を確認した。
llm-agentsには独立したllama-serverパッケージがなく、追加inputやlock更新は不要だった。

起動条件は127.0.0.1:8080、alias `local-qwen`、GPU全レイヤー要求、context 16384、parallel 1、Jinja、Flash Attention auto。
KVキャッシュ量子化は指定しない。ログは通常のinfoを端末に出し、ログファイル・prompt保存・slot保存・server内蔵agentは有効にしない。
wrapperは継承した`LLAMA_ARG_*`を除去し、公開hostやログ先などの意図しない上書きを防ぐ。
ポートが使われていれば終了し、既存プロセスは停止しない。

## 起動・停止・モデル切り替え

適用後、ローカルの任意のGGUFを指定する。

```sh
local-llama-server /absolute/path/model.gguf
# または
LLAMA_MODEL=/absolute/path/model.gguf local-llama-server
```

停止は起動した端末でCtrl+C。モデル切り替えは停止して別のパスで再起動する。
ポートを変える場合は`--port 8081`を指定し、クライアントの接続先も揃える。
GPU offloadを確認する起動では`--diagnostics`を付ける。端末の`offloaded N/N layers to GPU`と`using device MTL0`を確認する。
診断出力もファイル保存はしない。
適用前でも、このcheckoutで`nix run .#local-llama-server -- /absolute/path/model.gguf`を使える。

Hugging Faceの対応GGUFはリポジトリと正確なファイル名を指定する。初回はダウンロードし、次回はキャッシュを使う。

```sh
local-llama-server \
  --hf-repo ggml-org/Qwen3.8-27B-GGUF \
  --hf-file Qwen3.8-27B-Q4_K_M.gguf
```

候補の配布元: <https://huggingface.co/ggml-org/Qwen3.8-27B-GGUF>
ファイル容量: **18,973,870,528 bytes（約19.0GB / 17.7GiB）**、2026-10-05確認。
既定保存先は`~/.cache/llama.cpp/`（`XDG_CACHE_HOME`があればその配下）。`LLAMA_CACHE=/path/outside/store`で変更できる。
モデル・HF_TOKEN・秘密情報をGit/Nix storeへ入れない。新しい認証は作らない。
HFの取得は上記コマンドを明示的に実行したときだけ行う。ローカルファイル指定はofflineで起動する。

候補GGUFの公開conversion logは`qwen35`構造と埋め込みchat templateを示しており、採用ソースにはqwen35とQ4_Kの実装がある。
これはソース上の対応確認であり、27Bのロード・template動作・速度・36GB機でのメモリ適合は未検証。
27Bの重みだけで約17.7GiBを使うため、他アプリ・KV・計算用バッファも含めて実測する。

## pi / Kilo CLI

実機導入済み: pi 1.0.0、Kilo CLI (`kilocode`) 7.8.3。現行lockのビルド対象piは1.0.2。
今回確認したVS Code / Cursorの拡張ディレクトリにはKilo拡張は見つからなかった。
両クライアントのprovider名は`local-llama`、モデルIDは`local-qwen`。
接続先は`http://127.0.0.1:8080/v1`、contextは16384、出力上限4096。
`local-only-unused`はローカルAPIにだけ渡すダミー値で、認証ファイルは変更しない。

適用時に`~/.pi/agent/models.json`と`~/.config/kilo/kilo.json[c]`へproviderを追加する。
既存provider・設定・JSONCコメントは保持し、初回のみ`.before-local-llama`へバックアップする。
同名providerが異なる設定で既にある場合や管理されたsymlinkの場合は変更を拒否する。
通常のJSONと、コメント・末尾カンマを含むJSONCを扱う。

```sh
pi --provider local-llama --model local-qwen --no-tools --no-session
kilocode --model local-llama/local-qwen
```

27Bについてreasoning・画像・tool callingを未検証のため、reasoning/画像は無効、Kiloの`tool_call`はfalse。
piのモデル設定にはtool calling能力のスイッチがないため、未検証段階は`--no-tools`で起動する。
思考量の制御・思考履歴の引き継ぎは未検証。検証用の小型モデルで通っても27Bへ自動的に転用しない。

## 適用・戻し方

対象hostの評価・ビルド後も、確認を得るまで`darwin-rebuild switch`を実行しない。
ビルドは現在のcheckout全体を含むので、既存のVPN/Wi-Fi等の変更も適用対象になる。

```sh
nix build '.#darwinConfigurations.Yuis-MacBook-Pro.system' --no-link
# ユーザー確認後のみ
sudo darwin-rebuild switch --flake /private/etc/nix-darwin
```

未適用なら稼働環境は変わっていない。戻す場合はflakeの`local-llama` importとpackage出力を外して再ビルド・確認後に適用する。
適用済みのclient設定は、他の後続編集を残すため`local-llama`のproviderだけ削除する。
後続編集がないと確認できる場合だけ`.before-local-llama`バックアップを戻す。
モデルは別管理なので残る。検証用小型GGUFが不要なら`~/.cache/llama.cpp/test-models/Qwen3-0.6B-Q4_0.gguf`だけ削除できる。

## 検証

2026-10-05、MacBook Pro M3 Max / 36GBで確認。

- 対象hostの評価とシステムビルド、wrapperのビルド、nix fmt、差分の空白検査: 成功。
- wrapperの引数検査、存在しないモデルの拒否、占有ポートの拒否: 成功。既存プロセスは停止していない。
- provider追加: 実設定の一時コピーで既存値保持を確認。JSONCコメント・末尾カンマ保持、再実行、同名衝突拒否も確認。
- pi 1.0.0とKilo CLI 7.8.3の一時設定で`local-llama/local-qwen`の認識を確認。
- 検証用モデルは`ggml-org/Qwen3-0.6B-GGUF`の`Qwen3-0.6B-Q4_0.gguf`（428,970,080 bytes）。
  revision `b5f37287796e5be0ea3dab2e7430873fb3f73e49`、SHA-256 `da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4`を照合。
- 小型モデルで`/v1/models` alias、通常応答、ストリーミング、tool call→無害な固定結果→最終応答: 成功。
- pi 1.0.2のローカル応答と一時ディレクトリ内の`write`、Kilo CLI 7.8.3の`read`→結果を含む最終応答: 成功。
  Kiloのテストは`--dir`で専用ディレクトリを明示し、readだけを許可した。
  tool_callは小型モデルの一時設定だけ有効化し、通常のprovider設定は未検証27B向けにfalseのまま。
- Metalログ: Apple M3 Max / `MTL0`、`offloaded 29/29 layers to GPU`。
  小型モデルのMetal重み約403MiB、16KのKV約1792MiB、計算用約110MiBを確認。
- 推論中の`memory_pressure -Q`のsystem-wide freeは76–77%、swap使用量は0MiBで増加なし。
  最初の試験の前後ではfree 89%→82%→89%、swapは0MiB。
  これらはシステム全体のスナップショットで、他プロセスの変化を含み得る。
- 一時サーバーは停止済み。試験ログは一時ファイルのみで閉じて削除。実クライアント設定・認証はまだ未変更。

**未検証**: 27Bのロード・実GPU offload・chat template・16K実入力・tool calling・メモリ適合、画像、思考量、思考履歴の引き継ぎ、switchによる適用。
小型モデルでの成功を27Bでの動作済みとは扱わない。27Bの重みは未取得。

参照:
- <https://github.com/NixOS/nixpkgs/blob/master/pkgs/by-name/ll/llama-cpp/package.nix>
- <https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md>
- <https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md>
- <https://kilo.ai/docs/ai-providers/openai-compatible>
- Kilo CLIは上記拡張向け設定ではなく、導入版の`kilo.json[c]` / `@ai-sdk/openai-compatible`形式を使用。
