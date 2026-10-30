// ESP32 を BLE キーボードにして iPad にキーを送るファームウェア。
//
// PC(kiri) --USBシリアル--> ESP32 --BLE HID--> iPad
//
// 必要なもの:
//   - Arduino IDE（ボード: ESP32 Dev Module 等）
//   - ライブラリ: ESP32-NimBLE-Keyboard（wakwak-koba 版。BleKeyboard.h を提供）
//       Arduino core 2.x 系なら T-vK の ESP32-BLE-Keyboard でも同じコードで動く想定
//
// シリアル仕様（115200bps、1行1コマンド、改行終端）:
//   right / left     矢印キー（ページ送り）
//   esc              Escape キー
//   shot             Cmd+Shift+3（iPadのスクリーンショット）
//   release          全キーを離す
//   status           "connected" か "disconnected" を返す
// 各コマンドの完了後に "ok"、未接続なら "error: not connected"、
// 不明なコマンドなら "error: unknown" を1行で返す。

#include <BleKeyboard.h>
#include <NimBLEDevice.h>

BleKeyboard bleKeyboard("kiri-kbd", "kiri", 100);

const unsigned long KEY_HOLD_MS = 60;

void tap(uint8_t key) {
  bleKeyboard.press(key);
  delay(KEY_HOLD_MS);
  bleKeyboard.releaseAll();
}

void screenshot() {
  bleKeyboard.press(KEY_LEFT_GUI);
  bleKeyboard.press(KEY_LEFT_SHIFT);
  bleKeyboard.press('3');
  delay(KEY_HOLD_MS);
  bleKeyboard.releaseAll();
}

void handle(const String& cmd) {
  if (cmd == "status") {
    Serial.println(bleKeyboard.isConnected() ? "connected" : "disconnected");
    return;
  }
  if (cmd != "right" && cmd != "left" && cmd != "esc" && cmd != "shot" && cmd != "release") {
    Serial.println("error: unknown");
    return;
  }
  if (!bleKeyboard.isConnected()) {
    Serial.println("error: not connected");
    return;
  }
  if (cmd == "right") tap(KEY_RIGHT_ARROW);
  else if (cmd == "left") tap(KEY_LEFT_ARROW);
  else if (cmd == "esc") tap(KEY_ESC);
  else if (cmd == "shot") screenshot();
  else bleKeyboard.releaseAll();
  Serial.println("ok");
}

void setup() {
  Serial.begin(115200);
  bleKeyboard.begin();

  // ライブラリ既定のアドバタイズには名前が入らず、iPad の Bluetooth 一覧に出ない。
  // 名前を含めて再開する。
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->stop();
  adv->enableScanResponse(true);
  adv->setName("kiri-kbd");
  adv->start();
}

void loop() {
  static String line;
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n') {
      line.trim();
      if (line.length() > 0) handle(line);
      line = "";
    } else if (c != '\r') {
      line += c;
    }
  }
}
