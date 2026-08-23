part of '../home_page.dart';

/// 弹幕控制器：拉流成功后按平台起弹幕客户端，本地桥广播给 OBS 浏览器源，
/// 面板展示最近弹幕与连接状态。
mixin _DanmakuController on _HomePageBase {
  DanmakuClient? _danmakuClient;
  StreamSubscription<DanmakuMessage>? _danmakuSub;
  String _danmakuStatus = '未连接';
  final List<DanmakuMessage> _recentDanmaku = [];

  static const int _maxRecentDanmaku = 200;

  Future<void> _loadDanmakuPrefs() async {
    final sp = await SharedPreferences.getInstance();
    _danmakuEnabled = sp.getBool(PrefsKeys.danmakuEnabled) ?? true;
  }

  /// 拉流成功后调用；平台暂不支持或开关关闭时静默跳过。
  Future<void> _startDanmaku(LivePlatform platform, String roomId) async {
    if (!_danmakuEnabled || roomId.isEmpty) return;
    if (_danmakuClient != null) return;
    if (!DanmakuClientFactory.supports(platform)) {
      if (mounted) setState(() => _danmakuStatus = '不支持');
      return;
    }
    if (mounted) setState(() => _danmakuStatus = '连接中…');
    try {
      await DanmakuBridge.instance.start();
      final client = DanmakuClientFactory.create(
        platform: platform,
        roomId: roomId,
      );
      _danmakuClient = client;
      _danmakuSub = client.messages.listen(_onDanmaku);
      await client.connect();
      if (!mounted) return;
      setState(() => _danmakuStatus = '已连接');
      _appendLog('弹幕已连接（${client.platformLabel} 房间 ${client.roomId}）');
      _appendLog(
        'OBS 浏览器源地址: ${DanmakuBridge.instance.overlayUrl}',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _danmakuStatus = '失败');
        _appendLog('弹幕连接失败: $e');
      }
      await _stopDanmaku(status: '失败');
    }
  }

  void _onDanmaku(DanmakuMessage msg) {
    if (mounted) {
      setState(() {
        _recentDanmaku.insert(0, msg);
        if (_recentDanmaku.length > _maxRecentDanmaku) {
          _recentDanmaku.removeLast();
        }
      });
    }
    // 系统提示不进 OBS 叠层，避免刷屏干扰画面
    if (msg.kind != DanmakuKind.system) {
      DanmakuBridge.instance.publish(msg);
    }
  }

  Future<void> _stopDanmaku({String status = '未连接'}) async {
    await _danmakuSub?.cancel();
    _danmakuSub = null;
    final client = _danmakuClient;
    _danmakuClient = null;
    if (client != null) {
      await client.dispose();
    }
    if (mounted) setState(() => _danmakuStatus = status);
  }

  Future<void> _openDanmakuPanel() async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final cs = Theme.of(ctx).colorScheme;
          return AlertDialog(
            title: const Text('弹幕面板'),
            content: SizedBox(
              width: 430,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('拉流时自动连接弹幕'),
                    subtitle: const Text('当前只支持 B 站，其它平台后续接入'),
                    value: _danmakuEnabled,
                    onChanged: (v) async {
                      setDialogState(() => _danmakuEnabled = v);
                      await _persist();
                      if (!v) await _stopDanmaku();
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '状态：$_danmakuStatus',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _danmakuStatus == '已连接'
                          ? const Color(0xFF15803D)
                          : cs.onSurfaceVariant,
                    ),
                  ),
                  if (DanmakuBridge.instance.running) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: SelectableText(
                                  DanmakuBridge.instance.overlayUrl,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontFamily: 'Consolas',
                                  ),
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                icon: const Icon(Icons.copy, size: 18),
                                tooltip: '复制地址',
                                onPressed: () {
                                  Clipboard.setData(
                                    ClipboardData(
                                      text: DanmakuBridge.instance.overlayUrl,
                                    ),
                                  );
                                  _toast('浏览器源地址已复制');
                                },
                              ),
                            ],
                          ),
                          const Text(
                            'OBS → 来源 → 添加 → 浏览器：粘贴上面地址，'
                            '宽 1920 高 1080，勾选「背景透明」。',
                            style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  const Text(
                    '最近弹幕',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    height: 190,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: _recentDanmaku.isEmpty
                        ? const Center(
                            child: Text(
                              '暂无弹幕',
                              style: TextStyle(color: Color(0xFF64748B)),
                            ),
                          )
                        : ListView.builder(
                            padding: const EdgeInsets.all(8),
                            itemCount: _recentDanmaku.length,
                            itemBuilder: (ctx, i) {
                              final m = _recentDanmaku[i];
                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  m.displayText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: _danmakuColor(m.kind),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Color _danmakuColor(DanmakuKind kind) {
    switch (kind) {
      case DanmakuKind.gift:
        return const Color(0xFFFFD54A);
      case DanmakuKind.superChat:
        return const Color(0xFFFF9C9C);
      case DanmakuKind.enter:
        return const Color(0xFF9CD4FF);
      case DanmakuKind.system:
        return const Color(0xFFB0BEC5);
      case DanmakuKind.chat:
      case DanmakuKind.unknown:
        return Colors.white;
    }
  }
}
