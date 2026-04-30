---
name: purchase-research
description: 商品の最安・最適な購入ルートを agent-browser で実機確認しながら調査する。中古EC（メルカリ、メルカリShops、Yahoo!フリマ、ラクマ、ヤフオク、2nd STREET、ハードオフ、BookOff、ジモティー、Buyma）と新品EC（Yahoo!ショッピング、LOHACO、楽天市場、Amazon、ヨドバシ.com、ビックカメラ、ジョーシン、ノジマ、エディオン、au PAYマーケット、Qoo10、価格.com、専門店・公式）を並列調査し、ログイン済み実機の還元率とキャピタルロスを試算してTOP候補と判断フローを提示する。出力はチャットのみでファイル保存しない。発動条件: 「○○を買いたい/欲しい」「○○の最安」「○○のいい買い方」「最適な買い方」「中古でいいやつ探して」「○○のお得な買い方」等の購買意思決定リサーチ依頼。
---

# Purchase Research

商品を買うときの「最安・最適ルート」を、ログイン済みのリアル還元率で確定させるスキル。

## 鉄則

- **agent-browser のみ**を使う。WebFetch は禁止（JS描画・ログイン状態が反映されないため）
- **ファイル保存禁止**。出力はチャット内のマークダウンのみ。Desktop 等にレポートを書き出さない
- **ログイン状態を必ず実機確認**してから還元率を語る。推測で「○%還元」と言わない
- agent-browser の操作詳細は `agent-browser skills get core --full` を参照

## プロセス

### Step 1: ヒアリング（不足分のみ短く聞く）

ユーザーから以下を抽出。足りないもののみ聞く（既知のものは聞き直さない）:

- 商品名・型番・モデル年
- 用途・期待使用期間（→ 再販タイミングの試算に使う）
- 状態許容度（新品 / 美品 / 中古 / ジャンク可）
- 色・サイズ等の必須条件
- 予算上限・緊急性（5のつく日・日曜・お買い物マラソン待てるか）
- 既にある関連製品（互換アクセサリ等の同時購入機会）

### Step 2: ログイン状態の実機確認

調査開始前に、agent-browser で各ECのトップページを開いて snapshot でヘッダーUIを判定:

```bash
agent-browser --profile Default snapshot https://shopping.yahoo.co.jp
agent-browser --profile Default snapshot https://www.rakuten.co.jp
agent-browser --profile Default snapshot https://www.amazon.co.jp
agent-browser --profile Default snapshot https://www.yodobashi.com
agent-browser --profile Default snapshot https://www.biccamera.com
agent-browser --profile Default snapshot https://jp.mercari.com
agent-browser --profile Default snapshot https://paypayfleamarket.yahoo.co.jp
agent-browser --profile Default snapshot https://auctions.yahoo.co.jp
agent-browser --profile Default snapshot https://fril.jp
agent-browser --profile Default snapshot https://lohaco.yahoo.co.jp
```

判定基準:

| サイト | 未ログインのサイン | ログイン済みのサイン |
|--------|-----------------|--------------------|
| Yahoo!ショッピング | "ログイン"リンク | ユーザー名表示・"マイページ" |
| LOHACO | "ログイン"ボタン | アカウント名 |
| 楽天 | "会員登録/ログイン" | "ようこそ {名前} さん" |
| Amazon | "こんにちは, ログイン アカウント＆リスト" | "こんにちは, {名前}" |
| ヨドバシ | "ログイン"ボタン残存 | 名前表示 |
| ビックカメラ | 同上 | 同上 |
| メルカリ | "ログイン"リンク | アバター/通知ベル |
| Yahoo!フリマ | Yahoo IDログイン要求 | プロフィール画像 |
| ヤフオク | 同上 | 同上 |
| ラクマ | "ログイン" | アバター |

### Step 3: 未ログインサイトの通知（必須・推測で進めない）

ログインが必要なサイトが1つでもあれば、**リサーチ開始前に**ユーザーへ伝える:

```
以下のECサイトに未ログインです。実際のポイント還元率を確定するため
ログインをお願いします:

  □ Yahoo!ショッピング: https://login.yahoo.co.jp
  □ 楽天市場: https://login.rakuten.co.jp
  □ Amazon: https://www.amazon.co.jp/ap/signin
  □ ヨドバシ.com: https://order.yodobashi.com/yc/login/index.html
  □ ビックカメラ.com: https://www.biccamera.com/bc/member/CSfLogin.jsp
  □ メルカリ: https://jp.mercari.com/login
  □ Yahoo!フリマ: https://login.yahoo.co.jp
  □ ヤフオク: https://login.yahoo.co.jp
  □ ラクマ: https://fril.jp/login

ログイン後、Chrome を完全終了 してから「ログインした」と返してください。
（agent-browser が Default プロファイルを取得するために必要）
```

