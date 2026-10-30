import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

// ─────────────────────────────────────────
//  エントリポイント
// ─────────────────────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await _ensureYdotoold();
  final settings = await Settings.load();
  runApp(KiriApp(settings: settings));
}

Future<void> _ensureYdotoold() async {
  final check = await Process.run('pgrep', ['ydotoold']);
  if (check.stdout.toString().trim().isEmpty) {
    await Process.start('ydotoold', []);
    await Future.delayed(const Duration(milliseconds: 500));
  }
}

// ─────────────────────────────────────────
//  保存先パス
// ─────────────────────────────────────────
Future<String> _screenshotDir() async {
  final home = Platform.environment['HOME'] ?? '/tmp';
  final dir = Directory(p.join(home, 'ピクチャ', 'スクリーンショット'));
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir.path;
}

final _kiriFileRegExp = RegExp(r'^kiri-(\d+)\.png$');

Future<String> _nextScreenshotPath(String dir) async {
  var maxIndex = 0;
  await for (final entity in Directory(dir).list()) {
    if (entity is! File) continue;
    final match = _kiriFileRegExp.firstMatch(p.basename(entity.path));
    if (match == null) continue;
    final n = int.parse(match.group(1)!);
    if (n > maxIndex) maxIndex = n;
  }
  return p.join(dir, 'kiri-${maxIndex + 1}.png');
}

// ─────────────────────────────────────────
//  スクリーンショット取得（ウィンドウ単位）
// ─────────────────────────────────────────
Future<String?> takeScreenshot({
  VoidCallback? onHide,
  VoidCallback? onShow,
}) async {
  final dir = await _screenshotDir();
  final path = await _nextScreenshotPath(dir);

  // kiriを隠すと、直前まで裏にあったウィンドウへフォーカスが自動的に移る。
  // その状態で -w(アクティブウィンドウ) を撮ることで対象ウィンドウの自動選択を実現する。
  onHide?.call();
  await Future.delayed(const Duration(milliseconds: 300));

  final result = await Process.run('gnome-screenshot', ['-w', '-f', path]);

  await Future.delayed(const Duration(milliseconds: 100));
  onShow?.call();

  return result.exitCode == 0 ? path : null;
}

// ─────────────────────────────────────────
//  設定（~/.config/kiri/settings.json に保存）
// ─────────────────────────────────────────
enum CaptureMode { pc, ipad }

enum TurnDirection { left, right }

enum AppLanguage { ja, en }

// ESP32 通信のエラー種別（表示文言は Strings 側で言語ごとに決める）
enum EspError { portOpen, notConnected, reply }

class EspException implements Exception {
  final EspError kind;
  final String detail;
  EspException(this.kind, [this.detail = '']);
  @override
  String toString() => 'EspException($kind, $detail)';
}

// 画面の文言（日本語 / English）。新規パッケージを使わない簡易ローカライズ
class Strings {
  final bool _en;
  const Strings(AppLanguage language) : _en = language == AppLanguage.en;

  String get modePc => _en ? 'Computer' : 'コンピューター';
  String get modeMobile => _en ? 'Mobile' : 'モバイル';
  String get repeat => _en ? 'Repeat count' : 'リピート回数';
  String get startDelay => _en ? 'Start delay (sec)' : '開始までの秒数';
  String get afterShotWait => _en ? 'Wait after shot (sec)' : '撮影後の待機秒数';
  String get afterShotNote => _en
      ? 'The device ignores page turns unless you wait 7+ seconds after a shot'
      : 'モバイル端末は撮影後 7 秒以上空けないとページ送りが効きません';
  String get turnLeft => _en ? 'Turn left' : '左送り';
  String get turnRight => _en ? 'Turn right' : '右送り';
  String get start => _en ? 'Start' : '開始';
  String get stop => _en ? 'Stop' : '停止';
  String progress(int done, int total) =>
      _en ? '$done / $total shots' : '$done / $total 枚';

