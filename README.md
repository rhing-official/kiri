# kiri

マクロ(連続撮影シーケンス)を使って画面上のウィンドウを連写するための、個人使用向けLinux専用スクリーンショットツールです。

企画の詳細は Obsidian 側の企画書を参照してください（本リポジトリには含まれていません）。

## インストール

[Releases](../../releases/latest) から `kiri-x86_64.AppImage` をダウンロードしてください。

### 推奨: AppImageLauncher を使う

[AppImageLauncher](https://github.com/TheAssassin/AppImageLauncher) を一度導入しておくと、ダウンロードした AppImage をダブルクリックするだけでアプリ一覧に統合されます。

```bash
sudo apt install appimagelauncher
```

導入後は `kiri-x86_64.AppImage` をダブルクリックするだけでインストールが完了します。

### 手動で実行する場合

```bash
chmod +x kiri-x86_64.AppImage
./kiri-x86_64.AppImage
```

## 必要なコマンド

- `gnome-screenshot`（スクリーンショット取得）
- `ydotool` / `ydotoold`（キー送信。初回起動時にデーモンが自動起動します）

## 開発者向け

```bash
flutter run -d linux            # 実行
flutter build linux --release   # ビルド
bash build_appimage.sh          # AppImage生成（要 appimagetool）
```
