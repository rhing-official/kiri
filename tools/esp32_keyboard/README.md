# ESP32 ファームウェアの書き込み手順（モバイルモード用）

kiri の「モバイル」モードは、ESP32 を BLE キーボードにして iPad にキーを送り、スクリーンショットとページ送りを行います。

```
PC (kiri) ──USB シリアル──▶ ESP32 ──Bluetooth(BLE)──▶ iPad
```

このフォルダの `esp32_keyboard.ino` を ESP32 に書き込むと、ESP32 が `kiri-kbd` という名前のキーボードになります。
書き込みとペアリングは、最初に1回だけ行えば済みます。

動作を確認した環境: Linux（Zorin OS）、`arduino-cli` 1.5.1、ボード定義 `esp32:esp32` 3.3.12、
`NimBLE-Arduino` 2.5.2、`ESP32-NimBLE-Keyboard`（コミット `1f3a88a`）、iPad（Freenove の ESP32 ボード、USB シリアルは CH340）。

## 用意するもの

- ESP32 開発ボード（**BLE に対応した ESP32**。ESP32-S2 は BLE 非対応のため使えません）
- データ通信ができる USB ケーブル
- Linux の PC と iPad

## 1. arduino-cli を入れる

[arduino-cli の Releases](https://github.com/arduino/arduino-cli/releases) から、`arduino-cli_<バージョン>_Linux_64bit.tar.gz` と
`<バージョン>-checksums.txt` を、**空のフォルダ**にダウンロードします（例: 1.5.1）。

```bash
mkdir ~/arduino-cli-dl && cd ~/arduino-cli-dl
# ダウンロードした2つのファイルをここに置いてから:
grep Linux_64bit.tar.gz *-checksums.txt | sha256sum -c -   # OK と出れば正しいファイル
mkdir ex && tar -xzf arduino-cli_*_Linux_64bit.tar.gz -C ex
mkdir -p ~/.local/bin && cp ex/arduino-cli ~/.local/bin/
export PATH="$HOME/.local/bin:$PATH"                       # 通っていなければ ~/.bashrc にも追記
arduino-cli version
```

`gh` コマンドが使える場合は、`gh release download --repo arduino/arduino-cli --pattern "arduino-cli_*_Linux_64bit.tar.gz" --pattern "*-checksums.txt"` でも取得できます。

## 2. ボード定義とライブラリを入れる

```bash
arduino-cli core update-index
arduino-cli core install esp32:esp32        # 数百 MB あります
arduino-cli lib install NimBLE-Arduino
```

BLE キーボードのライブラリ `ESP32-NimBLE-Keyboard` は、ライブラリ一覧に無いため GitHub から取得します。

```bash
LIBDIR="$(arduino-cli config get directories.user)/libraries"   # 通常は ~/Arduino/libraries
git clone https://github.com/wakwak-koba/ESP32-NimBLE-Keyboard "$LIBDIR/ESP32-NimBLE-Keyboard"
git -C "$LIBDIR/ESP32-NimBLE-Keyboard" checkout 1f3a88a
```

このライブラリのヘッダ `BleKeyboard.h` には `#include <functional>` が足りず、そのままだとコンパイルエラーになります。**一度だけ** 次を実行して追記します。

```bash
sed -i '0,/#include/s//#include <functional>\n#include/' "$LIBDIR/ESP32-NimBLE-Keyboard/src/BleKeyboard.h"
head -4 "$LIBDIR/ESP32-NimBLE-Keyboard/src/BleKeyboard.h"       # 3行目付近に #include <functional> が入っていれば成功
```

## 3. 書き込み

USB で ESP32 を PC につなぎ、ポートを確認します。

```bash
arduino-cli board list          # 例: /dev/ttyUSB0
```

ポートを開けない場合は、`dialout` グループに入っていません。次を実行して、**ログインし直して**ください。

```bash
sudo usermod -aG dialout "$USER"
```

kiri のフォルダで、コンパイルと書き込みを行います（`/dev/ttyUSB0` は自分のポートに置き換えます）。

```bash
cd /path/to/kiri
arduino-cli compile --fqbn esp32:esp32:esp32 tools/esp32_keyboard
arduino-cli upload -p /dev/ttyUSB0 --fqbn esp32:esp32:esp32 tools/esp32_keyboard
```

- コンパイルに失敗すると、`upload` は**前回のビルド**を書き込むだけです。コンパイルが通ってから書き込んでください。
- `Connecting...` のまま進まない場合は、ボードの `BOOT` ボタンを押しながら `upload` を実行してください。
- 最後に `Hash of data verified.` と出れば、書き込みは成功です。

## 4. iPad とペアリングする

1. iPad の `設定` → `Bluetooth` を開く（一覧が更新されない場合は、一度オフ、オンにする）。
2. **`その他のデバイス`** に出る `kiri-kbd` をタップして、ペアリングする。
3. 以降は、ESP32 に電源が入ると、自動で iPad に再接続されます。

## 5. kiri で撮影する

1. ESP32 をつないだ状態で kiri を起動し、モードを **モバイル** にする。
2. iPad で、撮影したい本アプリのページを開いておく。
3. リピート回数・開始までの秒数・撮影後の待機秒数・ページ送り（左／右）を設定して、開始を押す。

- **撮影後の待機秒数は 7 秒以上**にしてください。iPad はスクリーンショットの後、7 秒ほどキーを受け付けません（既定値は 8 秒）。
- 撮った画像は、PC ではなく **iPad の写真アプリ**に保存されます。
- シリアルポートが `/dev/ttyUSB0` 以外のときは、設定ファイル `~/.config/kiri/settings.json` の `serialPort` を書き換えます。

## 困ったとき

| 症状 | 対処 |
|---|---|
| iPad の Bluetooth 一覧に `kiri-kbd` が出ない | ボードの電源（USB）と、書き込みが成功しているかを確認する。iPad に古い `kiri-kbd` の登録が残っていれば、`このデバイスの登録を解除` してから、もう一度探す |
| kiri が「ESP32 が接続されていません」と表示する | iPad の Bluetooth がオンか、ペアリング済みかを確認する。ESP32 の USB を抜き差しして、数秒待つ |
| 「シリアルポートを開けません」と表示する | ポート名（`arduino-cli board list`）と、`dialout` グループへの所属を確認する |
| 撮影はできるが、ページがめくれない | 撮影後の待機秒数を 7 秒以上にする。本アプリが矢印キーでページをめくれるか、外付けキーボードで確かめる |
| コンパイルで `std::function` や `Callback` のエラーが出る | 手順 2 の `#include <functional>` の追記を行う |

## 命令の仕様（参考）

ESP32 は、115200bps のシリアルで、1行1コマンドを受け付けます。完了すると `ok` を返します。

| 命令 | 動作 |
|---|---|
| `right` / `left` | 矢印キー（ページ送り） |
| `shot` | Cmd+Shift+3（iPad のスクリーンショット） |
| `esc` | Esc キー |
| `release` | 全キーを離す |
| `status` | `connected` か `disconnected` を返す |

iPad に未接続のときは `error: not connected`、不明な命令は `error: unknown` を返します。
