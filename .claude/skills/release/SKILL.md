---
name: release
description: kiriの新バージョンをGitHub Releaseとして公開する（AppImageをビルドし、タグ付きのReleaseにkiri-x86_64.AppImageを添付する）。ユーザーが「/release」「リリースして」等、明示的にリリースを求めたときだけ使う。
---

# /release

`main`へのpushでは配布物は更新されない。kiriの配布は、`bash build_appimage.sh`で作った`kiri-x86_64.AppImage`を`gh release create`でGitHub Release（`rhing-official/kiri`）に添付する手動運用で、CIは無い。`*.AppImage`は`.gitignore`済みでコミットしない。この操作は公開にあたるため、ユーザーが明示的に求めた時以外は実行しない。

## 1. 事前確認

```bash
git status --short
git fetch origin --tags
git rev-list --left-right --count origin/main...main
git branch --show-current
```

- 未コミットの変更がある、または`main`が`origin/main`にpush済みでない場合は、リリースせずその旨を報告して中断する（Releaseは`main`のHEADを対象にするため、未pushの内容は載らず意図とずれる）。
- 現在のブランチが`main`でない場合も中断して報告する。
- `flutter analyze`を実行し、エラーがあれば中断して報告する。

## 2. リリース内容の確認とバージョン決定

```bash
gh release list --limit 3
git describe --tags --abbrev=0
git log <最新タグ>..HEAD --oneline
git diff --stat <最新タグ>..HEAD
```

- 差分（`lib/`・`linux/`・`pubspec.yaml`・`build_appimage.sh`等のアプリに影響する変更）が無ければ「リリース済み」と報告して終了する（文書や日記だけの差分ではリリースしない）。
- バージョンは`vMAJOR.MINOR.PATCH`。機能追加・UI/挙動の変更はマイナーを上げる、不具合修正のみはパッチを上げる、破壊的変更はメジャーを上げる。決めたバージョンと理由、コミット一覧をユーザーに見せてから進める。ユーザーがバージョンを指定していればそれに従う。
- `pubspec.yaml`の`version`はリリースごとに更新されておらず（`1.0.0+1`のまま）、Releaseのタグが正。揃えるかはユーザーに任せ、勝手に変更しない。

## 3. ビルド

```bash
bash build_appimage.sh
```

- 完了すると`kiri-x86_64.AppImage`がリポジトリ直下に出来る。要`appimagetool`。
- CMakeキャッシュのパス不一致（`CMakeCache.txt directory is different`）で失敗した場合は、`build/`が古いパスのキャッシュを持っている。`flutter clean`（`build/`と`.dart_tool`のキャッシュのみ消える生成物）を実行して再ビルドする。それ以外の失敗は無理に解決せず報告して中断する。
- ビルド後のAppImageは起動確認していない旨を、最終報告で正直に伝える（ユーザーが実機確認したと言った場合のみ「確認済み」と書く）。

## 4. Release作成

```bash
gh release create vX.Y.Z kiri-x86_64.AppImage --target main --title "kiri vX.Y.Z" --notes '<リリースノート>'
```

リリースノートは過去のRelease（`gh release view <最新タグ> --json body --jq .body`）と同じ形式にする:

````markdown
## 変更点
- （ユーザーに見える変更を簡潔に。内部リファクタは書かない）

## インストール
AppImageLauncher (https://github.com/TheAssassin/AppImageLauncher) の導入をおすすめします。導入後は kiri-x86_64.AppImage をダブルクリックするだけでアプリ一覧に統合されます。

手動で実行する場合:
```
chmod +x kiri-x86_64.AppImage
./kiri-x86_64.AppImage
```
````

- 同名タグが既にある場合は上書きせず、報告して中断する。
- `gh release create`は新しいタグも作成する（`--target main`）。

## 5. 報告

- 作成したReleaseのURL、バージョン、含まれる変更を伝える。
- 手戻りが必要な場合（誤ったAppImageを上げた等）は、`gh release delete vX.Y.Z --cleanup-tag`で削除できるが、公開済みの物を消す操作なので、必ずユーザーに確認してから行う。
