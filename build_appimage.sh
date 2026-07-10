#!/bin/bash
# kiri AppImage ビルドスクリプト
# 使い方: bash build_appimage.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/build/linux/x64/release/bundle"
APPDIR="$SCRIPT_DIR/build/kiri.AppDir"

echo "=== kiri AppImage ビルダー ==="

# ── 1. Flutterビルド ───────────────────────
echo "[1/4] Flutter ビルド中..."
cd "$SCRIPT_DIR"
flutter build linux --release
echo "      完了"

# ── 2. AppDir 構成 ─────────────────────────
echo "[2/4] AppDir を構成中..."
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin"
mkdir -p "$APPDIR/usr/lib"
mkdir -p "$APPDIR/usr/share/applications"
mkdir -p "$APPDIR/usr/share/icons/hicolor/256x256/apps"

# バイナリと依存ライブラリをコピー
cp -r "$BUNDLE/." "$APPDIR/usr/bin/"

# ── 3. メタデータ作成 ──────────────────────
echo "[3/4] メタデータを作成中..."

# .desktop ファイル
cat > "$APPDIR/kiri.desktop" << EOF
[Desktop Entry]
Name=kiri
Comment=スクリーンショット＆マクロツール
Exec=kiri
Icon=kiri
Type=Application
Categories=Utility;
EOF
cp "$APPDIR/kiri.desktop" "$APPDIR/usr/share/applications/"

# アイコン（仮：存在しない場合はスキップ）
if [ -f "$SCRIPT_DIR/assets/icon.png" ]; then
  cp "$SCRIPT_DIR/assets/icon.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/kiri.png"
  cp "$SCRIPT_DIR/assets/icon.png" "$APPDIR/kiri.png"
else
  # アイコンがない場合はダミーを作成（ImageMagickがあれば）
  if command -v convert &> /dev/null; then
    convert -size 256x256 xc:#1C1C1C \
      -fill white -pointsize 120 -gravity center -annotate 0 "k" \
      "$APPDIR/kiri.png" 2>/dev/null || touch "$APPDIR/kiri.png"
    cp "$APPDIR/kiri.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/kiri.png"
  else
    touch "$APPDIR/kiri.png"
    cp "$APPDIR/kiri.png" "$APPDIR/usr/share/icons/hicolor/256x256/apps/kiri.png"
  fi
fi

# AppRun（起動スクリプト）
cat > "$APPDIR/AppRun" << 'EOF'
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
export LD_LIBRARY_PATH="$HERE/usr/bin/lib:$LD_LIBRARY_PATH"
exec "$HERE/usr/bin/kiri" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# ── 4. AppImage 生成 ───────────────────────
echo "[4/4] AppImage を生成中..."
cd "$SCRIPT_DIR/build"
ARCH=x86_64 appimagetool "$APPDIR" "$SCRIPT_DIR/kiri-x86_64.AppImage"

echo ""
echo "完了！ → $SCRIPT_DIR/kiri-x86_64.AppImage"
echo ""
echo "インストール方法（別PCでも同じ手順）:"
echo "  1. sudo apt install libkeybinder-3.0-dev"
echo "  2. chmod +x kiri-x86_64.AppImage"
echo "  3. ./kiri-x86_64.AppImage"