ユーザーから「ログインした」を受けたら、**Step 2 をもう一度実機で再確認**してから先へ進む。
（過去事例: ユーザーが「ログイン済み」と思っていても実際はセッション切れしていたケースがあった）

### Step 4: 並列リサーチ（3〜4 エージェントを同時投入）

ログイン確認後、同一メッセージで複数の Agent ツールを並列発火する。

#### Agent A: 中古・フリマ・オークション

対象サイトと検索URL:

- メルカリ出品中: `https://jp.mercari.com/search?keyword={q}&status=on_sale`
- メルカリSOLD: `https://jp.mercari.com/search?keyword={q}&status=sold_out`
- メルカリShops: `https://jp.mercari.com/search?keyword={q}&shop_type=shop`
- Yahoo!フリマ: `https://paypayfleamarket.yahoo.co.jp/search/PRODUCT?keyword={q}`
- ラクマ: `https://fril.jp/s?query={q}`
- ヤフオク 出品中: `https://auctions.yahoo.co.jp/search/search?p={q}&s1=new&o1=d`
- ヤフオク 落札相場: `https://auctions.yahoo.co.jp/closedsearch/closedsearch?p={q}`
- 2nd STREET ONLINE: `https://www.2ndstreet.jp/search?keyword={q}`
- ハードオフ オフモール: `https://netmall.hardoff.co.jp/cate/?keyword={q}`
- BookOff Online: `https://shopping.bookoff.co.jp/search/keyword/{q}`
- ジモティー（地域取引・送料節約）: `https://jmty.jp/all/sale-all?keyword={q}`
- Buyma（海外ブランド品）: `https://www.buyma.com/r/-F1/{q}/`

調査内容:

- 出品中の価格・状態・付属品・出品者評価・URL
- SOLD実績（中央値・レンジ・件数）でフェア価格を把握
- ヤフオクは即決価格と現在価格を分けて記録
- リコール対象モデルや偽造品の除外（型番・製造年・構造の目視確認）

#### Agent B: 新品EC（汎用・横断）

対象サイト:

- Yahoo!ショッピング（**ログイン済み**で還元率取得）: `https://shopping.yahoo.co.jp/search?p={q}`
- LOHACO: `https://lohaco.yahoo.co.jp/search?q={q}`
- 楽天市場（SPU・お買い物マラソン要確認）: `https://search.rakuten.co.jp/search/mall/{q}/`
- 楽天ブックス（書籍・CD/DVD/Blu-ray）: `https://books.rakuten.co.jp/search?sitem={q}`
- Amazon: `https://www.amazon.co.jp/s?k={q}`
- au PAY マーケット: `https://wowma.jp/itemlist?keyword={q}`
- Qoo10: `https://www.qoo10.jp/s/{q}`
- アイリスプラザ: `https://www.irisplaza.co.jp/search?keyword={q}`
- 価格.com（横断比較・最安履歴・価格推移グラフ）: `https://kakaku.com/search_results/{q}/`

各候補商品ページで取得:

- 価格・送料・お届け予定
- **ログイン済み状態でのポイント還元率の内訳**（base / LYPプレミアム / LINE / ボーナスストアPlus / 5のつく日 / 日曜+5% / GW・スーパーセール等の上乗せ）
- 期間限定ポイントの有無と失効日
- カラー・サイズ展開
- レビュー数・星評価（信頼度の参考）

#### Agent C: 家電量販店・カテゴリ専門店・公式

カテゴリ別に取捨選択:

- 家電: ヨドバシ.com、ビックカメラ.com、ジョーシンweb、ノジマオンライン、エディオンネットショップ、ケーズデンキオンラインショップ
- ベビー: ベビザらス、赤ちゃん本舗、DADWAY、blossom39、Combi/Pigeon/Aprica/CYBEX 公式
- ファッション: ZOZOTOWN、Magaseek、ロコンド、SHOPLIST
- インテリア: ニトリネット、IKEA、無印良品ネットストア、Re:CENO
- 食品/日用品: イオンネットスーパー、Pal System、サミットネットスーパー
- 書籍: 楽天ブックス、honto、紀伊國屋ウェブストア
- メーカー公式（商品カテゴリにより追加）

調査内容:

