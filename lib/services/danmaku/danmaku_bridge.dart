import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'danmaku_message.dart';

/// 本地弹幕桥：起一个仅本机可访问的 HTTP + WebSocket 服务，把弹幕广播给
/// OBS 浏览器源渲染成滚动弹幕。
///
/// - `GET /danmaku`：渲染页（透明背景滚动弹幕）
/// - `WS  /ws`：弹幕 JSON 推送（`DanmakuMessage.toJson`）
/// - `GET /health`：健康检查
class DanmakuBridge {
  DanmakuBridge._();

  static final DanmakuBridge instance = DanmakuBridge._();

  HttpServer? _server;
  final _sockets = <WebSocket>{};
  int _port = 0;

  bool get running => _server != null;

  int get port => _port;

  /// OBS 浏览器源要填的地址。
  String get overlayUrl => 'http://127.0.0.1:$_port/danmaku';

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _port = _server!.port;
    _server!.listen(_onRequest, onError: (Object _) {});
  }

  void _onRequest(HttpRequest req) {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && path == '/danmaku') {
        req.response.headers.contentType = ContentType.html;
        req.response.headers.set('Cache-Control', 'no-store');
        req.response.write(_overlayHtml);
        req.response.close();
        return;
      }
      if (req.method == 'GET' && path == '/health') {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"ok":true,"clients":${_sockets.length}}');
        req.response.close();
        return;
      }
      if (req.method == 'GET' && path == '/ws') {
        WebSocketTransformer.upgrade(req).then((ws) {
          _sockets.add(ws);
          ws.listen(
            (dynamic _) {},
            onDone: () {
              _sockets.remove(ws);
            },
            onError: (dynamic _) {
              _sockets.remove(ws);
            },
          );
        }).catchError((Object _) {});
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      req.response.write('not found');
      req.response.close();
    } catch (_) {
      try {
        req.response.statusCode = HttpStatus.internalServerError;
        req.response.close();
      } catch (_) {}
    }
  }

  /// 把一条弹幕广播给所有已连接的浏览器源。
  void publish(DanmakuMessage msg) {
    if (_sockets.isEmpty) return;
    final text = jsonEncode(msg.toJson());
    for (final ws in _sockets.toList()) {
      try {
        ws.add(text);
      } catch (_) {
        _sockets.remove(ws);
      }
    }
  }

  Future<void> stop() async {
    for (final ws in _sockets.toList()) {
      try {
        await ws.close();
      } catch (_) {}
    }
    _sockets.clear();
    final server = _server;
    _server = null;
    _port = 0;
    if (server != null) {
      try {
        await server.close(force: true);
      } catch (_) {}
    }
  }

  /// OBS 浏览器源页面：上半屏从右向左滚动弹幕，左下角保留最近若干条。
  ///
  /// 支持查询参数：`?size=28&speed=10`（字号 / 横滚秒数）。
  static const _overlayHtml = r'''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>kmxzs danmaku overlay</title>
<style>
  html, body { margin: 0; padding: 0; width: 100%; height: 100%;
    background: transparent; overflow: hidden; font-family: "Microsoft YaHei", sans-serif; }
  #stage { position: fixed; top: 0; left: 0; width: 100%; height: 62%;
    overflow: hidden; pointer-events: none; }
  .dm { position: absolute; left: 100%; white-space: nowrap;
    font-size: var(--size, 26px); font-weight: 700; color: #fff;
    -webkit-text-stroke: 1px rgba(0,0,0,.85);
    text-shadow: 0 2px 4px rgba(0,0,0,.9);
    will-change: transform; }
  .dm.gift { color: #ffd54a; }
  .dm.superChat { color: #ff9c9c; background: rgba(120,0,0,.45);
    border-radius: 8px; padding: 2px 10px; }
  .dm.enter { color: #8fd0ff; font-size: calc(var(--size, 26px) * .82); }
  .dm.system { color: #b0bec5; font-size: calc(var(--size, 26px) * .75); }
  #list { position: fixed; left: 16px; bottom: 16px; width: 40%;
    display: flex; flex-direction: column; gap: 4px; pointer-events: none; }
  .item { background: rgba(0,0,0,.5); color: #fff; border-radius: 6px;
    padding: 4px 10px; font-size: 15px; line-height: 1.35;
    overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
    animation: fadeOut 1s ease forwards; }
  .item.gift { color: #ffd54a; }
  .item.superChat { color: #ffb4b4; border: 1px solid #ff5f5f; }
  .item.enter { color: #9cd4ff; }
  @keyframes fadeOut { from { opacity: 1; } to { opacity: 0; } }
  @keyframes fly { from { transform: translateX(0); } to { transform: translateX(-110vw); } }
</style>
</head>
<body>
  <div id="stage"></div>
  <div id="list"></div>
<script>
  const params = new URLSearchParams(location.search);
  const size = Number(params.get('size') || 26);
  const speed = Number(params.get('speed') || 10);
  const LANES = 8;
  let laneIndex = 0;

  document.documentElement.style.setProperty('--size', size + 'px');

  function addDm(text, kind) {
    const stage = document.getElementById('stage');
    const el = document.createElement('div');
    el.className = 'dm' + (kind && kind !== 'chat' && kind !== 'unknown' ? ' ' + kind : '');
    el.textContent = text;
    const lane = laneIndex++ % LANES;
    const top = (stage.clientHeight / LANES) * lane + 2;
    el.style.top = top + 'px';
    stage.appendChild(el);
    const width = el.offsetWidth;
    const travel = stage.clientWidth + width + 40;
    el.animate(
      [
        { transform: 'translateX(0)' },
        { transform: 'translateX(-' + travel + 'px)' }
      ],
      { duration: speed * 1000, easing: 'linear', fill: 'forwards' }
    );
    setTimeout(() => el.remove(), speed * 1000 + 300);
  }

  function addItem(text, kind) {
    const list = document.getElementById('list');
    const el = document.createElement('div');
    el.className = 'item' + (kind && kind !== 'chat' && kind !== 'unknown' ? ' ' + kind : '');
    el.textContent = text;
    list.appendChild(el);
    while (list.children.length > 7) list.removeChild(list.firstChild);
    setTimeout(() => el.remove(), 6000);
  }

  function render(msg) {
    const kind = msg.kind || 'chat';
    let text = msg.content || '';
    if (msg.user) text = msg.user + '：' + text;
    if (kind === 'gift') text = msg.user + ' 送出 ' + (msg.giftName || '礼物') +
      (msg.giftCount && msg.giftCount > 1 ? ' ×' + msg.giftCount : '');
    if (kind === 'enter') text = msg.user + ' 进入直播间';
    if (kind === 'system') { addItem(text, kind); return; }
    addDm(text, kind);
    addItem(text, kind);
  }

  function connect() {
    const ws = new WebSocket('ws://' + location.host + '/ws');
    ws.onopen = () => render({ user: '', content: '弹幕已连接', kind: 'system' });
    ws.onmessage = (ev) => {
      try { render(JSON.parse(ev.data)); } catch (e) {}
    };
    ws.onclose = () => {
      render({ user: '', content: '弹幕连接断开，等待重连…', kind: 'system' });
      setTimeout(connect, 3000);
    };
  }
  connect();
</script>
</body>
</html>''';
}
