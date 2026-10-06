# AWS VPC Flow Logs (Parquet) Viewer Tools

AWSのS3上に出力・保存された **Apache Parquet形式のVPCフローログ** を解析し、人間が読みやすい形式に変換して画面表示およびファイル出力を行うツールセットです。

- **RHEL 9.8 / Linux環境**: `view_vpc_flow_logs.sh` (Bashシェルスクリプト、完全スタンドアロン同梱)
- **Windows 11環境**: `View-VpcFlowLogs.ps1` (PowerShellスクリプト)
- **クロスプラットフォーム (Python)**: `vpc_flow_logs_viewer.py` (Python CLIツール)

---

## 主な機能と特長

1. **ディレクトリ再帰スキャン対応**
   - 単一の `.parquet` ファイルの指定だけでなく、S3から同期した日付・アカウント単位のネストされたディレクトリ構造（例: `AWSLogs/<account_id>/vpcflowlogs/<region>/<year>/<month>/<day>/`）を指定した場合、配下のすべての `.parquet` ファイルを自動検出して一括処理します。

2. **人間が直感的に理解しやすいフォーマット変換**
   - **タイムスタンプ変換**: UNIXエポック秒（`start`, `end`）を日時に整形（`YYYY-MM-DD HH:MM:SS`）
   - **プロトコル名変換**: プロトコル番号（6, 17, 1など）をプロトコル名（TCP, UDP, ICMP, ICMPv6など）に変換
   - **データサイズ換算**: バイト数（`bytes`）を人間が読みやすい単位（`B`, `KB`, `MB`, `GB`）に換算
   - **TCPフラグ変換**: `tcp_flags` の数値をフラグ名（`SYN`, `ACK`, `SYN-ACK`, `RST` 等）に変換
   - **カラーハイライト**: ターミナル上で `ACCEPT` を緑、`REJECT` を赤で色分け表示

3. **外部依存不要・シェルスクリプト単体で動作する同梱実装 (RHEL 9.8)**
   - インターネット接続がない閉域網・エアギャップ環境のRHEL 9.8でも動作するよう、超高速Parquet解析エンジン（DuckDB Linux x86_64）が `view_vpc_flow_logs.sh` の内部にBase64/XZ圧縮形式で**自己解凍型ペイロードとして同梱実装**されています。
   - スクリプト単体を別のサーバーにコピーして実行するだけで、事前ライブラリのインストール不要で即座に動作します（初回実行時に `~/.cache/vpc_flow_logs/` に自動展開・キャッシュされます）。
   - 既存の `bin/duckdb` やシステムのDuckDBが存在する場合はそちらを最優先で使用します。

4. **多彩なフィルタリングと集計ダッシュボード (`--stats`)**
   - アクション指定（`ACCEPT` / `REJECT`）
   - プロトコル指定（`TCP`, `UDP`, `ICMP` など）
   - IPアドレス指定（送信元IP、宛先IP、または双方対象）
   - ポート番号指定（送信元ポート、宛先ポート、または双方対象）
   - 表示件数制限（`--limit N`）
   - ソート（時間、データ量、パケット数、IP）
   - **統計情報ダッシュボード**: 総フロー数、総パケット数、総転送量、ACCEPT/REJECT割合、Top 5 送信元IP（Top Talkers）、Top 5 宛先IP、Top 5 宛先ポート、プロトコル別内訳を表示

5. **多彩な出力形式**
   - `table` (見やすい罫線表形式)
   - `detail` (全フィールドを1件ずつ縦並びで確認する詳細カード形式)
   - `csv` (CSV形式)
   - `tsv` (TSV形式)
   - `json` (JSON形式)
   - `GridView` (Windows 11でGUIウィンドウを開き、GUI上で検索・並び替えを行う対話形式)

---

## ディレクトリ構成

