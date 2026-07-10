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

// ─────────────────────────────────────────
//  連続撮影シーケンス（screenshot → wait → key を repeat 回）
// ─────────────────────────────────────────
Future<void> runCaptureSequence({
  required int repeat,
  required int waitMs,
  required String sendKey,
  required bool Function() isCancelled,
  VoidCallback? onHide,
  VoidCallback? onShow,
  void Function(int index, String? path)? onShot,
}) async {
  for (var i = 0; i < repeat; i++) {
    if (isCancelled()) return;

    final path = await takeScreenshot(onHide: onHide, onShow: onShow);
    onShot?.call(i + 1, path);

    if (isCancelled()) return;
    await Future.delayed(Duration(milliseconds: waitMs));

    if (isCancelled()) return;
    await Process.run('ydotool', ['key', sendKey]);
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

// 使用可能な送信キー（ページめくり用途を想定）
const _availableKeys = ['Left', 'Right', 'space', 'Page_Down', 'Page_Up'];

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
  int _waitMs = 300;
  String _sendKey = _availableKeys.first;

  bool _running = false;
  bool _cancelRequested = false;
  int _progress = 0;
  String? _lastShotPath;

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
      waitMs: _waitMs,
      sendKey: _sendKey,
      isCancelled: () => _cancelRequested,
      onHide: _hide,
      onShow: _show,
      onShot: (index, path) {
        if (!mounted) return;
        setState(() {
          _progress = index;
          if (path != null) _lastShotPath = path;
        });
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
            children: [
              Expanded(child: _PreviewArea(path: _lastShotPath)),
              const SizedBox(height: 16),
              if (_running)
                Text(
                  '$_progress / $_repeat 枚',
                  style: const TextStyle(color: Colors.white70),
                ),
              const SizedBox(height: 8),
              _NumberStepper(
                label: 'リピート回数',
                value: _repeat,
                min: 1,
                enabled: !_running,
                onChanged: (v) => setState(() => _repeat = v),
              ),
              const SizedBox(height: 8),
              _NumberStepper(
                label: '待機時間(ms)',
                value: _waitMs,
                min: 0,
                step: 50,
                enabled: !_running,
                onChanged: (v) => setState(() => _waitMs = v),
              ),
              const SizedBox(height: 8),
              _KeySelector(
                value: _sendKey,
                enabled: !_running,
                onChanged: (v) => setState(() => _sendKey = v),
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
//  画像プレビュー
// ─────────────────────────────────────────
class _PreviewArea extends StatelessWidget {
  final String? path;

  const _PreviewArea({required this.path});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2A),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3A3A3A)),
      ),
      clipBehavior: Clip.antiAlias,
      child: path == null
          ? const Center(
              child: Text(
                '画像プレビュー',
                style: TextStyle(color: Colors.white24),
              ),
            )
          : Image.file(File(path!), fit: BoxFit.contain),
    );
  }
}

// ─────────────────────────────────────────
//  数値ステッパー（入力欄＋上下矢印）
// ─────────────────────────────────────────
class _NumberStepper extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int step;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _NumberStepper({
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.step = 1,
    this.enabled = true,
  });

  void _set(int v) {
    if (v < min) v = min;
    onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: Colors.white54)),
          ),
          SizedBox(
            width: 80,
            child: TextField(
              key: ValueKey('$label-$value'),
              enabled: enabled,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(color: Colors.white70),
              controller: TextEditingController(text: '$value'),
              decoration: const InputDecoration(isDense: true),
              onSubmitted: (text) => _set(int.tryParse(text) ?? value),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                iconSize: 18,
                color: Colors.white54,
                onPressed: enabled ? () => _set(value + step) : null,
                icon: const Icon(Icons.arrow_drop_up),
              ),
              IconButton(
                iconSize: 18,
                color: Colors.white54,
                onPressed: enabled ? () => _set(value - step) : null,
                icon: const Icon(Icons.arrow_drop_down),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────
//  送信キー選択
// ─────────────────────────────────────────
class _KeySelector extends StatelessWidget {
  final String value;
  final bool enabled;
  final ValueChanged<String> onChanged;

  const _KeySelector({
    required this.value,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: Row(
        children: [
          const Expanded(
            child: Text('送信キー', style: TextStyle(color: Colors.white54)),
          ),
          DropdownButton<String>(
            value: value,
            dropdownColor: const Color(0xFF2A2A2A),
            style: const TextStyle(color: Colors.white70),
            onChanged: enabled
                ? (v) {
                    if (v != null) onChanged(v);
                  }
                : null,
            items: _availableKeys
                .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                .toList(),
          ),
        ],
      ),
    );
  }
}