  String error(Object e) {
    if (e is EspException) {
      switch (e.kind) {
        case EspError.portOpen:
          return _en
              ? 'Cannot open serial port: ${e.detail} (check the ESP32 connection)'
              : 'シリアルポートを開けません: ${e.detail}（ESP32 の接続を確認してください）';
        case EspError.notConnected:
          return _en
              ? 'ESP32 is not connected to the mobile device (check Bluetooth pairing on the device)'
              : 'ESP32 がモバイル端末に接続されていません（端末の Bluetooth とペアリングを確認）';
        case EspError.reply:
          return 'ESP32: ${e.detail}';
      }
    }
    if (e is TimeoutException) {
      return _en ? 'No response from the ESP32' : 'ESP32 から応答がありません';
    }
    return '$e';
  }
}

class Settings {
  // 設定ファイルが無い初回は、OS の言語が日本語なら日本語、それ以外は English
  AppLanguage language = Platform.localeName.startsWith('ja')
      ? AppLanguage.ja
      : AppLanguage.en;
  CaptureMode mode = CaptureMode.pc;
  int repeat = 100;
  int startDelaySec = 3;
  TurnDirection turnDirection = TurnDirection.left; // 日本の書籍は左送りで進む
  int afterShotWaitSec = 8; // iPadは撮影後7秒以上空けないとキーが効かない
  String serialPort = '/dev/ttyUSB0';

  static File _file() {
    final env = Platform.environment;
    final base =
        env['XDG_CONFIG_HOME'] ?? p.join(env['HOME'] ?? '/tmp', '.config');
    return File(p.join(base, 'kiri', 'settings.json'));
  }

  // ファイルが無い・壊れている場合は既定値で起動する
  static Future<Settings> load() async {
    final s = Settings();
    try {
      final json = jsonDecode(await _file().readAsString());
      if (json is! Map) return s;
      s.language =
          AppLanguage.values.asNameMap()[json['language']] ?? s.language;
      s.mode = CaptureMode.values.asNameMap()[json['mode']] ?? s.mode;
      s.turnDirection =
          TurnDirection.values.asNameMap()[json['turnDirection']] ??
          s.turnDirection;
      int? positive(String key, int min) {
        final v = json[key];
        return v is num && v >= min ? v.toInt() : null;
      }

      s.repeat = positive('repeat', 1) ?? s.repeat;
      s.startDelaySec = positive('startDelaySec', 0) ?? s.startDelaySec;
      s.afterShotWaitSec =
          positive('afterShotWaitSec', 0) ?? s.afterShotWaitSec;
      final port = json['serialPort'];
      if (port is String && port.isNotEmpty) s.serialPort = port;
    } catch (_) {}
    return s;
  }

  Future<void> save() async {
    try {
      final file = _file();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'language': language.name,
          'mode': mode.name,
          'repeat': repeat,
          'startDelaySec': startDelaySec,
          'turnDirection': turnDirection.name,
          'afterShotWaitSec': afterShotWaitSec,
          'serialPort': serialPort,
        }),
      );
    } catch (_) {}
  }
}

// 固定シーケンス設定（書籍撮影を想定：撮影→待機→ページめくり）
const _fixedWaitMs = 300;
const _ipadAfterTurnMs = 1000; // ページ送り後の描画待ち

