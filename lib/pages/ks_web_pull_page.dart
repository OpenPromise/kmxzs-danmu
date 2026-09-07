import 'dart:async';
import 'dart:convert';

import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:flutter/material.dart';
import 'package:kmxzs/pages/ks_web_login_page.dart';
import 'package:kmxzs/services/flv_extractor.dart';
import 'package:kmxzs/services/prefs_keys.dart';
import 'package:kmxzs/services/webview2_runtime.dart';
import 'package:kmxzs/services/win_hotkey.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 用独立于登录的 WebView2 会话打开快手房间页取流。
///
/// 登录与拉流共用同一份持久 WebView2 配置目录，确保 Cookie、设备身份
/// 和快手弹幕 token 属于同一会话。不改 UA、不额外打 livedetail。
///
/// 实测 `https://live.kuaishou.com/u/{rid}` 的数据结构：
/// `window.__INITIAL_STATE__.liveroom.playList` 是数组，
/// **只有 author.id == 房间号的那一项**才是当前直播；其余项是推荐位，
/// 也带 playUrls，整页扫描会拿到别人的流。
/// 当前项可能因验证暂时为空；通过后只在本页取流并关窗，不刷新。
class KsWebPullPage {
  KsWebPullPage._();

  static const _firstProbeDelay = Duration(seconds: 2);
  static const _probeInterval = Duration(milliseconds: 2500);
  static const _urlSettle = Duration(milliseconds: 1500);
  static const minPullInterval = Duration(seconds: 45);
  static const rateLimitCooldown = Duration(minutes: 5);

  static DateTime? _lastPullAt;
  static DateTime? _coolUntil;
  static bool _cooldownLoaded = false;

  static const _hookJs = r'''
(function () {
  if (window.__kmxzsHooked) return;
  window.__kmxzsHooked = true;
  window.__kmxzsByPrincipal = {};
  window.__kmxzsPerf = [];
  window.__kmxzsWsCapture = { url: '', enterPacket: '' };
  window.__kmxzsWsMeta = { url: '', token: '', liveStreamId: '' };
  function bytesToBase64(bytes) {
    var binary = '';
    for (var i = 0; i < bytes.length; i += 8192) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    }
    return btoa(binary);
  }
  function captureWsSend(url, data) {
    function keepPacket(bytes) {
      // SocketMessage.payloadType=CS_ENTER_ROOM(200) 的 varint 前缀。
      if (bytes && bytes.length > 3 && bytes[0] === 8 &&
          bytes[1] === 200 && bytes[2] === 1) {
        window.__kmxzsWsCapture.url = String(url || '');
        window.__kmxzsWsCapture.enterPacket = bytesToBase64(bytes);
      }
    }
    try {
      if (data instanceof ArrayBuffer) {
        keepPacket(new Uint8Array(data));
      } else if (ArrayBuffer.isView(data)) {
        keepPacket(new Uint8Array(data.buffer, data.byteOffset, data.byteLength));
      } else if (data instanceof Blob) {
        data.arrayBuffer().then(function (b) {
          keepPacket(new Uint8Array(b));
        }).catch(function () {});
      }
    } catch (e) {}
  }
  var OriginalWebSocket = window.WebSocket;
  if (typeof OriginalWebSocket === 'function') {
    var HookedWebSocket = function (url, protocols) {
      var ws = protocols === undefined
        ? new OriginalWebSocket(url)
        : new OriginalWebSocket(url, protocols);
      var rawSend = ws.send;
      ws.send = function (data) {
        captureWsSend(url, data);
        return rawSend.call(this, data);
      };
      return ws;
    };
    HookedWebSocket.prototype = OriginalWebSocket.prototype;
    Object.setPrototypeOf(HookedWebSocket, OriginalWebSocket);
    window.WebSocket = HookedWebSocket;
  }
  function keep(pid, u) {
    if (!u) return;
    var s = String(u);
    if (!/^https?:/i.test(s) || !/(\.flv|m3u8|pull-flv|pull-hls)/i.test(s)) return;
    var id = String(pid || '').toLowerCase();
    if (!id) {
      if (window.__kmxzsPerf.indexOf(s) < 0) window.__kmxzsPerf.push(s);
      return;
    }
    var arr = window.__kmxzsByPrincipal[id] || [];
    if (arr.indexOf(s) < 0) arr.push(s);
    window.__kmxzsByPrincipal[id] = arr;
  }
  function takeH264(ls, pid) {
    if (!ls || typeof ls !== 'object') return;
    keep(pid, ls.hlsPlayUrl);
    var play = ls.playUrls;
    var h264 = play && play.h264;
    var reps = h264 && h264.adaptationSet && h264.adaptationSet.representation;
    if (!Array.isArray(reps)) return;
    for (var i = 0; i < reps.length; i++) {
      var r = reps[i] || {};
      keep(pid, r.url);
      keep(pid, r.backupUrl);
    }
  }
  function scanWsMeta(value, depth) {
    if (!value || typeof value !== 'object' || depth > 7) return;
    try {
      var urls = value.webSocketUrls || value.websocketUrls || [];
      var url = value.url || (Array.isArray(urls) ? urls[0] : '');
      var token = value.token || '';
      if (url && token && /websocket|live.*ws/i.test(String(url))) {
        window.__kmxzsWsMeta.url = String(url);
        window.__kmxzsWsMeta.token = String(token);
      }
      if (value.liveStreamId) {
        window.__kmxzsWsMeta.liveStreamId = String(value.liveStreamId);
      }
      if (Array.isArray(value)) {
        for (var i = 0; i < Math.min(value.length, 50); i++) {
          scanWsMeta(value[i], depth + 1);
        }
      } else {
        var keys = Object.keys(value);
        for (var j = 0; j < Math.min(keys.length, 80); j++) {
          scanWsMeta(value[keys[j]], depth + 1);
        }
      }
    } catch (e) {}
  }
  function ingest(json) {
    if (!json || typeof json !== 'object') return;
    scanWsMeta(json, 0);
    var data = json.data || json;
    var detail = data.liveDetail || data;
    var ls = detail.liveStream || data.liveStream;
    var author = detail.author || data.author || {};
    var pid = author.id || author.principalId || (ls && ls.principalId) || '';
    if (ls && pid) takeH264(ls, pid);
  }
  var ofetch = window.fetch;
  if (typeof ofetch === 'function') {
    window.fetch = function () {
      return ofetch.apply(this, arguments).then(function (res) {
        try {
          var u = String(res.url || '');
          keep('', u);
          if (/graphql|livedetail|live_api/i.test(u)) {
            res.clone().json().then(ingest).catch(function () {});
          }
        } catch (e) {}
        return res;
      });
    };
  }
  var xo = XMLHttpRequest.prototype.open;
  var xs = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (m, u) {
    this.__kmxzsU = u;
    return xo.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    this.addEventListener('load', function () {
      try {
        keep('', this.responseURL || this.__kmxzsU);
        var t = this.responseText;
        if (t && t.length < 2000000 && (t.charAt(0) === '{' || t.charAt(0) === '[')) {
          ingest(JSON.parse(t));
        }
      } catch (e) {}
    });
    return xs.apply(this, arguments);
  };
})();
''';

