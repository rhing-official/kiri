# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## プロジェクト概要

kiri は個人使用向けの Linux 専用スクリーンショットツール（Flutter/Dart）。マクロ（screenshot→wait→key の固定シーケンス）を使って連続スクショを撮る用途に特化。企画書は `企画書.md`（シンボリックリンク。実体は `/home/arata/アプリ開発/Obsidian-Rhing/kiri/企画書.md`）にあり、仕様変更時は必ずこれを参照・更新する。`lib/main.dart` は企画書v5に追従済み（JSON手書きマクロは廃止）。ユーザーがUIから設定できるのは**リピート回数のみ**（待機時間・送信キーはアプリ内に固定値として組み込み。画像プレビューも廃止）。

## コマンド

- 実行: `flutter run -d linux`
- ビルド: `flutter build linux --release`
- 静的解析: `flutter analyze`
- テスト: `flutter test`（`test/widget_test.dart` は空実装のプレースホルダ）
- AppImage生成: `bash build_appimage.sh`（`flutter build linux --release` → AppDir構成 → `appimagetool` でパッケージング。要 `appimagetool` コマンド）

## アーキテクチャ

- 単一ファイル構成（`lib/main.dart` のみ、ウィジェット分割なし）
- `windowManager`（`window_manager` パッケージ）でウィンドウの最小化・復元を制御し、撮影直前にkiri自身を隠す（`_hide`/`_show` → `takeScreenshot` の `onHide`/`onShow` コールバック）
- スクリーンショット取得は `gnome-screenshot -w -f <path>` を `Process.run` で呼び出す方式（`-w` はアクティブウィンドウ取得）。kiriを隠すとWMが自動で直前のウィンドウへフォーカスを戻すため、「hide→`-w`キャプチャ→show」の順で対象ウィンドウの自動選択を実現している
- キー送信は `ydotool key <key>` を使用。起動時に `main()` 内で `pgrep ydotoold` を確認し未起動なら自動起動する（`_ensureYdotoold()`）
- 連続撮影は `runCaptureSequence()` が担う固定ロジック（JSONインタプリタではない）：`repeat` 回、`screenshot → 固定待機(`_fixedWaitMs`) → 固定キー送信(`_fixedSendKey`)` を繰り返す。待機時間・送信キーはUIで変更不可の定数。`isCancelled` コールバックで停止ボタンからの中断に対応
- `_NumberStepper` はリピート回数入力用（`TextField.onChanged`で即時反映。`onSubmitted`だとEnter未押下時に値が反映されない不具合があったため修正済み）
- 保存先は `~/ピクチャ/スクリーンショット/`、ファイル名は `kiri-<連番>.png`（`_nextScreenshotPath()` がディレクトリを走査して次の連番を決定。他アプリの screenshot と混在可能）
- 依存パッケージは `path`（パス結合）と `window_manager` のみ
