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
  runApp(const KiriApp());
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

// 固定シーケンス設定（書籍撮影を想定：撮影→待機→ページめくり）
const _fixedWaitMs = 300;
const _fixedSendKey = 'Left';

// ─────────────────────────────────────────
//  連続撮影シーケンス（screenshot → wait → key を repeat 回）
// ─────────────────────────────────────────
Future<void> runCaptureSequence({
  required int repeat,
  int startDelaySec = 0,
  required bool Function() isCancelled,
  VoidCallback? onHide,
  VoidCallback? onShow,
  void Function(int index)? onShot,
}) async {
  // 開始までの待機。kiriを隠して撮影対象を操作できるようにする
  // （停止ボタンで中断できるよう短い間隔で確認）
  if (startDelaySec > 0) {
    onHide?.call();
    final deadline = DateTime.now().add(Duration(seconds: startDelaySec));
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled()) {
        onShow?.call();
        return;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  for (var i = 0; i < repeat; i++) {
    if (isCancelled()) return;

    await takeScreenshot(onHide: onHide, onShow: onShow);
    onShot?.call(i + 1);

    if (isCancelled()) return;
    await Future.delayed(const Duration(milliseconds: _fixedWaitMs));

    if (isCancelled()) return;
    await Process.run('ydotool', ['key', _fixedSendKey]);
  }
}

// ─────────────────────────────────────────
//  App
// ─────────────────────────────────────────
class KiriApp extends StatelessWidget {
  const KiriApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'kiri',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2D2D2D),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const CaptureScreen(),
    );
  }
}

// ─────────────────────────────────────────
//  メイン画面（連続撮影）
// ─────────────────────────────────────────
class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  int _repeat = 100;
  int _startDelaySec = 3;

  bool _running = false;
  bool _cancelRequested = false;
  int _progress = 0;

  void _hide() => windowManager.minimize();

  void _show() async {
    await Future.delayed(const Duration(milliseconds: 200));
    windowManager.restore();
  }

  Future<void> _start() async {
    if (_running) return;
    setState(() {
      _running = true;
      _cancelRequested = false;
      _progress = 0;
    });

    await runCaptureSequence(
      repeat: _repeat,
      startDelaySec: _startDelaySec,
      isCancelled: () => _cancelRequested,
      onHide: _hide,
      onShow: _show,
      onShot: (index) {
        if (!mounted) return;
        setState(() => _progress = index);
      },
    );

    if (mounted) setState(() => _running = false);
  }

  void _stop() => setState(() => _cancelRequested = true);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1C1C1C),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_running)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(
                    '$_progress / $_repeat 枚',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              _NumberStepper(
                label: 'リピート回数',
                value: _repeat,
                min: 1,
                enabled: !_running,
                onChanged: (v) => setState(() => _repeat = v),
              ),
              const SizedBox(height: 8),
              _NumberStepper(
                label: '開始までの秒数',
                value: _startDelaySec,
                enabled: !_running,
                onChanged: (v) => setState(() => _startDelaySec = v),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _running ? _stop : _start,
                      icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                      label: Text(_running ? '停止' : '開始'),
                      style: FilledButton.styleFrom(
                        backgroundColor: _running
                            ? const Color(0xFF4A2A2A)
                            : const Color(0xFF2A4A2A),
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
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