// 100ms刻みで isCancelled を確認しながら待つ。最後まで待てたら true、中断されたら false
Future<bool> _sleepCancellable(
  Duration duration,
  bool Function() isCancelled,
) async {
  final deadline = DateTime.now().add(duration);
  while (DateTime.now().isBefore(deadline)) {
    if (isCancelled()) return false;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  return !isCancelled();
}

// ─────────────────────────────────────────
//  連続撮影シーケンス（screenshot → wait → key を repeat 回）
// ─────────────────────────────────────────
Future<void> runCaptureSequence({
  required int repeat,
  required String sendKey, // ydotool のキー名（'Left' / 'Right'）
  int startDelaySec = 0,
  required bool Function() isCancelled,
  VoidCallback? onHide,
  VoidCallback? onShow,
  void Function(int index)? onShot,
}) async {
  // 開始までの待機。kiriを隠して撮影対象を操作できるようにする
  if (startDelaySec > 0) {
    onHide?.call();
    if (!await _sleepCancellable(
      Duration(seconds: startDelaySec),
      isCancelled,
    )) {
      onShow?.call();
      return;
    }
  }

  for (var i = 0; i < repeat; i++) {
    if (isCancelled()) return;

    await takeScreenshot(onHide: onHide, onShow: onShow);
    onShot?.call(i + 1);

    if (isCancelled()) return;
    await Future.delayed(const Duration(milliseconds: _fixedWaitMs));

    if (isCancelled()) return;
    await Process.run('ydotool', ['key', sendKey]);
  }
}

// ─────────────────────────────────────────
//  ESP32（BLEキーボード）とのシリアル通信
//  命令: status / right / left / shot / release / esc（1行1コマンド）
//  返答: ok / error: ... / connected / disconnected（1行）
// ─────────────────────────────────────────
class EspSerial {
  final String port;
  EspSerial(this.port);

  RandomAccessFile? _out;
  StreamSubscription<List<int>>? _sub;
  final _lines = StreamController<String>.broadcast();
  var _buf = '';

  Future<void> open() async {
    if (_out != null) return;
    final r = await Process.run('stty', [
      '-F',
      port,
      '115200',
      'raw',
      '-echo',
      '-hupcl',
      'clocal',
      'cread',
    ]);
    if (r.exitCode != 0) {
      throw EspException(EspError.portOpen, port);
    }
    final file = File(port);
    _sub = file.openRead().listen(_onData, onError: (_) {});
    _out = file.openSync(mode: FileMode.writeOnly); // ttyはシーク不可なので append は使えない
  }

  void _onData(List<int> data) {
    _buf += utf8.decode(data, allowMalformed: true);
    var i = _buf.indexOf('\n');
    while (i >= 0) {
      final line = _buf.substring(0, i).trim();
      _buf = _buf.substring(i + 1);
      if (line.isNotEmpty) _lines.add(line);
      i = _buf.indexOf('\n');
    }
  }

  static bool _isReply(String l) =>
      l == 'ok' ||
      l == 'connected' ||
      l == 'disconnected' ||
      l.startsWith('error');

  // 命令を送り、返答の1行を返す。error 返答は例外、返答なしは TimeoutException
  Future<String> send(
    String cmd, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await open();
    final reply = _lines.stream.firstWhere(_isReply).timeout(timeout);
    try {
      _out!.writeStringSync('$cmd\n');
    } catch (_) {
      reply.ignore();
      rethrow;
    }
    final line = await reply;
    if (line.startsWith('error')) throw EspException(EspError.reply, line);
    return line;
  }

  // ポートを開くと ESP32 が再起動して iPad に再接続するため、connected になるまで待つ
  Future<void> ensureConnected(bool Function() isCancelled) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) return;
      try {
        final r = await send(
          'status',
          timeout: const Duration(milliseconds: 800),
        );
        if (r == 'connected') return;
      } on TimeoutException {
        // 起動直後は返答がないので再試行する
      }
      await Future.delayed(const Duration(milliseconds: 500));
    }
    throw EspException(EspError.notConnected);
  }

  // 読み取り待ちのストリームは cancel の完了を待つと戻らないので、待たずに閉じる
  void close() {
    _sub?.cancel();
    _out?.closeSync();
    _lines.close();
    _sub = null;
    _out = null;
  }
}

// ─────────────────────────────────────────
//  iPad 連続撮影（shot → 待機 → ページ送り を repeat 回）
//  撮影後は 7 秒以上空けないと iPad がキーを受け付けない（実機で確認）
// ─────────────────────────────────────────
Future<void> runIpadSequence({
  required EspSerial esp,
  required int repeat,
  required TurnDirection turn,
  required int afterShotWaitSec,
  int startDelaySec = 0,
  required bool Function() isCancelled,
  void Function(int index)? onShot,
}) async {
  await esp.ensureConnected(isCancelled);
  if (isCancelled()) return;

  if (!await _sleepCancellable(Duration(seconds: startDelaySec), isCancelled)) {
    return;
  }

  for (var i = 0; i < repeat; i++) {
    if (isCancelled()) return;

    await esp.send('shot');
    onShot?.call(i + 1);

    // 最後の1枚の後は、待機もページ送りも不要
    if (i == repeat - 1) return;
    if (!await _sleepCancellable(
      Duration(seconds: afterShotWaitSec),
      isCancelled,
    )) {
      return;
    }

    await esp.send(turn.name);
    if (!await _sleepCancellable(
      const Duration(milliseconds: _ipadAfterTurnMs),
      isCancelled,
    )) {
      return;
    }
  }
}