```text
S3_Parquet_Tools_Agy/
├── bin/
│   ├── duckdb                     # Linux x86_64用スタンドアロン実行バイナリ
│   └── duckdb.exe                 # Windows x86_64用実行バイナリ
├── view_vpc_flow_logs.sh          # RHEL 9.8用シェルスクリプト (エンジン同梱型)
├── view_vpc_flow_logs.template.sh # シェルスクリプトテンプレート
├── build_standalone_script.py     # エンジンを同梱したシェルスクリプトを再ビルドするスクリプト
├── View-VpcFlowLogs.ps1           # Windows 11用PowerShellスクリプト
├── vpc_flow_logs_viewer.py        # クロスプラットフォームPython CLI
├── test_data/                     # テスト用Parquetファイル群 (単一ファイル、ディレクトリ階層、v2形式)
├── test_all.sh                    # RHEL/Linux用自動テストスイート (10テスト)
├── test_all.ps1                   # Windows 11用自動テストスイート (10テスト)
└── README.md                      # 本ドキュメント
```

---

## 1. RHEL 9.8 での使用方法 (シェルスクリプト)

### 基本的な実行方法

```bash
# 実行権限の付与
chmod +x view_vpc_flow_logs.sh

# 1. 単一のParquetファイルを指定して表示
./view_vpc_flow_logs.sh /path/to/log.parquet

# 2. ディレクトリを指定して配下のすべてのParquetファイルを一括表示
./view_vpc_flow_logs.sh /path/to/s3_flowlogs/

# 3. 画面に表示しつつファイルにも保存
./view_vpc_flow_logs.sh -o output_report.txt /path/to/s3_flowlogs/
```

### フィルタリングとオプション指定

```bash
# REJECTされた通信のみを抽出
./view_vpc_flow_logs.sh --action REJECT /path/to/s3_flowlogs/

# TCPプロトコルでポート443宛ての通信を表示
./view_vpc_flow_logs.sh --protocol TCP --dstport 443 /path/to/s3_flowlogs/

# 特定のIPアドレス（送信元または宛先）を含む通信を表示
./view_vpc_flow_logs.sh --ip 10.0.1.25 /path/to/s3_flowlogs/

# 転送量（bytes）の多い順に上位10件を表示
./view_vpc_flow_logs.sh --sort bytes --order DESC -l 10 /path/to/s3_flowlogs/

# CSV形式で出力
./view_vpc_flow_logs.sh -f csv -o flowlogs.csv /path/to/s3_flowlogs/

# 全カラム（カスタムログのvpc_idやサブネットID等）を表示
./view_vpc_flow_logs.sh --all-columns /path/to/s3_flowlogs/
```

### 統計情報ダッシュボードの表示 (`--stats`)

```bash
./view_vpc_flow_logs.sh --stats /path/to/s3_flowlogs/
```

**出力例:**
```text
================================================================================
 AWS VPC Flow Logs - Summary Statistics Dashboard
================================================================================
 Target Path      : ./test_data/s3
 Parquet Files    : 2 file(s)
 Time Range       : 2026-10-07 01:48:43 ~ 2026-10-07 02:43:53
 Total Flows      : 8
 Total Packets    : 548
 Total Bytes      : 265.13 KB (271,498 bytes)
 ACCEPT Flows     : 5 (62.5%)
 REJECT Flows     : 3 (37.5%)

--- Top 5 Source IPs (by Bytes) ---
┌───────────────┬───────┬─────────┬───────────────────┐
│   source_ip   │ flows │ packets │ bytes_transferred │
├───────────────┼───────┼─────────┼───────────────────┤
│ 10.0.1.50     │ 1     │ 500     │ 250.0 KB          │
│ 10.0.1.25     │ 3     │ 26      │ 8.69 KB           │
...
```

---

## 2. Windows 11 での使用方法 (PowerShell)

### 基本的な実行方法

