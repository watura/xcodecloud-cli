# AGENTS.md

AI コーディングエージェント向けのプロジェクト案内。

## プロジェクト概要

Xcode Cloud ビルド管理 TUI アプリケーション。Zig 0.15.2 + libvaxis で構築。
App Store Connect API を通じて CI プロダクト・ワークフロー・ビルド実行・アーティファクトをブラウズ・管理する。

## ビルド・実行・テスト

```bash
zig build run          # コンパイル & 実行
zig build test         # テスト実行
zig build              # コンパイルのみ (zig-cache/bin/xcodecloud-cli)
```

### 環境変数

| 変数名 | 説明 |
|--------|------|
| `APPSTORE_CONNECT_API_ISSUER_ID` | App Store Connect の Team ID |
| `APPSTORE_CONNECT_API_KEY_ID` | API Key ID |
| `APPSTORE_CONNECT_API_KEY` | Base64 エンコードされた `.p8` 秘密鍵 |

3 つとも未設定の場合、自動的にモックデータモードで動作する。

## アーキテクチャ

### ディレクトリ構成

```
src/
├── main.zig                       # エントリポイント（TTY チェック、アロケータ初期化）
├── app.zig                        # App 本体（状態マシン、イベント処理、描画）
├── api/
│   ├── client.zig                 # HTTP クライアント（requestJson、モック分岐、認証）
│   ├── types.zig                  # データ型・JSON パース・free 関数
│   └── endpoints.zig              # API エンドポイント URL ビルダー
├── auth/
│   ├── jwt.zig                    # JWT トークン生成（ES256）
│   └── pem.zig                    # PEM/DER デコード
├── views/
│   ├── products.zig               # Products テーブル
│   ├── workflows.zig              # Workflows テーブル
│   ├── build_runs.zig             # Build Runs テーブル
│   ├── build_run_detail.zig       # Detail サマリー + Actions テーブル
│   └── build_action_artifacts.zig # Artifacts テーブル
├── widgets/
│   ├── table.zig                  # カラムベーステーブルフォーマッタ
│   └── status_bar.zig             # キーボードヒント表示
└── util/
    └── timefmt.zig                # ISO8601 → ローカル時刻変換（C libc 使用）
```

### Screen 状態マシン

```
products → workflows → build_runs → build_run_detail → build_action_artifacts
```

- Enter で次の画面へ遷移、Esc/q で前の画面へ戻る
- 各遷移時: データクリア → API 読み込み → `rebuildRows()` → `screen` 更新

### データフロー

```
KeyPress → handleKeyPress()
  → API Client (real: requestJson + JWT / mock: ハードコード)
  → App フィールド更新 (products/workflows/build_runs/...)
  → rebuildRows() (ArenaAllocator で行データ生成)
  → draw() → vaxis で描画
```

## コーディング規約・パターン

### メモリ管理

**GPA（General Purpose Allocator）**: `main.zig` で生成し App と Client に渡す。デバッグモードでリーク検出。

**ArenaAllocator**: `rebuildRows()` でテーブル行の文字列を一括確保。次の `rebuildRows()` 呼び出し時に全解放。

**必須パターン**:
- `defer allocator.free(...)` — 成功時のクリーンアップ
- `errdefer allocator.free(...)` — エラー時のクリーンアップ
- `try allocator.dupe(u8, string)` — 文字列の所有権コピー
- `free*` 関数 — スライス内の各フィールドを個別に free してからスライス自体を free

```zig
pub fn freeProducts(allocator: Allocator, items: []CiProduct) void {
    for (items) |item| {
        allocator.free(item.id);
        allocator.free(item.name);
        allocator.free(item.bundle_id);
    }
    allocator.free(items);
}
```

### API クライアントパターン

- `credentials == null` ならモックデータを返す、そうでなければ `requestJson()` で実 API 呼び出し
- 全 HTTP 通信は `requestJson()` に集約（JWT 生成・ヘッダ付与・エラーハンドリング）
- モック関数は本物と同じシグネチャで `mock*` として定義

### View パターン

各画面の View ファイルは同じ構造に従う：

```zig
const columns = [_]table.Column{
    .{ .title = "Name", .width = 30 },
    .{ .title = "Status", .width = 10 },
};

pub fn header(allocator: Allocator) ![]u8 {
    return table.formatHeader(allocator, &columns);
}

pub fn row(allocator: Allocator, item: types.SomeType) ![]u8 {
    const cells = [_][]const u8{ item.name, item.status };
    return table.formatRow(allocator, &columns, &cells);
}
```

### JSON パース規約

- `std.json.parseFromSlice` に `.{ .ignore_unknown_fields = true }` を常に指定
- レスポンスの struct フィールドにはデフォルト値を設定（`= .{}`, `= null`）
- `defer parsed.deinit()` で JSON ツリーを解放
- `dupOrDefault(allocator, value, "fallback")` でオプショナルフィールドを安全にコピー

## 新しい画面を追加する手順

1. **型定義** — `src/api/types.zig` にデータ型・`parse*`・`free*` 関数を追加
2. **エンドポイント** — `src/api/endpoints.zig` に URL ビルダーを追加
3. **クライアント** — `src/api/client.zig` に `list*`/`get*` メソッドと `mock*` 関数を追加
4. **View** — `src/views/` に新ファイルを作成（Column 定義 + `header`/`row` 関数）
5. **Screen enum & App** — `src/app.zig` の `Screen` enum に追加し、`load*`・`clear*` メソッド、`rebuildRows` 分岐、ナビゲーション（`activateSelection`/`goBack`）、`breadcrumbLine`、`deinit` を実装
6. **import** — `src/app.zig` に View モジュールの import を追加

## 注意事項・制約

- **TTY 必須**: パイプ入出力では動作しない（`isatty` チェックで即終了）
- **libc 依存**: 時刻フォーマットに C の `localtime_r`/`strftime` を使用
- **Zig 0.15.2 固定**: `.tool-versions` と `build.zig.zon` で指定。他バージョンではコンパイル不可
- **テスト最小限**: imports テストと `parseArtifacts` テストのみ
- **macOS 前提**: `open` コマンドでアーティファクト URL を開く（Linux は `xdg-open` にフォールバック）
- **ポーリング**: workflows/build_runs 画面で 30 秒間隔の自動更新 + macOS 通知