// ─────────────────────────────────────────
//  App
// ─────────────────────────────────────────
class KiriApp extends StatelessWidget {
  final Settings settings;
  const KiriApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'kiri',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        // 無彩色（グレースケール）の配色。既定の seed 配色は青緑がかるため使わない
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D2D2D),
          brightness: Brightness.dark,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        ),
        useMaterial3: true,
        // トグル（SegmentedButton）: 選択中は明るいグレーの面＋白文字、未選択は枠だけ
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? const Color(0xFF4A4A4A)
                  : Colors.transparent,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.disabled)
                  ? Colors.white24
                  : states.contains(WidgetState.selected)
                  ? Colors.white
                  : Colors.white54,
            ),
            overlayColor: WidgetStatePropertyAll(
              Colors.white.withValues(alpha: 0.08),
            ),
            side: const WidgetStatePropertyAll(
              BorderSide(color: Color(0xFF3A3A3A)),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ),
      ),
      home: CaptureScreen(settings: settings),
    );
  }
}

// ─────────────────────────────────────────
//  メイン画面（連続撮影）
// ─────────────────────────────────────────
class CaptureScreen extends StatefulWidget {
  final Settings settings;
  const CaptureScreen({super.key, required this.settings});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  late final Settings _s = widget.settings;
  EspSerial? _esp;

  bool _running = false;
  bool _cancelRequested = false;
  int _progress = 0;
  Object? _error;

  void _hide() => windowManager.minimize();

  void _show() async {
    await Future.delayed(const Duration(milliseconds: 200));
    windowManager.restore();
  }

  // 設定を変更して即保存する
  void _update(VoidCallback change) {
    setState(change);
    _s.save();
  }