  static String _probeJs(String rid) {
    final encoded = jsonEncode(rid);
    return '''
(function () {
  var rid = $encoded;
  function pushH264(ls, urls) {
    if (!ls || typeof ls !== 'object') return;
    var s = ls.hlsPlayUrl ? String(ls.hlsPlayUrl) : '';
    if (/^https?:/i.test(s) && /m3u8|pull-hls/i.test(s)) urls.push(s);
    var play = ls.playUrls;
    var h264 = play && play.h264;
    var reps = h264 && h264.adaptationSet && h264.adaptationSet.representation;
    if (!Array.isArray(reps)) return;
    for (var i = 0; i < reps.length; i++) {
      var r = reps[i] || {};
      var u = r.url ? String(r.url) : '';
      var b = r.backupUrl ? String(r.backupUrl) : '';
      if (/^https?:/i.test(u) && /(\\.flv|pull-flv)/i.test(u)) urls.push(u);
      if (/^https?:/i.test(b) && /(\\.flv|pull-flv)/i.test(b)) urls.push(b);
    }
  }
  function itemOf(raw) {
    var item = raw || {};
    var ls = item.liveStream || {};
    var author = item.author || {};
    var err = item.errorType || {};
    var urls = [];
    pushH264(ls, urls);
    var streamId = String(ls.liveStreamId || ls.id || item.liveStreamId || '');
    if (!streamId) {
      for (var u = 0; u < urls.length; u++) {
        var match = String(urls[u]).match(
          /[/]gifshow[/]([A-Za-z0-9_-]+?)_(?:Game|SD|HD|UHD|Origin)[A-Za-z0-9_-]*[.](?:flv|m3u8)/i
        );
        if (match) { streamId = match[1]; break; }
      }
    }
    return {
      principalId: String(author.id || author.principalId || ls.principalId || ''),
      liveStreamId: streamId,
      urls: urls,
      errorTitle: String(err.title || ''),
      isLiving: item.isLiving === true || ls.living === true
    };
  }
  var href = String(location.href || '');
  var state = {};
  try { state = window.__INITIAL_STATE__ || {}; } catch (e) {}
  var lr = state.liveroom || {};
  var list = Array.isArray(lr.playList) ? lr.playList : [];
  var items = [];
  for (var i = 0; i < list.length; i++) items.push(itemOf(list[i]));
  var hooked = [];
  try {
    var bag = window.__kmxzsByPrincipal || {};
    var hit = bag[String(rid).toLowerCase()] || [];
    for (var j = 0; j < hit.length; j++) hooked.push(hit[j]);
  } catch (e) {}
  var perf = [];
  try {
    var extra = window.__kmxzsPerf || [];
    for (var k = 0; k < extra.length; k++) perf.push(extra[k]);
    var entries = performance.getEntriesByType('resource');
    for (var n = 0; n < entries.length; n++) {
      var name = String(entries[n].name || '');
      if (/^https?:/i.test(name) && /(\\.flv|m3u8|pull-flv|pull-hls)/i.test(name)) perf.push(name);
    }
  } catch (e) {}
  function visibleBox(el) {
    if (!el) return false;
    var r = el.getBoundingClientRect();
    return r.width > 80 && r.height > 80;
  }
  var captcha = false;
  try {
    var iframes = document.querySelectorAll(
      'iframe[src*="captcha"], iframe[src*="verify"], iframe[src*="geetest"]'
    );
    for (var c = 0; c < iframes.length; c++) {
      if (visibleBox(iframes[c])) { captcha = true; break; }
    }
    if (!captcha) {
      var nodes = document.querySelectorAll('div, span, p, h1, h2, h3, button');
      var nmax = Math.min(nodes.length, 120);
      for (var t = 0; t < nmax; t++) {
        if (!visibleBox(nodes[t])) continue;
        var s = String(nodes[t].innerText || '').slice(0, 48);
        if (/请完成滑块|拖动滑块|请点击|依次点击|图形验证|请完成验证/.test(s)) {
          captcha = true;
          break;
        }
      }
    }
  } catch (e) {}
  var activeIndex = lr.activeIndex || 0;
  var active = items[activeIndex] || null;
  var principalId = active ? active.principalId : '';
  var liveStreamId = active ? active.liveStreamId : '';
  if (!liveStreamId && lr.liveStream) {
    liveStreamId = String(lr.liveStream.liveStreamId || lr.liveStream.id || '');
  }
  var wsInfo = null;
  try {
    var wi = lr.websocketInfo || {};
    var capture = window.__kmxzsWsCapture || {};
    var meta = window.__kmxzsWsMeta || {};
    var urls = wi.webSocketUrls || wi.websocketUrls || [];
    var wsUrl = String(capture.url || wi.url || (urls[0] || '') || meta.url || '');
    var packet = String(capture.enterPacket || '');
    var token = String(wi.token || meta.token || '');
    liveStreamId = String(wi.liveStreamId || liveStreamId || meta.liveStreamId || '');
    if (wsUrl && (packet || (token && liveStreamId))) {
      wsInfo = {
        url: wsUrl,
        token: token,
        liveStreamId: liveStreamId,
        enterPacket: packet
      };
    }
  } catch (e) {}
  return JSON.stringify({
    href: href,
    captcha: captcha,
    activeIndex: activeIndex,
    activeError: active ? active.errorTitle : '',
    principalId: principalId,
    liveStreamId: liveStreamId,
    wsInfo: wsInfo,
    items: items,
    hooked: hooked,
    perf: perf
  });
})()
''';
  }