```powershell
# 1. 単一のParquetファイルを指定して表示
powershell -ExecutionPolicy Bypass -File .\View-VpcFlowLogs.ps1 -Path .\test_data\single_sample.parquet

# 2. ディレクトリを指定して配下の全Parquetファイルを処理
powershell -ExecutionPolicy Bypass -File .\View-VpcFlowLogs.ps1 -Path .\test_data\s3

# 3. 画面表示とともにファイルに出力
powershell -ExecutionPolicy Bypass -File .\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -OutFile .\output.txt
```

### フィルタリングとオプション指定

```powershell
# REJECT通信のみ表示
.\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Action REJECT

# 送信元IPとポートで絞り込み
.\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -SrcAddr 10.0.1.25 -Port 53

# CSV形式で出力
.\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Format Csv -OutFile .\flows.csv

# GUIウィンドウ (Out-GridView) を開いてインタラクティブに検索・ソート
.\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Format GridView

# パイプライン連携 (-PassThru)
.\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -PassThru | Where-Object Action -eq 'REJECT' | Format-Table
```

### 統計情報ダッシュボードの表示 (`-Stats`)

```powershell
.\View-VpcFlowLogs.ps1 -Path .\test_data\s3 -Stats
```

---

## 3. オプション一覧

| シェルスクリプト (RHEL 9.8) | PowerShell (Windows 11) | 説明 |
| :--- | :--- | :--- |
| `<PATH>` (引数) | `-Path <string>` | 対象のParquetファイルまたはディレクトリパス |
| `-a, --action <ACTION>` | `-Action <ACCEPT\|REJECT\|ALL>` | アクションでフィルタ |
| `-p, --protocol <PROTO>` | `-Protocol <string>` | プロトコル名または番号でフィルタ |
| `-s, --src <IP>` | `-SrcAddr <string>` | 送信元IPでフィルタ |
| `-d, --dst <IP>` | `-DstAddr <string>` | 宛先IPでフィルタ |
| `-i, --ip <IP>` | `-IP <string>` | 送信元または宛先IPでフィルタ |
| `--srcport <PORT>` | `-SrcPort <int>` | 送信元ポートでフィルタ |
| `--dstport <PORT>` | `-DstPort <int>` | 宛先ポートでフィルタ |
| `--port <PORT>` | `-Port <int>` | 送信元または宛先ポートでフィルタ |
| `-l, --limit <N>` | `-Limit <int>` | 最大表示行数 |
| `--sort <FIELD>` | `-Sort <time\|bytes\|packets>` | ソート基準列 |
| `--order <ORDER>` | `-Order <ASC\|DESC>` | 昇順/降順 |
| `-f, --format <FORMAT>` | `-Format <Table\|Detail\|Csv\|Json\|GridView>` | 出力形式 |
| `-o, --output <FILE>` | `-OutFile <string>` | 結果をファイルに保存 |
| `--stats` | `-Stats` | 統計情報ダッシュボードを表示 |
| `--all-columns` | `-DetailedColumns` | Parquet内の全カラムを表示 |
| `--no-recurse` | `-NoRecurse` | サブディレクトリの再帰スキャンを行わない |

---

## 4. 自動テストの実行方法

各環境で動作確認を行うための包括的なテストスイートが同梱されています。

### RHEL 9.8 / Linux 環境

```bash
chmod +x test_all.sh test_standalone_bash.sh
./test_all.sh
```
- 単一ファイル、ディレクトリ再帰、v2最小スキーマ、各種フィルタ、統計、ファイル保存、**完全孤立環境（bin/ディレクトリなし・PATHなしでの自己解凍実行）**の全10項目を検証します。

### Windows 11 環境

```powershell
powershell -ExecutionPolicy Bypass -File .\test_all.ps1
```
- 単一ファイル、ディレクトリ再帰、v2最小スキーマ、各種フィルタ、統計、CSV/JSON/Listフォーマット、ファイル保存、Pythonエンジン連携の全10項目を検証します。