  Future<void> _start() async {
    if (_running) return;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = 0;
      _error = null;
    });

    void onShot(int index) {
      if (!mounted) return;
      setState(() => _progress = index);
    }

    try {
      if (_s.mode == CaptureMode.ipad) {
        if (_esp?.port != _s.serialPort) {
          _esp?.close();
          _esp = EspSerial(_s.serialPort);
        }
        await runIpadSequence(
          esp: _esp!,
          repeat: _s.repeat,
          turn: _s.turnDirection,
          afterShotWaitSec: _s.afterShotWaitSec,
          startDelaySec: _s.startDelaySec,
          isCancelled: () => _cancelRequested,
          onShot: onShot,
        );
      } else {
        await runCaptureSequence(
          repeat: _s.repeat,
          sendKey: _s.turnDirection == TurnDirection.left ? 'Left' : 'Right',
          startDelaySec: _s.startDelaySec,
          isCancelled: () => _cancelRequested,
          onHide: _hide,
          onShow: _show,
          onShot: onShot,
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _stop() => setState(() => _cancelRequested = true);

  @override
  void dispose() {
    _esp?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ipad = _s.mode == CaptureMode.ipad;
    final t = Strings(_s.language);
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          // 「開始までの秒数」を画面の縦中央に固定する。上半分は下寄せ・下半分は上寄せで並べるので、
          // モード切替で iPad 用の項目が増えても、中央より上は動かず、下に追加される。
          // 狭い窓では各半分を縮小して収める（FittedBox）
          child: Column(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SegmentedButton<AppLanguage>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: AppLanguage.ja,
                              label: Text('日本語'),
                            ),
                            ButtonSegment(
                              value: AppLanguage.en,
                              label: Text('English'),
                            ),
                          ],
                          selected: {_s.language},
                          onSelectionChanged: (v) =>
                              _update(() => _s.language = v.first),
                        ),
                        const SizedBox(height: 16),
                        SegmentedButton<CaptureMode>(
                          segments: [
                            ButtonSegment(
                              value: CaptureMode.pc,
                              label: Text(t.modePc),
                            ),
                            ButtonSegment(
                              value: CaptureMode.ipad,
                              label: Text(t.modeMobile),
                            ),
                          ],
                          selected: {_s.mode},
                          onSelectionChanged: _running
                              ? null
                              : (v) => _update(() => _s.mode = v.first),
                        ),
                        const SizedBox(height: 16),
                        _NumberStepper(
                          label: t.repeat,
                          value: _s.repeat,
                          min: 1,
                          enabled: !_running,
                          onChanged: (v) => _update(() => _s.repeat = v),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ),
                  ),
                ),
              ),
              _NumberStepper(
                label: t.startDelay,
                value: _s.startDelaySec,
                enabled: !_running,
                onChanged: (v) => _update(() => _s.startDelaySec = v),
              ),
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (ipad) ...[
                          const SizedBox(height: 8),
                          _NumberStepper(
                            label: t.afterShotWait,
                            value: _s.afterShotWaitSec,
                            enabled: !_running,
                            onChanged: (v) =>
                                _update(() => _s.afterShotWaitSec = v),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              t.afterShotNote,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white38,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        // 矢印は送る向きに合わせて、左送りは文字の左、右送りは文字の右に置く。
                        // 選択中のチェックマークが矢印と入れ替わらないよう showSelectedIcon は切る
                        SegmentedButton<TurnDirection>(
                          showSelectedIcon: false,
                          segments: [
                            ButtonSegment(
                              value: TurnDirection.left,
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.arrow_back, size: 18),
                                  const SizedBox(width: 8),
                                  Text(t.turnLeft),
                                ],
                              ),
                            ),
                            ButtonSegment(
                              value: TurnDirection.right,
                              label: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(t.turnRight),
                                  const SizedBox(width: 8),
                                  const Icon(Icons.arrow_forward, size: 18),
                                ],
                              ),
                            ),
                          ],
                          selected: {_s.turnDirection},
                          onSelectionChanged: _running
                              ? null
                              : (v) =>
                                    _update(() => _s.turnDirection = v.first),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: 160,
                          height: 96,
                          child: FilledButton.icon(
                            onPressed: _running ? _stop : _start,
                            icon: Icon(
                              _running ? Icons.stop : Icons.play_arrow,
                            ),
                            label: Text(_running ? t.stop : t.start),
                            style: FilledButton.styleFrom(
                              backgroundColor: _running
                                  ? const Color(0xFF4A2A2A)
                                  : const Color(0xFF2A4A2A),
                              foregroundColor: Colors.white70,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                        if (_running)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              t.progress(_progress, _s.repeat),
                              style: const TextStyle(color: Colors.white70),
                            ),
                          ),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              t.error(_error!),
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Color(0xFFE57373)),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
//  数値ステッパー（入力欄＋上下矢印）
// ─────────────────────────────────────────
class _NumberStepper extends StatefulWidget {
  final String label;
  final int value;
  final int min;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _NumberStepper({
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.enabled = true,
  });

  @override
  State<_NumberStepper> createState() => _NumberStepperState();
}

class _NumberStepperState extends State<_NumberStepper> {
  late final _controller = TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(_NumberStepper oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ('${widget.value}' != _controller.text) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _set(int v) {
    if (v < widget.min) v = widget.min;
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: widget.enabled ? 1.0 : 0.4,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.label, style: const TextStyle(color: Colors.white54)),
          const SizedBox(width: 12),
          SizedBox(
            width: 80,
            child: TextField(
              enabled: widget.enabled,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(color: Colors.white70),
              controller: _controller,
              decoration: const InputDecoration(isDense: true),
              onChanged: (text) {
                final v = int.tryParse(text);
                if (v != null) _set(v);
              },
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                iconSize: 18,
                color: Colors.white54,
                onPressed: widget.enabled ? () => _set(widget.value + 1) : null,
                icon: const Icon(Icons.arrow_drop_up),
              ),
              IconButton(
                iconSize: 18,
                color: Colors.white54,
                onPressed: widget.enabled ? () => _set(widget.value - 1) : null,
                icon: const Icon(Icons.arrow_drop_down),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