  static String _webSocketInfoJs(String liveStreamId) {
    final encoded = jsonEncode(liveStreamId);
    return '''
(function () {
  var liveStreamId = $encoded;
  var state = window.__kmxzsWsInfoFetch;
  if (!state || state.liveStreamId !== liveStreamId) {
    state = {
      liveStreamId: liveStreamId,
      done: false,
      status: 0,
      url: '',
      token: '',
      error: '',
      diagnostic: ''
    };
    window.__kmxzsWsInfoFetch = state;
    function hasSession() {
      return !!state.url && !!state.token;
    }
    function scan(value, depth) {
      if (value == null || depth > 7) return;
      if (typeof value === 'string') {
        if (!state.url && /^wss?:/i.test(value)) state.url = value;
        return;
      }
      if (typeof value !== 'object') return;
      if (!state.token && typeof value.token === 'string') {
        state.token = value.token;
      }
      var candidates = [value.url, value.wsUrl];
      var lists = [value.websocketUrls, value.webSocketUrls, value.wsUrls];
      for (var i = 0; i < lists.length; i++) {
        if (Array.isArray(lists[i])) candidates = candidates.concat(lists[i]);
      }
      for (var j = 0; j < candidates.length; j++) {
        var candidate = candidates[j];
        if (candidate && typeof candidate === 'object') {
          candidate = candidate.url || candidate.wsUrl || '';
        }
        if (!state.url && /^wss?:/i.test(String(candidate || ''))) {
          state.url = String(candidate);
        }
      }
      var keys = Object.keys(value);
      for (var k = 0; k < Math.min(keys.length, 80); k++) {
        scan(value[keys[k]], depth + 1);
      }
    }
    function describe(json, label) {
      var root = json && typeof json === 'object' ? json : {};
      var data = root.data && typeof root.data === 'object' ? root.data : {};
      var code = root.result;
      if (code == null) code = root.code;
      if (code == null) code = data.result;
      if (code == null) code = data.code;
      var message = root.error_msg || root.errorMessage || root.message ||
        data.error_msg || data.errorMessage || data.message || '';
      state.diagnostic = label + ':code=' + String(code == null ? '-' : code) +
        ',keys=' + Object.keys(root).slice(0, 12).join('|') +
        ',data=' + Object.keys(data).slice(0, 12).join('|') +
        (message ? ',msg=' + String(message).slice(0, 60) : '');
    }
    function requestJson(url, options, label) {
      return fetch(url, options).then(function (response) {
        state.status = response.status;
        return response.json();
      }).then(function (json) {
        scan(json, 0);
        describe(json, label);
        return hasSession();
      }).catch(function (e) {
        state.diagnostic = label + ':error=' + String(e).slice(0, 80);
        return false;
      });
    }
    var endpoint = '/live_api/liveroom/websocketinfo?liveStreamId=' +
      encodeURIComponent(liveStreamId);
    var getOptions = {
      method: 'GET',
      credentials: 'include',
      headers: { 'Accept': 'application/json, text/plain, */*' }
    };
    requestJson(endpoint, getOptions, 'rest').then(function () {
      state.done = true;
    }).catch(function (e) {
      state.error = String(e);
      state.done = true;
    });
  }
  return JSON.stringify({
    done: state.done === true,
    status: Number(state.status || 0),
    url: String(state.url || ''),
    token: String(state.token || ''),
    error: String(state.error || ''),
    diagnostic: String(state.diagnostic || '')
  });
})()
''';
  }