- 公式・実店舗発送の保証内容（メーカー保証 + 店舗独自保証）
- ポイント還元率（ヨドバシゴールド10%、ビックポイント10%等）
- 在庫・店頭引取の可否
- アウトレット・展示品の在庫

#### Agent D（任意）: 並行輸入・海外

国内流通が薄い場合のみ:

- US Amazon (`amazon.com`)
- eBay
- Buyma
- 海外メーカー直販

確認事項: 関税(8〜10%)・国際送料・PSE/PSC等の規格・保証範囲・電圧/プラグ形状

### Step 5: 安全性チェック

- **リコール対象**: CPSC（米）、消費者庁リコール情報、メーカー告知
- **偽造品リスク**: 並行輸入や極端な低価格品
- **規格適合**: PSE（電気）/ PSC（消費生活用製品）/ Sマーク / SG / PL
- **構造的安全要件**: ハーネス点数、ロック機構、年式毎の改良点
- **モデル年判別**: 古い世代がリコール対象になっているケース要注意（例: mamaRoo 1.0〜4.0 はCPSCリコール対象、5.0以降は対象外）

中古候補のうち判別不能なものは「除外」テーブルに移し、根拠を明記。価格に釣られた推薦をしない。

### Step 6: キャピタルロス試算

```
実質支払 = 価格 + 送料 - 還元ポイント
再販手取り = 売却価格 × (1 - 手数料率) - 売却時送料
  メルカリ手数料: 10%       送料: ¥1,500前後（梱包大型）
  Yahoo!フリマ手数料: 5%     送料: 同上
  ヤフオク手数料: 8.8〜10%（プレミアム会員8.8%）
  ラクマ手数料: 6%
キャピタルロス = 実質支払 - 再販手取り
年あたりロス = キャピタルロス ÷ 使用年数
```

中古→中古再販のループは値崩れが少ないことが多い（人気商品で年¥4,000〜¥7,000程度）。
新品買って再販するルートは初年度の減価が大きい（30〜50%）ので注意。

### Step 7: 出力（チャットのみ・ファイル保存禁止）

```markdown
## 結論
（一行サマリー：最強候補と次点を端的に）

## TOP3〜5候補
| 順位 | 価格 | 還元 | 実質 | プラットフォーム | 状態・付属品 | URL |
|---|---|---|---|---|---|---|

## 新品 vs 中古 比較
（必要なら）

## キャピタルロス試算
| ルート | 実質支払 | N年後手取り想定 | キャピタルロス | 年あたり |

## 判断フロー
\```
条件A？
  ├─ YES → 候補X
  └─ NO  → 条件B？
        ├─ YES → 候補Y
        └─ NO  → 候補Z
\```

## 価格交渉ガイド（中古の場合）
- 打診額: SOLD中央値ベース or 付属品欠品の減額幅
- 文例

## 注意事項
- リコール・偽造品・規格
- 在庫・タイミング・キャンペーン期限
```

## 価格交渉ガイド（中古品）

打診額の決め方:

- SOLD中央値以下が出品されていれば、その出品が「適正以下」なので即決寄り
- 付属品欠品（元箱・取説・純正部品・新生児インサート等）: 1〜2割引が妥当
- 出品から長期間動いていない / 出品者の評価が少ない: 強気の交渉余地
- 出品者評価高 / 即決OK明記 / 24h発送: 大幅値下げは期待しない

文例（メルカリ・Yahoo!フリマ共通）:

```
はじめまして。即購入を検討しています。{確認したい付属品}は揃って
いますでしょうか？ もし無い場合 ¥{中央値-付属品分} でいかがでしょ
うか？ 前向きに検討しています。
```

## agent-browser 使用時の注意

- `--profile Default` で Chrome のログイン済みプロファイルを共有する
  - ユーザーが Chrome を開いている場合は **「Chrome を完全終了してください」** と促す
- 個別商品ページが時々フッターのみを返す（特にメルカリ）→ リトライ or 検索結果サマリーで代替
- snapshot で構造取得 → 必要に応じて eval で詳細抽出
- 商品画像で安全機構（ハーネス・ロック等）を確認するときは screenshot を保存して目視確認
- 詳細リファレンス: `agent-browser skills get core --full`

## やらないこと

- WebFetch によるリサーチ（メモリの feedback で禁止済み）
- Desktop 等へのレポートファイル保存（チャット出力のみ）
- ログイン未確認のままの還元率の推測・断言
- リコール対象モデルの推薦（疑わしい場合は「除外」に明記）
- 推測でリコール対象外と判断（モデル年・型番・5点ハーネス等の構造を必ず画像で確認）
