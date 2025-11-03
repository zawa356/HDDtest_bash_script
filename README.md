# HDDtest_bash_script

# HDD/SAS Acceptance Test (hddtest.sh)

**バージョン:** v1.14  
**ライセンス:** 0BSD（Zero-Clause BSD / 無帰属・許諾自由・無保証）  
**対象OS:** Ubuntu系（22.04/24.04 を想定）  

---

## 🧭 概要

**注意このREADMEはChatGPTに書いてもらっています。
内容について一切の保証をしませんのでご注意ください。**

本リポジトリは、SATA/SAS ドライブの受け入れ検査（Burn-in / Acceptance Test）を **対話UI（whiptail）** で安全に実行・記録する Bash スクリプト **`hddtest.sh`** を提供します。  
主な目的は、**SMART Short → badblocks（破壊的）→ SMART Long** の流れを**複数台並列**で自動化し、**CSV/Markdown** で要約、**フルログ**を保存、**zip/tar.gz** に自動圧縮までを行うことです。

- OS/マウント中のディスクは自動除外（誤消去防止）
- **DRY RUN** でログ生成パスを事前検証
- **SMART（ATA/SCSI/SAS対応）** の前後取得と **差分レポート** 生成
- **badblocks を P=4 並列**（デフォルト／変更可）
- 出力は **/var/log/hddtest/YYYYMMDD_HHMM/** 配下に時刻ベースで整理
- **SMART-only**（診断のみ）や **テスト選択**（FULL/組合せ）にも対応
- **デモモード**（loop デバイスで安全にUI/ロジック確認）を搭載

> ⚠️ **注意（破壊的テスト）**  
> `badblocks -w` は対象ディスクの **データを完全に破壊** します。  
> 業務環境では、**対象ディスクの特定・マウント解除・抜き差しミス防止**に十分注意してください。

---

## ✨ 主な機能一覧

- **UIフロー**（80×24 付近で収まる最適化）
  - 起動 → ディスク選択 → モード選択 → テスト選択 → 実行前確認/詳細 → 実行 → 完了画面
  - 「Back」導線を完備（誤操作時の復帰が容易）
- **モード**
  - **Test mode（任意のテスト選択）**
  - **SMART report only（シーケンス0のみ）**
  - `--smart-only` で非UIでもSMART単体実行が可能
- **テスト選択（チェックリスト）**
  - `FULL_ALL`（0..5 すべて・破壊的含）
  - `SMART_PRE`（0） / `SMART_SHORT`（1） / `BADBLOCKS`（2） / `SMART_LONG`（3） / `SMART_POST`（4） / `SMART_DIFF`（5）
  - `SMART_DIFF` 選択時は自動で 0/4 を追加
- **SMART**（ATA/SAS/SCSI対応）
  - `smartctl -a/-H/-l error/-l selftest/-x` を収集
  - **SAS向け**の Error counter log から **uncorrected** を合算抽出
  - 0: 取得前 / 4: 取得後 / 5: 差分（CSV生成・ユニファイドdiff）
- **badblocks 実行**
  - 既定：`-w -p 2 -b 4096 -c 10240`（ユーザー指定）
  - 並列数 `P=4`（`--badblocks-parallel`で変更可）
  - ログ・不良セクタリストを個別保存
- **安全機構**
  - OSルート・マウント中ディスクの除外
  - 破壊的テスト時にダブル確認
  - **DRY RUN**：I/Oせず完全なログ雛形と成果物を生成
- **成果物**
  - CSV/Markdown の要約、テキストログ、差分、ファイル一覧、ハッシュ、環境情報
  - 成果物ディレクトリを **zip/tar.gz** で自動アーカイブ

---

## 🧩 テストのシーケンス

番号とフェーズの対応は以下のとおりです。

| Seq | フェーズ名       | 目的/内容                                               |
|----:|------------------|--------------------------------------------------------|
| 0   | SMART_PRE        | 事前のフル SMART スナップショット（基準値）            |
| 1   | SMART_SHORT      | ショート自己診断の実行と完了確認                       |
| 2   | BADBLOCKS        | 破壊的 write/read テスト（指定オプション・並列実行）   |
| 3   | SMART_LONG       | ロング自己診断の実行と完了確認                         |
| 4   | SMART_POST       | 事後のフル SMART スナップショット（比較対象）          |
| 5   | SMART_DIFF       | 0↔4 の差分（POH/Defects/Uncorrected/Temp/Overall）     |

> FULL_ALL を選ぶと 0..5 を一括実行します。  
> `SMART_DIFF` を単独選択した場合でも 0 と 4 が自動追加されます。

---

## 🔧 前提条件 / 依存パッケージ

- root 実行（必要に応じて sudo 再実行します）
- Ubuntu 22.04/24.04 相当で動作を想定
- 初回起動時に不足パッケージを自動インストール  
  - `smartmontools` `e2fsprogs` `util-linux` `ncurses-bin` `whiptail` `zip` `pciutils` `diffutils` `coreutils`

> ネットワーク未接続環境では、事前に上記パッケージを導入してください。

---

## 🚀 クイックスタート

```bash
# 1) 取得
git clone https://github.com/zawa356/HDDtest_bash_script.git
cd HDDtest_bash_script

# 2) 権限
chmod +x hddtest.sh

# 3) 構文チェック（任意）
bash -n ./hddtest.sh

# 4) 起動（UI）
sudo ./hddtest.sh
```

> まずは `--dry-run` で成果物の雛形とフローを確認すると安全です。  
> 破壊的テスト（badblocks）を含めない選択も可能です。

---

## 🖥️ UIフロー（概要）

1. **起動画面**：注意事項と出力ディレクトリの案内  
2. **ディスク選択**：OS/マウント済みは除外済み。対象のみ選択  
3. **モード選択**：  
   - **Test mode**（任意のテストを選ぶ）  
   - **SMART report only**（シーケンス 0 のみ）
4. **テスト選択（Test mode 時）**：FULL/個別/組合せ  
5. **確認画面**：`Run / Details / Back`  
6. **実行**：選択シーケンスに従い並列処理を含め自動実施  
7. **完了画面**：要点の出力パスと Badlist の有無を表示

> 画面サイズが小さい端末（TeraTerm 既定など）では、80×24 以上へ調整を推奨。UI は自動縮小します。
> 罫線は `NCURSES_NO_UTF8_ACS=1` で ASCII 代替を利用しています。

---

## 🛡️ DRY RUN / DEMO

- `--dry-run`：**I/Oなし**で全工程のログ雛形・要約・アーカイブまで出力  
- `--demo`：loop デバイスを2台作成し、UI/ロジックを安全に確認可能  
  - `--demo --dry-run` の組合せで最小リスクの通し確認ができます

```bash
# DRY RUN（破壊なし）
sudo ./hddtest.sh --dry-run

# DEMO（仮想ディスクで検証）
sudo ./hddtest.sh --demo
sudo ./hddtest.sh --demo --dry-run
```

---

## ⚙️ オプション / 既定値

- badblocks 並列数：`--badblocks-parallel <N>`（既定 **4**）
- badblocks オプション：**`-w -p 2 -b 4096 -c 10240`**（ユーザー既定）
  - 4KiB 対応、2パス上書き検査、チャンク 10240（I/O 効率）

> 高スループット NIC/HBA/バックプレーンでも、**I/O 帯域の奪い合い**に注意。  
> 並列数は**ディスク本数/ホスト性能**に合わせて調整してください。

---

## 📂 出力（成果物）構成

作業ごとに **`/var/log/hddtest/YYYYMMDD_HHMM/`** が作られます。

```
/var/log/hddtest/20251103_2210/
├─ 0_env.txt                      # 環境スナップショット（カーネル/PCI/lsblk等）
├─ 0_selected_disks.txt           # 選択ターゲット一覧
├─ 0_smart_pre_sdX.log            # 事前SMART（ディスク別）
├─ 1_smart_short_sdX.log          # SMART Short（ディスク別）
├─ 2_badblocks_sdX.log            # badblocks ログ（ディスク別）
├─ 2_badblocks_badlist_sdX.txt    # badblocks 不良セクタ一覧（空＝問題なし）
├─ 3_smart_long_sdX.log           # SMART Long（ディスク別）
├─ 4_smart_post_sdX.log           # 事後SMART（ディスク別）
├─ 5_smart_diff_sdX.txt           # 0↔4 の diff（ディスク別）
├─ 8_all_logs_concat.txt          # ログ総結合（テキスト解析向け）
├─ 9_summary_*.csv                # CSV要約（POH/Defects/Uncorr/Temp）
├─ 9_summary_*.md                 # Markdown要約（GitHub表示向け）
├─ 9_smart_diff_*.csv             # SMART 差分 CSV
├─ 9_filelist_lslR.txt            # 生成ファイル一覧（ls -laR）
├─ 9_filelist_paths.txt           # 相対パスリスト
├─ 9_sha256sums_root.txt          # 直下ファイルのハッシュ
├─ 9_sha256sums_all.txt           # 全ファイルのハッシュ
├─ 9_plan.txt                     # 実行計画（モード/選択/シーケンス）
├─ 9_trace.log                    # 実行トレース（INFO/WARN/FATAL）
├─ 9_hddtest_*.zip                # 成果物一式（zip）
└─ 9_hddtest_*.tar.gz             # 成果物一式（tar.gz）
```

> CSV/MD は ChatGPT や表計算、GitHub 上での共有に便利です。

---

## 🔎 SMART（SAS/SCSI への配慮）

Windows 環境では HBA/RAID 構成により**SAS SMART が見えない**ことが多々あります。  
本スクリプトは Linux 上で `smartctl -d auto/scsi` を駆使して情報取得し、**SAS 特有の Error counter log** から `uncorrected` を合算抽出して **CSV 要約**に反映します。

- 主要抽出項目：PowerOnHours, GrownDefects, UncorrectedErrors, Temperature, Overall
- 事前（0）と事後（4）を **`SMART_DIFF`（5）** で比較（CSV/ユニファイドdiff）
- `smartctl` 補助: `-H`, `-l error`, `-l selftest`, `-x` も収集

> LSI/Avago/Broadcom の RAID モードでは、**IT/HBA モード**や `-d megaraid,N` 等の個別指定が必要な場合があります。

---

## 🧪 使い方（シナリオ別）

### 1) DRY RUN で雛形と導線を確認

```bash
sudo ./hddtest.sh --dry-run
# → ログ雛形/CSV/MD/zip/tar.gz まで生成される（I/Oなし）
```

### 2) SMART だけ取得（診断）

```bash
sudo ./hddtest.sh --smart-only
# → 0 のみ（事前SMART）を収集
```

### 3) FULL（0..5 すべて）

```bash
sudo ./hddtest.sh
# UI で FULL_ALL を選択 → 破壊的テスト警告を承諾 → 実行
```

### 4) badblocks なしで健全性を概観

```bash
sudo ./hddtest.sh
# UI で SMART_PRE, SMART_SHORT, SMART_LONG, SMART_POST, SMART_DIFF を選択
```

### 5) 並列数やオプションを調整

```bash
sudo ./hddtest.sh --badblocks-parallel 2
# 例：I/O 帯域の都合で 2 並列に抑える
```

---

## ⏱️ 目安時間（経験則）

- SMART Short：1～3 分/台 程度  
- SMART Long：2～6 時間/台（HDD/容量/型番で大きく差）  
- badblocks（-w -p 2）：TB級 HDD では**かなり長時間**  
- 6TB HDD × 9台の Long は、HBA 帯域や同時数で前後。夜間～24h スパンが目安。

> 途中で UI は閉じても処理自体は継続しません（UI 主導です）。進捗は各ログで確認してください。

---

## 🧰 トラブルシューティング

- **DRY 表示が消えない/混在する**  
  - v1.14 で数値判定に統一（`dry_label()`）。`9_trace.log` を確認。
- **xargs の警告**  
  - `-0` と `-I` と `-P` の組合せで警告が出ないよう修正済み。
- **TeraTerm 既定サイズでUIがはみ出す**  
  - 80×24 以上に拡張を推奨。UI は自動縮小します。
- **SAS SMART の数値が欠落**  
  - HBA/RAID モードに依存。IT/HBA モードや `smartctl -d` の明示指定を検討。
- **badblocks がやたら遅い**  
  - 並列数/バッファ/CPU負荷/温度/電源/バックプレーンの帯域を確認。
- **成果物が見当たらない**  
  - `/var/log/hddtest/YYYYMMDD_HHMM/` を確認。`9_trace.log` で時刻を特定。

---

## 🧪 設計とテスト戦略（要点）

- **状態機械（DISK→MODE→TESTS→CONFIRM→RUN）** で UI を整理  
- **Back** をどの段階でも提供（人間のミスに強い）  
- `--demo` で **loop デバイス**を自動作成し、安全に I/O なしで UI/分岐を網羅  
- **DRY RUN** は **「成果物が空」** を避ける目的で、雛形出力を徹底  
- ログは **ディスク別・シーケンス別** に命名（ソート順 = シーケンス順）  
- `9_plan.txt` / `9_trace.log` / `9_filelist_*` / `9_sha256sums_*` で**再現性**と**検収容易性**を担保

---

## 🧪 既知の制約

- RAID コントローラ配下の論理ボリュームに対し、素の `smartctl` が到達できない場合があります  
  - コントローラ固有の `-d` パラメータやツール（storcli 等）が必要なケースも
- Linux カーネル/HBA ドライバの差で SMART/Long の完了検出に時間差が出ることがあります  
- 端末によって罫線表示が ASCII 代替になる場合があります（機能上の問題はありません）

---

## 🤝 コントリビュート

- Issue/Pull Request 歓迎です（再現手順・使用 HBA/ドライブ型番・ログ添付があると助かります）
- 機能提案例：
  - `smartctl -d megaraid,N` 自動判別の拡充
  - JSON/Prometheus 形式の出力
  - `fio` との併用モード
  - メール/Slack などの通知連携

---

## 🔐 リスクと安全のチェックリスト

- [ ] 対象ディスクの **型番/シリアル** を `lsblk`/UI で再確認した  
- [ ] OS/マウント中デバイスが**除外**されていることを確認した  
- [ ] 破壊的テスト（badblocks）で **誤消去** が起きない配線/差し間違いを排除した  
- [ ] 温度/ファン/電源系の**冷却と冗長**を確保した  
- [ ] 長時間運転に耐える **監視**（温度・SMART・電源）を用意した

---

## 📜 ライセンス

このリポジトリは **0BSD（Zero-Clause BSD）** です。  
帰属表示やソース提示などの義務はありません（**無帰属・許諾自由**）。  
もちろん、クレジット表記やリンクをいただけると嬉しいですが、**義務ではありません**。


---

## 🗃️ 変更履歴（抜粋）

- **v1.14**: DRY 表示の誤判定修正、UI/文言の整備、xargs 警告対応  
- **v1.13**: `if ...; then` 漏れ修正、詳細画面、SAS抽出の堅牢化、zip/tar.gz 追加  
- **v1.12**: SMART-only/Back 導線、DRY RUN 導入、差分の CSV 化  
- **v1.11**: テスト選択と FULL、ログ命名のシーケンス順最適化  
- **v1.10**: 初回公開（並列 badblocks、SMART 収集、CSV/MD 要約）

---

## 🙏 謝辞

このスクリプトは、ユーザーコミュニティからの**フィードバック**と**実運用での知見**をもとに磨かれました。  
「最初に DRY RUN でログ雛形を確認する」「SAS の uncorrected を正しく拾う」「UI を 80×24 に収める」など、実務ならではの改善が多数含まれています。  
ご意見・PR、お待ちしています。



---

## 📚 付録A: SMART 項目の簡易対訳と読み方

- **Power_On_Hours / number of hours powered up**: 通電時間。累積運転時間の指標で、Long 後の増分は自己診断に要した時間の参考になります。  
- **Elements in grown defect list / Grown Defect**（SAS）: 使用中に成長した不良のエントリ数。増加は媒体劣化の兆候。  
- **Uncorrected Error(s)**: 読み書きで訂正不能だった回数。ゼロ以外が継続する場合は要注意。  
- **Temperature**: 温度。Badblocks 中は上がりやすいためファン制御を見直す指標になります。  
- **SMART overall-health self-assessment**: 総合評価。`PASSED` でも個別項目が悪いケースはあり、CSV/ログで全体を確認してください。

---

## 📚 付録B: badblocks の動作とオプション選定理由

`badblocks -w` はパターン書き込み→読み戻しを複数回繰り返し、読み戻し不一致セクタを抽出します。  
このスクリプトでは「実装の単純性」「4KiB 物理セクタ最適化」「適度な転送サイズ」の観点から、

- `-w` 破壊的書き込みモード（完全消去）  
- `-p 2` 2 パス（所要時間と検出力の妥協点）  
- `-b 4096` 4KiB ブロック  
- `-c 10240` 1 回あたり 10240 ブロック（I/O 効率改善）  

を既定としました。RAID/HBA のキャッシュ有無で結果が揺れることもあるため、**単発検査より傾向観察**を重視します。

---

## 📚 付録C: SAS と ATA の SMART 表現差

SAS は ATA と出力形式が異なり、生の属性テーブルがないケースが一般的です。  
そのため **Error counter log** から `read/write` の統計を抽出し、「訂正不能（uncorrected）」と見なせる合算値を CSV に掲載しています。  
SAS ドライブの「Grown Defects」は媒質の再配置などが契機となり、**経時で増える**ことがあります。差分（0→4）での変化を確認してください。

---

## 📚 付録D: よくある質問（追加）

- **Q: Windows で CrystalDiskInfo に出ないのは？**  
  A: HBA/RAID の抽象化により ATA パススルーが通らないため。Linux + smartctl を推奨します。

- **Q: DRY RUN の成果物って本当に安全？**  
  A: すべて「コマンド呼び出しを記録するだけ」で、デバイスへは触れません。検収/運用準備向けです。

- **Q: 6TB × 9台の Long はどのくらい？**  
  A: モデルやヘッド速度に依存しますが、**数時間～十数時間/台**。同時数が多いほど帯域依存で伸びます。

- **Q: RAID モード配下のディスクは？**  
  A: `-d megaraid,N` や IT/HBA モードを検討。物理ディスク単位の SMART 表示ができる経路を確保してください。

- **Q: ログを外部に渡したい**  
  A: zip/tar.gz をそのまま共有できます。`9_summary_*.csv` と `9_plan.txt` を併せて渡すと理解が早いです。

---

## 📚 付録E: 解析のヒント

- `9_smart_diff_*.csv` の **POH 差分** はテスト所要時間の近似になります。  
- `Uncorrected` の増加は要注意。`badblocks_badlist` にセクタが出ていないか照合してください。  
- 温度が 50℃ 付近を常時超える構成は見直し推奨（ケースエアフロー/ファンカーブ）。

---

## 📚 付録F: 開発者向けメモ（内部構造）

- **状態機械**で UI を統制し、`Back` を常に提供  
- **並列 badblocks** は `xargs -0 -I{} -P N` で起動（警告抑止済み）  
- SAS の抽出は `Error counter log` から AWK で合算。将来は JSON 出力と構造化を計画  
- すべての成果物はシーケンス番号で**ソート可能性**を担保（`0_`→`5_`→`8_`→`9_`）  
- **再現性**確保のため、環境スナップショットとハッシュを常に同梱