  static Future<FlvExtractResult> open(
    BuildContext context,
    String input, {
    void Function(String msg)? log,
    void Function(
      String url,
      String token,
      String liveStreamId,
      List<int>? enterPacket,
    )? onDanmakuSession,
  }) async {
    void note(String m) => log?.call(m);

    final available = await WebviewWindow.isWebviewAvailable();
    if (!available) {
      if (context.mounted) {
        await WebView2Runtime.showMissingDialog(context);
      }
      return FlvExtractResult.fail(
        '本机未安装 WebView2 运行时。请先安装后再拉流。',
        platform: LivePlatform.kuaishou,
      );
    }

    final rid = _roomId(input);
    final pageUrl = input.trim().toLowerCase().startsWith('http')
        ? input.trim()
        : 'https://live.kuaishou.com/u/$rid';

    await _loadCooldown();
    final wait = cooldownWait(
      now: DateTime.now(),
      lastPullAt: _lastPullAt,
      coolUntil: _coolUntil,
    );
    if (wait != null) {
      final sec = wait.inSeconds.clamp(1, 3600);
      final msg = (_coolUntil != null && DateTime.now().isBefore(_coolUntil!))
          ? '刚才房间被风控，请 $sec 秒后再试，以免把拉流会话再次打分。'
          : '拉流间隔过短，请 $sec 秒后再试。';
      note(msg);
      return FlvExtractResult.fail(
        msg,
        platform: LivePlatform.kuaishou,
        roomId: rid,
      );
    }
    await _markPullAttempt();
    note('正在打开房间 $rid（使用已登录的快手会话）');

    final profile = await KsWebLoginPage.profilePath();
    late final Webview webview;
    try {
      webview = await WebviewWindow.create(
        configuration: CreateConfiguration(
          title: '快手直播间（滑块请拖完）',
          windowWidth: 1100,
          windowHeight: 780,
          titleBarHeight: 40,
          userDataFolderWindows: profile,
          openMaximized: true,
        ),
      );
    } catch (e) {
      return FlvExtractResult.fail(
        '无法打开快手浏览器窗口: $e',
        platform: LivePlatform.kuaishou,
        roomId: rid,
      );
    }

    final completer = Completer<FlvExtractResult>();
    var settled = false;
    BuildContext? tipCtx;
    var sliderHinted = false;
    var verifyPassedHinted = false;
    var roomOpenedHinted = false;
    var danmakuSessionSent = false;
    var wsInfoProbeCount = 0;
    DateTime? lastWsInfoFetchAt;
    DateTime? verifiedAt;
    DateTime? urlsSeenAt;
    DateTime? danmakuWaitStartedAt;
    final startedAt = DateTime.now();

    Future<void> raisePullWindow() async {
      try {
        await webview.setWebviewWindowVisibility(true);
        await webview.bringToForeground(maximized: true);
      } catch (e) {
        debugPrint('[ks-pull] bringToForeground: $e');
      }
      WinHotkey.raiseTopmostByTitle('快手直播间');
    }

    void dismissTip() {
      final c = tipCtx;
      if (c != null && c.mounted) {
        Navigator.of(c).pop();
      }
      tipCtx = null;
    }

    void finish(FlvExtractResult result, {bool rateLimited = false}) {
      if (settled) return;
      settled = true;
      dismissTip();
      try {
        webview.close();
      } catch (e) {
        debugPrint('[ks-pull] close: $e');
      }
      if (rateLimited) {
        unawaited(_markRateLimited());
      }
      if (!completer.isCompleted) completer.complete(result);
    }

    webview.onClose.whenComplete(() {
      finish(
        FlvExtractResult.fail(
          '已关闭快手直播间窗口，未取到拉流地址。',
          platform: LivePlatform.kuaishou,
          roomId: rid,
        ),
      );
    });

    try {
      webview.addScriptToExecuteOnDocumentCreated(_hookJs);
    } catch (e) {
      debugPrint('[ks-pull] hook: $e');
    }
    webview.launch(pageUrl, triggerOnUrlRequestEvent: false);

    if (context.mounted) {
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) {
          tipCtx = ctx;
          return AlertDialog(
            title: const Text('正在取流'),
            content: Text(
              '正在打开房间 $rid。出现验证时请在弹出窗口完成，'
              '通过后软件会自动取流并关闭窗口。',
            ),
            actions: [
              TextButton(
                onPressed: () => finish(
                  FlvExtractResult.fail(
                    '已取消快手浏览器取流。',
                    platform: LivePlatform.kuaishou,
                    roomId: rid,
                  ),
                ),
                child: const Text('取消'),
              ),
            ],
          );
        },
      ));
    }

    unawaited(() async {
      await Future.delayed(_firstProbeDelay);
      final probe = _probeJs(rid);
      while (!settled) {
        if (settled) return;
        try {
          final raw = await webview.evaluateJavaScript(probe);
          final parsed = _parseProbe(raw);
          if (parsed == null) {
            await Future.delayed(_probeInterval);
            continue;
          }
          if (!danmakuSessionSent && parsed.wsInfo != null) {
            final url = parsed.wsInfo!['url']?.toString() ?? '';
            final token = parsed.wsInfo!['token']?.toString() ?? '';
            final liveStreamId =
                parsed.wsInfo!['liveStreamId']?.toString() ?? '';
            final packetBase64 =
                parsed.wsInfo!['enterPacket']?.toString() ?? '';
            List<int>? enterPacket;
            if (packetBase64.isNotEmpty) {
              try {
                enterPacket = base64Decode(packetBase64);
              } catch (_) {}
            }
            if (url.isNotEmpty) {
              danmakuSessionSent = true;
              onDanmakuSession?.call(
                url,
                token,
                liveStreamId,
                enterPacket,
              );
            }
          }
          if (hrefIsTargetRoom(parsed.href, rid) && !roomOpenedHinted) {
            roomOpenedHinted = true;
            note('已进入房间页 ${parsed.href}');
          }
          final urls = pickCurrentRoomUrls(
            rid: rid,
            href: parsed.href,
            items: parsed.items,
            activeIndex: parsed.activeIndex,
            extraUrls: [...parsed.hooked, ...parsed.perf],
          );
          if (urls.isNotEmpty) {
            urlsSeenAt ??= DateTime.now();
            if (DateTime.now().difference(urlsSeenAt!) >= _urlSettle) {
              final packed = FlvExtractor().packPlayUrls(
                platform: LivePlatform.kuaishou,
                roomId: rid,
                urls: urls,
                note: '来源: WebView playList 当前房间',
              );
              if (packed.ok) {
                if (onDanmakuSession != null && !danmakuSessionSent) {
                  danmakuWaitStartedAt ??= DateTime.now();
                  var liveStreamId = parsed.liveStreamId;
                  if (liveStreamId.isEmpty) {
                    for (final url in packed.allUrls) {
                      liveStreamId = liveStreamIdFromUrl(url);
                      if (liveStreamId.isNotEmpty) break;
                    }
                  }
                  final now = DateTime.now();
                  final waitedForNative = now.difference(danmakuWaitStartedAt!);
                  if (wsInfoProbeCount == 0 &&
                      waitedForNative < const Duration(seconds: 8)) {
                    if (waitedForNative < _probeInterval) {
                      note('直播地址已就绪，正在等待快手网页建立弹幕会话');
                    }
                    await Future.delayed(_probeInterval);
                    continue;
                  }
                  final canFetchWsInfo = liveStreamId.isNotEmpty &&
                      wsInfoProbeCount < 4 &&
                      (lastWsInfoFetchAt == null ||
                          now.difference(lastWsInfoFetchAt!) >=
                              const Duration(seconds: 2));
                  if (canFetchWsInfo) {
                    wsInfoProbeCount++;
                    lastWsInfoFetchAt = now;
                    if (wsInfoProbeCount == 1) {
                      note('网页未主动连接弹幕，正在进行一次登录会话兜底请求（直播流 $liveStreamId）');
                    }
                    try {
                      final rawWsInfo = await webview
                          .evaluateJavaScript(
                            _webSocketInfoJs(liveStreamId),
                          )
                          .timeout(const Duration(seconds: 8));
                      final fetched = parseWebSocketInfoProbe(rawWsInfo);
                      if (fetched != null &&
                          fetched.url.isNotEmpty &&
                          fetched.token.isNotEmpty) {
                        danmakuSessionSent = true;
                        note('已获取快手弹幕会话');
                        onDanmakuSession(
                          fetched.url,
                          fetched.token,
                          liveStreamId,
                          null,
                        );
                      } else if (fetched?.done == true) {
                        wsInfoProbeCount = 4;
                        final status = fetched?.status ?? 0;
                        var detail = fetched?.diagnostic.trim() ?? '';
                        detail = detail.replaceAll(RegExp(r'[\r\n]+'), ' ');
                        if (detail.length > 160) {
                          detail = detail.substring(0, 160);
                        }
                        if (detail.contains('code=400010')) {
                          unawaited(_markRateLimited());
                        }
                        final suffix = detail.isEmpty ? '' : '，$detail';
                        note(
                          status > 0
                              ? '快手弹幕连接信息请求失败（HTTP $status$suffix）'
                              : '快手弹幕连接信息请求未返回有效会话$suffix',
                        );
                      }
                    } catch (e) {
                      debugPrint('[ks-pull] websocketinfo: $e');
                      if (wsInfoProbeCount >= 4) {
                        note('快手弹幕连接信息请求超时');
                      }
                    }
                  }
                  if (danmakuSessionSent) {
                    note(
                      '浏览器取流成功，房间 $rid，当前场 ${packed.allUrls.length} 条',
                    );
                    finish(packed);
                    return;
                  }
                  if (DateTime.now().difference(danmakuWaitStartedAt!) <
                      const Duration(seconds: 20)) {
                    await Future.delayed(_probeInterval);
                    continue;
                  }
                  note('未捕获到快手弹幕会话，继续拉流但弹幕将不可用');
                }
                note(
                  '浏览器取流成功，房间 $rid，当前场 ${packed.allUrls.length} 条',
                );
                finish(packed);
                return;
              }
            }
            await Future.delayed(_probeInterval);
            continue;
          }
          urlsSeenAt = null;
          final needSlide = parsed.captcha ||
              parsed.activeError.contains('滑块') ||
              parsed.activeError.contains('完成验证') ||
              parsed.activeError.contains('图形');
          final rateLimited = parsed.activeError.contains('请求过快') ||
              parsed.activeError.contains('稍后重试');
          if (needSlide) {
            if (!sliderHinted) {
              sliderHinted = true;
              note('出现验证，已把窗口置顶。完成后会自动取流并关窗');
              await raisePullWindow();
            }
            await Future.delayed(_probeInterval);
            continue;
          }
          if (sliderHinted && !verifyPassedHinted) {
            verifyPassedHinted = true;
            verifiedAt = DateTime.now();
            note('验证已通过，正在取流');
          }
          if (verifyPassedHinted &&
              verifiedAt != null &&
              DateTime.now().difference(verifiedAt!) >=
                  const Duration(seconds: 12)) {
            finish(
              FlvExtractResult.fail(
                rateLimited
                    ? '验证已过，但房间 $rid 仍被风控，没有当前场地址。请等普通浏览器能直接出画面后再试。'
                    : '验证已过，但未拿到房间 $rid 的拉流地址。',
                platform: LivePlatform.kuaishou,
                roomId: rid,
              ),
              rateLimited: rateLimited,
            );
            return;
          }
          if (!sliderHinted &&
              DateTime.now().difference(startedAt) >=
                  const Duration(seconds: 20) &&
              rateLimited) {
            finish(
              FlvExtractResult.fail(
                '房间 $rid 当前被风控（请求过快），没有可取的直播地址。',
                platform: LivePlatform.kuaishou,
                roomId: rid,
              ),
              rateLimited: true,
            );
            return;
          }
          if (!sliderHinted &&
              DateTime.now().difference(startedAt) >=
                  const Duration(seconds: 90)) {
            finish(
              FlvExtractResult.fail(
                '浏览器 90 秒内未拿到房间 $rid 的拉流地址。请确认主播正在直播。',
                platform: LivePlatform.kuaishou,
                roomId: rid,
              ),
            );
            return;
          }
        } catch (e) {
          debugPrint('[ks-pull] probe: $e');
        }
        if (!settled) await Future.delayed(_probeInterval);
      }
    }());

    return completer.future;
  }

  @visibleForTesting
  static void resetPullPacingForTest() {
    _lastPullAt = null;
    _coolUntil = null;
    _cooldownLoaded = true;
  }

  /// 距下次允许拉流的剩余时间；null 表示可以立刻开始。
  @visibleForTesting
  static Duration? cooldownWait({
    required DateTime now,
    DateTime? lastPullAt,
    DateTime? coolUntil,
    Duration minInterval = minPullInterval,
  }) {
    if (coolUntil != null && now.isBefore(coolUntil)) {
      return coolUntil.difference(now);
    }
    if (lastPullAt != null) {
      final elapsed = now.difference(lastPullAt);
      if (elapsed < minInterval) return minInterval - elapsed;
    }
    return null;
  }

  static Future<void> _loadCooldown() async {
    if (_cooldownLoaded) return;
    _cooldownLoaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final last = sp.getInt(PrefsKeys.ksPullLastMs);
      final cool = sp.getInt(PrefsKeys.ksPullCoolUntilMs);
      if (last != null && last > 0) {
        _lastPullAt = DateTime.fromMillisecondsSinceEpoch(last);
      }
      if (cool != null && cool > 0) {
        _coolUntil = DateTime.fromMillisecondsSinceEpoch(cool);
      }
    } catch (e) {
      debugPrint('[ks-pull] load cooldown: $e');
    }
  }

  static Future<void> _markPullAttempt() async {
    _lastPullAt = DateTime.now();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(
          PrefsKeys.ksPullLastMs, _lastPullAt!.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('[ks-pull] save last pull: $e');
    }
  }

  static Future<void> _markRateLimited() async {
    _coolUntil = DateTime.now().add(rateLimitCooldown);
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(
        PrefsKeys.ksPullCoolUntilMs,
        _coolUntil!.millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('[ks-pull] save cool until: $e');
    }
  }

  static String _roomId(String input) {
    final m =
        RegExp(r'live\.kuaishou\.com/u/([A-Za-z0-9_\-]+)').firstMatch(input);
    if (m != null) return m.group(1)!;
    return input.trim().split(RegExp(r'[/?#]')).last;
  }

  /// 只取当前房间：author.id 对得上，或地址栏已是该房间时的 activeIndex。
  static List<String> pickCurrentRoomUrls({
    required String rid,
    required String href,
    required List<({String principalId, List<String> urls})> items,
    int activeIndex = 0,
    List<String> extraUrls = const [],
  }) {
    final r = rid.trim().toLowerCase();
    if (r.isEmpty) return const [];
    for (final it in items) {
      if (it.principalId.trim().toLowerCase() == r && it.urls.isNotEmpty) {
        return it.urls;
      }
    }
    if (hrefIsTargetRoom(href, rid) && items.isNotEmpty) {
      final i = activeIndex.clamp(0, items.length - 1);
      final active = items[i];
      final pid = active.principalId.trim().toLowerCase();
      if (active.urls.isNotEmpty && (pid.isEmpty || pid == r)) {
        return active.urls;
      }
    }
    if (hrefIsTargetRoom(href, rid)) {
      final extra = extraUrls
          .map((u) => u.trim())
          .where((u) => u.startsWith('http'))
          .toList();
      if (extra.isNotEmpty) return extra;
    }
    return const [];
  }

  /// 数字用户 ID 和房间短号不是一类，不能当成「进错房间」。
  static bool principalMatchesRoom(String principalId, String rid) {
    final p = principalId.trim().toLowerCase();
    final r = rid.trim().toLowerCase();
    if (p.isEmpty || r.isEmpty) return true;
    if (p == r) return true;
    if (p.contains(r) || r.contains(p)) return true;
    final pDigit = RegExp(r'^\d+$').hasMatch(p);
    final rDigit = RegExp(r'^\d+$').hasMatch(r);
    if (pDigit != rDigit) return true;
    return false;
  }

  static bool hrefIsTargetRoom(String href, String rid) {
    final id = rid.trim();
    if (id.isEmpty) return false;
    final h = href.toLowerCase();
    final r = Uri.encodeComponent(id).toLowerCase();
    final raw = id.toLowerCase();
    if (h.contains('/u/$raw') || h.contains('/u/$r')) return true;
    if (h.contains('principalid=$raw') || h.contains('principalid=$r')) {
      return true;
    }
    return false;
  }

  static String liveStreamIdFromUrl(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '';
    try {
      final uri = Uri.parse(value);
      for (final entry in uri.queryParameters.entries) {
        if (entry.key.toLowerCase() == 'livestreamid' &&
            entry.value.trim().isNotEmpty) {
          return entry.value.trim();
        }
      }
    } catch (_) {}
    final match = RegExp(
      r'/gifshow/([A-Za-z0-9_-]+?)_(?:Game|SD|HD|UHD|Origin)[A-Za-z0-9_-]*\.(?:flv|m3u8)',
      caseSensitive: false,
    ).firstMatch(value);
    return match?.group(1) ?? '';
  }

  static ({
    String url,
    String token,
    int status,
    bool done,
    String diagnostic,
  })? parseWebSocketInfoProbe(
    String? raw,
  ) {
    final map = _decodeJsMap(raw);
    if (map == null) return null;
    return (
      url: '${map['url'] ?? ''}'.trim(),
      token: '${map['token'] ?? ''}'.trim(),
      status: map['status'] is int
          ? map['status'] as int
          : int.tryParse('${map['status'] ?? 0}') ?? 0,
      done: map['done'] == true,
      diagnostic: '${map['diagnostic'] ?? ''}',
    );
  }

  static Map<String, dynamic>? _decodeJsMap(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty || s == 'null' || s == 'undefined') return null;
    for (var i = 0; i < 2 && s.startsWith('"') && s.endsWith('"'); i++) {
      try {
        final decoded = jsonDecode(s);
        if (decoded is! String) break;
        s = decoded;
      } catch (_) {
        break;
      }
    }
    try {
      final decoded = jsonDecode(s);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return null;
  }

  static ({
    String href,
    bool captcha,
    int activeIndex,
    String activeError,
    String principalId,
    String liveStreamId,
    Map<String, dynamic>? wsInfo,
    List<({String principalId, List<String> urls})> items,
    List<String> hooked,
    List<String> perf,
  })? _parseProbe(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    if (s.isEmpty || s == 'null' || s == 'undefined') return null;
    if (s.startsWith('"') && s.endsWith('"')) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {
        s = s.substring(1, s.length - 1).replaceAll(r'\"', '"');
      }
    }
    try {
      final map = jsonDecode(s);
      if (map is! Map) return null;
      List<String> asUrls(dynamic v) {
        final out = <String>[];
        if (v is List) {
          for (final u in v) {
            final t = '$u'.trim();
            if (t.startsWith('http')) out.add(t);
          }
        }
        return out;
      }

      final items = <({String principalId, List<String> urls})>[];
      final rawItems = map['items'];
      if (rawItems is List) {
        for (final it in rawItems) {
          if (it is! Map) continue;
          items.add((
            principalId: '${it['principalId'] ?? ''}',
            urls: asUrls(it['urls']),
          ));
        }
      }
      return (
        href: '${map['href'] ?? ''}',
        captcha: map['captcha'] == true,
        activeIndex: (map['activeIndex'] is int)
            ? map['activeIndex'] as int
            : int.tryParse('${map['activeIndex'] ?? 0}') ?? 0,
        activeError: '${map['activeError'] ?? ''}',
        principalId: '${map['principalId'] ?? ''}',
        liveStreamId: '${map['liveStreamId'] ?? ''}',
        wsInfo: map['wsInfo'] is Map
            ? Map<String, dynamic>.from(map['wsInfo'] as Map)
            : null,
        items: items,
        hooked: asUrls(map['hooked']),
        perf: asUrls(map['perf']),
      );
    } catch (e) {
      debugPrint('[ks-pull] parse probe: $e');
      return null;
    }
  }
}
