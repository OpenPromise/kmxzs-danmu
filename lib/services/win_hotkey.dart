import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 在本进程里前置窗口并发快捷键（SendInput），不另开 PowerShell。
///
/// 从 Cursor / 后台进程代按会被标成模拟输入，伴侣热键线程会丢掉；
/// 用户在快马小助手里点「一键开始」后由本进程发送，才有机会被认。
class WinHotkey {
  WinHotkey._();

  static const vkShift = 0x10;
  static const vkControl = 0x11;
  static const vkMenu = 0x12;
  static const vkReturn = 0x0D;
  static const _inputKeyboard = 1;
  static const _keyeventfKeyup = 0x0002;
  static const _swRestore = 9;
  static const _swShownormal = 1;
  static const _swShow = 5;
  static const _swpNomove = 0x0002;
  static const _swpNosize = 0x0001;
  static const _swpShowwindow = 0x0040;
  static const _hwndTopmost = -1;
  static const _hwndNotopmost = -2;
  static const _processQueryLimited = 0x1000;
  static const _asfwAny = 0xFFFFFFFF;

  static _WinApis? _apis;
  static _WinApis get _a {
    _apis ??= _WinApis();
    return _apis!;
  }

  static int get keyboardInputSize => sizeOf<_WinKbInput>();
  static int get mouseInputSize => sizeOf<_WinMouseInput>();

  /// 最近一次点关播确认框的诊断，便于写进客户端日志。
  static String lastConfirmDetail = '';

  static bool get isSupported =>
      Platform.isWindows && sizeOf<Pointer<Void>>() == 8;

  /// 关播确认框大约 376×196（逻辑）或 564×294（150% DPI 物理）。
  /// 712×400 那种卡片窗不能算进来。
  static bool isStopConfirmSize(int w, int h) {
    if (w < 240 || w > 680) return false;
    if (h < 100 || h > 360) return false;
    final ar = w / h;
    return ar >= 1.5 && ar <= 2.6;
  }

  /// 把快手直播伴侣主窗口提到前台。找不到窗口返回 false。
  static bool focusKwailive() {
    if (!isSupported) return false;
    final hwnd = _findKwailiveHwnd();
    if (hwnd == 0) return false;
    return _focusHwnd(hwnd);
  }

  /// 把标题包含 [titlePart] 的窗口提到桌面最前并保持置顶。
  /// 滑块窗口要用这个：普通 SetForegroundWindow 会被 OBS/伴侣盖住。
  static bool raiseTopmostByTitle(String titlePart) {
    if (!isSupported) return false;
    final needle = titlePart.trim();
    if (needle.isEmpty) return false;
    final hwnd = _findVisibleHwndByTitle(needle);
    if (hwnd == 0) return false;
    _a.allowSetForegroundWindow(_asfwAny);
    if (_a.isIconic(hwnd) != 0) {
      _a.showWindow(hwnd, _swRestore);
    }
    _a.showWindow(hwnd, _swShow);
    final fg = _a.getForegroundWindow();
    final pidPtr = calloc<Uint32>();
    try {
      final fgTid = fg == 0 ? 0 : _a.getWindowThreadProcessId(fg, pidPtr);
      final curTid = _a.getCurrentThreadId();
      final attached = fgTid != 0 && fgTid != curTid;
      if (attached) _a.attachThreadInput(curTid, fgTid, 1);
      const flags = _swpNomove | _swpNosize | _swpShowwindow;
      _a.setWindowPos(hwnd, _hwndTopmost, 0, 0, 0, 0, flags);
      _a.bringWindowToTop(hwnd);
      _a.setForegroundWindow(hwnd);
      if (attached) _a.attachThreadInput(curTid, fgTid, 0);
      return true;
    } finally {
      calloc.free(pidPtr);
    }
  }

  static int _findVisibleHwndByTitle(String needle) {
    final hit = calloc<IntPtr>();
    final titleBuf = calloc<Uint16>(256);
    int proc(int hwnd, int lParam) {
      if (hit.value != 0) return 0;
      if (_a.isWindowVisible(hwnd) == 0) return 1;
      titleBuf.asTypedList(256).fillRange(0, 256, 0);
      _a.getWindowText(hwnd, titleBuf.cast(), 256);
      final title = titleBuf.cast<Utf16>().toDartString();
      if (title.contains(needle)) {
        hit.value = hwnd;
        return 0;
      }
      return 1;
    }

    final cb = NativeCallable<_EnumWindowsProcNative>.isolateLocal(
      proc,
      exceptionalReturn: 0,
    );
    try {
      _a.enumWindows(cb.nativeFunction, 0);
      return hit.value;
    } finally {
      cb.close();
      calloc.free(hit);
      calloc.free(titleBuf);
    }
  }

  /// 解析并发送快捷键。成功注入（SendInput 全数返回）即为 true。
  static Future<bool> send(String raw) async {
    if (!isSupported) return false;
    final chord = KwaiHotkeyChord.parse(raw);
    if (chord == null) return false;
    return _sendChord(chord);
  }

  static Future<bool> _sendChord(KwaiHotkeyChord chord) async {
    final mods = <int>[
      if (chord.ctrl) vkControl,
      if (chord.alt) vkMenu,
      if (chord.shift) vkShift,
    ];
    if (!_sendVks(mods, up: false)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!_sendVks([chord.vk], up: false)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    if (!_sendVks([chord.vk], up: true)) return false;
    return _sendVks(mods.reversed.toList(), up: true);
  }

  static bool _sendVks(List<int> vks, {required bool up}) {
    if (vks.isEmpty) return true;
    final n = vks.length;
    final ptr = calloc<_WinKbInput>(n);
    try {
      for (var i = 0; i < n; i++) {
        _fillKey(ptr + i, vks[i], up);
      }
      final sent = _a.sendInput(n, ptr, sizeOf<_WinKbInput>());
      return sent == n;
    } finally {
      calloc.free(ptr);
    }
  }

  static void _fillKey(Pointer<_WinKbInput> p, int vk, bool up) {
    p.ref.type = _inputKeyboard;
    p.ref.unionAlign = 0;
    p.ref.wVk = vk;
    p.ref.wScan = _a.mapVirtualKey(vk, 0);
    p.ref.dwFlags = up ? _keyeventfKeyup : 0;
    p.ref.time = 0;
    p.ref.extraAlign = 0;
    p.ref.dwExtraInfo = 0;
    p.ref.unionPad0 = 0;
    p.ref.unionPad1 = 0;
  }

  static bool _focusHwnd(int hwnd) {
    _a.allowSetForegroundWindow(_asfwAny);
    if (_a.isIconic(hwnd) != 0) {
      _a.showWindow(hwnd, _swRestore);
    }
    _a.showWindow(hwnd, _swShownormal);
    _a.showWindow(hwnd, _swShow);

    final fg = _a.getForegroundWindow();
    final pidPtr = calloc<Uint32>();
    try {
      final fgTid = fg == 0 ? 0 : _a.getWindowThreadProcessId(fg, pidPtr);
      final curTid = _a.getCurrentThreadId();
      final attached = fgTid != 0 && fgTid != curTid;
      if (attached) _a.attachThreadInput(curTid, fgTid, 1);
      _a.bringWindowToTop(hwnd);
      final ok = _a.setForegroundWindow(hwnd) != 0;
      const flags = _swpNomove | _swpNosize | _swpShowwindow;
      _a.setWindowPos(hwnd, _hwndTopmost, 0, 0, 0, 0, flags);
      _a.setWindowPos(hwnd, _hwndNotopmost, 0, 0, 0, 0, flags);
      if (attached) _a.attachThreadInput(curTid, fgTid, 0);
      return ok || _a.getForegroundWindow() == hwnd;
    } finally {
      calloc.free(pidPtr);
    }
  }

  static int _findKwailiveHwnd() {
    final found = <_Wnd>[];
    final pidPtr = calloc<Uint32>();
    final classBuf = calloc<Uint16>(256);
    final titleBuf = calloc<Uint16>(256);
    final exeCache = <int, String>{};

    int proc(int hwnd, int lParam) {
      if (_a.isWindowVisible(hwnd) == 0) return 1;
      pidPtr.value = 0;
      _a.getWindowThreadProcessId(hwnd, pidPtr);
      final pid = pidPtr.value;
      if (pid == 0) return 1;
      final exe = exeCache.putIfAbsent(pid, () => _exeName(pid));
      if (!exe.toLowerCase().endsWith('\\kwailive.exe') &&
          exe.toLowerCase() != 'kwailive.exe') {
        return 1;
      }
      classBuf[0] = 0;
      titleBuf[0] = 0;
      _a.getClassName(hwnd, classBuf.cast(), 256);
      _a.getWindowText(hwnd, titleBuf.cast(), 256);
      final cls = classBuf.cast<Utf16>().toDartString();
      final title = titleBuf.cast<Utf16>().toDartString();
      final rc = calloc<_WinRect>();
      try {
        _a.getWindowRect(hwnd, rc);
        found.add(
          _Wnd(
            hwnd: hwnd,
            cls: cls,
            title: title,
            left: rc.ref.left,
            top: rc.ref.top,
            width: rc.ref.right - rc.ref.left,
            height: rc.ref.bottom - rc.ref.top,
            iconic: _a.isIconic(hwnd) != 0,
          ),
        );
      } finally {
        calloc.free(rc);
      }
      return 1;
    }

    final cb = NativeCallable<_EnumWindowsProcNative>.isolateLocal(
      proc,
      exceptionalReturn: 0,
    );
    try {
      _a.enumWindows(cb.nativeFunction, 0);
    } finally {
      cb.close();
      calloc.free(pidPtr);
      calloc.free(classBuf);
      calloc.free(titleBuf);
    }
    if (found.isEmpty) return 0;
    found.sort((a, b) => b.score.compareTo(a.score));
    return found.first.hwnd;
  }

  /// 关播确认框：截窗找粉色「确定」，点不到再按截图比例点右下。
  /// 不要 ShowWindow，工具窗被还原后坐标会乱。
  static Future<bool> clickKwaiStopConfirm() async {
    if (!isSupported) return false;
    lastConfirmDetail = '';
    final found = _listKwaiWnds();
    final qt = found.where((w) => !w.iconic && w.cls.contains('Qt')).toList();
    final candidates = qt.where((w) {
      if (isStopConfirmSize(w.width, w.height)) return true;
      return w.cls.contains('ToolSaveBits') &&
          w.width > w.height &&
          w.width * w.height < 280000;
    }).toList();
    candidates.sort((a, b) => _confirmScore(b).compareTo(_confirmScore(a)));
    lastConfirmDetail =
        'qt=${qt.map((w) => '${w.width}x${w.height}').join(',')}'
        ' cand=${candidates.map((w) => '${w.width}x${w.height}').join(',')}';
    if (candidates.isEmpty) return false;

    _raiseHwnd(candidates.first.hwnd);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    var bestN = 0;
    var bestX = 0;
    var bestY = 0;
    _Wnd? pinkWnd;
    for (final w in candidates.take(8)) {
      final hit = _pinkButtonInHwnd(w) ??
          _pinkButtonInRect(w.left, w.top, w.width, w.height);
      if (hit == null || hit.n <= bestN) continue;
      bestN = hit.n;
      bestX = hit.x;
      bestY = hit.y;
      pinkWnd = w;
    }

    final target = pinkWnd ?? candidates.first;
    if (target.hwnd != candidates.first.hwnd) {
      _raiseHwnd(target.hwnd);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    final x = pinkWnd == null
        ? target.left + (target.width * 675 / 1000).round()
        : bestX;
    final y = pinkWnd == null
        ? target.top + (target.height * 784 / 1000).round()
        : bestY;
    lastConfirmDetail += pinkWnd == null
        ? ' fallback ${target.width}x${target.height} @$x,$y'
        : ' pink n=$bestN ${target.width}x${target.height} @$x,$y';

    final ok = await _clickAt(x, y, hwnd: target.hwnd);
    lastConfirmDetail += ok ? ' clicked' : ' click-fail';
    return ok;
  }

  static bool stopConfirmVisible() {
    if (!isSupported) return false;
    return _listKwaiWnds().any((w) {
      if (w.iconic || !w.cls.contains('Qt')) return false;
      return isStopConfirmSize(w.width, w.height);
    });
  }

  // ── 抖音直播伴侣（Electron / Chrome_WidgetWin_1）─────────────────────────

  /// 抖音关播确认框尺寸：逻辑像素约 280×162，150% DPI 约 420×243。
  static bool isDouyinStopConfirmSize(int w, int h) {
    if (w < 220 || w > 520) return false;
    if (h < 120 || h > 320) return false;
    final ar = w / h;
    return ar >= 1.4 && ar <= 2.2;
  }

  /// 点抖音关播确认弹窗里的粉色「确认」按钮。
  /// 逻辑与快手版相同，但只找 exe=直播伴侣 + Chrome_WidgetWin_1 窗口。
  static Future<bool> clickDouyinStopConfirm() async {
    if (!isSupported) return false;
    lastConfirmDetail = '';
    final wnds = _listDouyinWnds();
    final candidates = wnds
        .where((w) => !w.iconic && isDouyinStopConfirmSize(w.width, w.height))
        .toList();
    candidates.sort((a, b) {
      final sa = (a.width * a.height - 45360).abs();
      final sb = (b.width * b.height - 45360).abs();
      return sa.compareTo(sb);
    });
    lastConfirmDetail =
        'dy_cand=${candidates.map((w) => '${w.width}x${w.height}').join(',')}';
    if (candidates.isEmpty) return false;

    _raiseHwnd(candidates.first.hwnd);
    await Future<void>.delayed(const Duration(milliseconds: 120));

    var bestN = 0;
    var bestX = 0;
    var bestY = 0;
    _Wnd? pinkWnd;
    for (final w in candidates.take(4)) {
      final hit = _pinkButtonInHwnd(w) ??
          _pinkButtonInRect(w.left, w.top, w.width, w.height);
      if (hit == null || hit.n <= bestN) continue;
      bestN = hit.n;
      bestX = hit.x;
      bestY = hit.y;
      pinkWnd = w;
    }

    final target = pinkWnd ?? candidates.first;
    final x = pinkWnd == null
        ? target.left + (target.width * 0.72).round()
        : bestX;
    final y = pinkWnd == null
        ? target.top + (target.height * 0.78).round()
        : bestY;
    lastConfirmDetail += pinkWnd == null
        ? ' dy_fallback ${target.width}x${target.height} @$x,$y'
        : ' dy_pink n=$bestN ${target.width}x${target.height} @$x,$y';

    final ok = await _clickAt(x, y, hwnd: target.hwnd);
    lastConfirmDetail += ok ? ' clicked' : ' click-fail';
    return ok;
  }

  /// 抖音关播弹窗是否可见。
  static bool douyinStopConfirmVisible() {
    if (!isSupported) return false;
    return _listDouyinWnds()
        .any((w) => !w.iconic && isDouyinStopConfirmSize(w.width, w.height));
  }

  /// 枚举抖音直播伴侣（直播伴侣.exe / webcast_mate.exe）的所有可见窗口。
  static List<_Wnd> _listDouyinWnds() {
    final found = <_Wnd>[];
    final pidPtr = calloc<Uint32>();
    final classBuf = calloc<Uint16>(256);
    final titleBuf = calloc<Uint16>(256);
    final exeCache = <int, String>{};

    int proc(int hwnd, int lParam) {
      if (_a.isWindowVisible(hwnd) == 0) return 1;
      pidPtr.value = 0;
      _a.getWindowThreadProcessId(hwnd, pidPtr);
      final pid = pidPtr.value;
      if (pid == 0) return 1;
      final exe = exeCache.putIfAbsent(pid, () => _exeName(pid));
      final el = exe.toLowerCase();
      final isDouyin = el.endsWith('\\直播伴侣.exe') ||
          el == '直播伴侣.exe' ||
          el.contains('webcast_mate') ||
          el.contains('webcastmate');
      if (!isDouyin) return 1;
      classBuf[0] = 0;
      _a.getClassName(hwnd, classBuf.cast(), 256);
      final cls = classBuf.cast<Utf16>().toDartString();
      if (!cls.contains('Chrome_WidgetWin')) return 1;
      titleBuf[0] = 0;
      _a.getWindowText(hwnd, titleBuf.cast(), 256);
      final rc = calloc<_WinRect>();
      try {
        _a.getWindowRect(hwnd, rc);
        found.add(
          _Wnd(
            hwnd: hwnd,
            cls: cls,
            title: titleBuf.cast<Utf16>().toDartString(),
            left: rc.ref.left,
            top: rc.ref.top,
            width: rc.ref.right - rc.ref.left,
            height: rc.ref.bottom - rc.ref.top,
            iconic: _a.isIconic(hwnd) != 0,
          ),
        );
      } finally {
        calloc.free(rc);
      }
      return 1;
    }

    final cb = NativeCallable<_EnumWindowsProcNative>.isolateLocal(
      proc,
      exceptionalReturn: 0,
    );
    try {
      _a.enumWindows(cb.nativeFunction, 0);
    } finally {
      cb.close();
      calloc.free(pidPtr);
      calloc.free(classBuf);
      calloc.free(titleBuf);
    }
    return found;
  }

  static int _confirmScore(_Wnd w) {
    var s = 0;
    if (w.cls.contains('ToolSaveBits') || w.cls.contains('QWindowTool')) {
      s += 1000;
    }
    if (isStopConfirmSize(w.width, w.height)) s += 800;
    final area = w.width * w.height;
    final dist = (area - 73700).abs() < (area - 165816).abs()
        ? (area - 73700).abs()
        : (area - 165816).abs();
    s -= dist ~/ 200;
    return s;
  }

  static void _raiseHwnd(int hwnd) {
    _a.allowSetForegroundWindow(_asfwAny);
    const flags = _swpNomove | _swpNosize;
    _a.setWindowPos(hwnd, _hwndTopmost, 0, 0, 0, 0, flags);
    _a.bringWindowToTop(hwnd);
    _a.setForegroundWindow(hwnd);
  }

  static List<_Wnd> _listKwaiWnds() {
    final found = <_Wnd>[];
    final pidPtr = calloc<Uint32>();
    final classBuf = calloc<Uint16>(256);
    final titleBuf = calloc<Uint16>(256);
    final exeCache = <int, String>{};

    int proc(int hwnd, int lParam) {
      if (_a.isWindowVisible(hwnd) == 0) return 1;
      pidPtr.value = 0;
      _a.getWindowThreadProcessId(hwnd, pidPtr);
      final pid = pidPtr.value;
      if (pid == 0) return 1;
      final exe = exeCache.putIfAbsent(pid, () => _exeName(pid));
      final isKwai = exe.toLowerCase().endsWith('\\kwailive.exe') ||
          exe.toLowerCase() == 'kwailive.exe';
      classBuf[0] = 0;
      _a.getClassName(hwnd, classBuf.cast(), 256);
      final cls = classBuf.cast<Utf16>().toDartString();
      if (!isKwai && !cls.contains('Qt515')) return 1;
      titleBuf[0] = 0;
      _a.getWindowText(hwnd, titleBuf.cast(), 256);
      final rc = calloc<_WinRect>();
      try {
        _a.getWindowRect(hwnd, rc);
        found.add(
          _Wnd(
            hwnd: hwnd,
            cls: cls,
            title: titleBuf.cast<Utf16>().toDartString(),
            left: rc.ref.left,
            top: rc.ref.top,
            width: rc.ref.right - rc.ref.left,
            height: rc.ref.bottom - rc.ref.top,
            iconic: _a.isIconic(hwnd) != 0,
          ),
        );
      } finally {
        calloc.free(rc);
      }
      return 1;
    }

    final cb = NativeCallable<_EnumWindowsProcNative>.isolateLocal(
      proc,
      exceptionalReturn: 0,
    );
    try {
      _a.enumWindows(cb.nativeFunction, 0);
    } finally {
      cb.close();
      calloc.free(pidPtr);
      calloc.free(classBuf);
      calloc.free(titleBuf);
    }
    return found;
  }

  static ({int x, int y, int n})? _pinkButtonInHwnd(_Wnd w) {
    if (w.width < 80 || w.height < 60 || w.width > 1920 || w.height > 1200) {
      return null;
    }
    final gdi = DynamicLibrary.open('gdi32.dll');
    final createCompatibleDc = gdi.lookupFunction<IntPtr Function(IntPtr),
        int Function(int)>('CreateCompatibleDC');
    final createCompatibleBitmap = gdi.lookupFunction<
        IntPtr Function(IntPtr, Int32, Int32),
        int Function(int, int, int)>('CreateCompatibleBitmap');
    final selectObject = gdi.lookupFunction<IntPtr Function(IntPtr, IntPtr),
        int Function(int, int)>('SelectObject');
    final getDiBits = gdi.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Uint32, Uint32, Pointer<Uint8>,
            Pointer<_BitmapInfo>, Uint32),
        int Function(int, int, int, int, Pointer<Uint8>, Pointer<_BitmapInfo>,
            int)>('GetDIBits');
    final deleteDc =
        gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
    final deleteObject = gdi.lookupFunction<Int32 Function(IntPtr),
        int Function(int)>('DeleteObject');

    final screen = _a.getDc(0);
    if (screen == 0) return null;
    final memDc = createCompatibleDc(screen);
    final bmp = createCompatibleBitmap(screen, w.width, w.height);
    final old = selectObject(memDc, bmp);
    var printed = _a.printWindow(w.hwnd, memDc, 2);
    if (printed == 0) {
      printed = _a.printWindow(w.hwnd, memDc, 0);
    }

    final bmi = calloc<_BitmapInfo>();
    final bits = calloc<Uint8>(w.width * w.height * 4);
    try {
      if (printed == 0) return null;
      bmi.ref.biSize = 40;
      bmi.ref.biWidth = w.width;
      bmi.ref.biHeight = -w.height;
      bmi.ref.biPlanes = 1;
      bmi.ref.biBitCount = 32;
      bmi.ref.biCompression = 0;
      if (getDiBits(memDc, bmp, 0, w.height, bits, bmi, 0) == 0) return null;
      return _pinkInBits(bits, w.width, w.height, w.left, w.top);
    } finally {
      calloc.free(bits);
      calloc.free(bmi);
      selectObject(memDc, old);
      deleteObject(bmp);
      deleteDc(memDc);
      _a.releaseDc(0, screen);
    }
  }

  static ({int x, int y, int n})? _pinkButtonInRect(
    int left,
    int top,
    int w,
    int h,
  ) {
    if (w < 80 || h < 60 || w > 1920 || h > 1200) return null;
    final gdi = DynamicLibrary.open('gdi32.dll');
    final createCompatibleDc = gdi.lookupFunction<IntPtr Function(IntPtr),
        int Function(int)>('CreateCompatibleDC');
    final createCompatibleBitmap = gdi.lookupFunction<
        IntPtr Function(IntPtr, Int32, Int32),
        int Function(int, int, int)>('CreateCompatibleBitmap');
    final selectObject = gdi.lookupFunction<IntPtr Function(IntPtr, IntPtr),
        int Function(int, int)>('SelectObject');
    final bitBlt = gdi.lookupFunction<
        Int32 Function(
            IntPtr, Int32, Int32, Int32, Int32, IntPtr, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int, int, int)>('BitBlt');
    final getDiBits = gdi.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Uint32, Uint32, Pointer<Uint8>,
            Pointer<_BitmapInfo>, Uint32),
        int Function(int, int, int, int, Pointer<Uint8>, Pointer<_BitmapInfo>,
            int)>('GetDIBits');
    final deleteDc =
        gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteDC');
    final deleteObject = gdi.lookupFunction<Int32 Function(IntPtr),
        int Function(int)>('DeleteObject');

    const srcCopy = 0x00CC0020;
    final screen = _a.getDc(0);
    if (screen == 0) return null;
    final memDc = createCompatibleDc(screen);
    final bmp = createCompatibleBitmap(screen, w, h);
    final old = selectObject(memDc, bmp);
    bitBlt(memDc, 0, 0, w, h, screen, left, top, srcCopy);

    final bmi = calloc<_BitmapInfo>();
    final bits = calloc<Uint8>(w * h * 4);
    try {
      bmi.ref.biSize = 40;
      bmi.ref.biWidth = w;
      bmi.ref.biHeight = -h;
      bmi.ref.biPlanes = 1;
      bmi.ref.biBitCount = 32;
      bmi.ref.biCompression = 0;
      if (getDiBits(memDc, bmp, 0, h, bits, bmi, 0) == 0) return null;
      return _pinkInBits(bits, w, h, left, top);
    } finally {
      calloc.free(bits);
      calloc.free(bmi);
      selectObject(memDc, old);
      deleteObject(bmp);
      deleteDc(memDc);
      _a.releaseDc(0, screen);
    }
  }

  static ({int x, int y, int n})? _pinkInBits(
    Pointer<Uint8> bits,
    int w,
    int h,
    int left,
    int top,
  ) {
    var sx = 0;
    var sy = 0;
    var n = 0;
    for (var y = (h * 0.52).floor(); y < (h * 0.92).ceil() && y < h; y++) {
      for (var x = (w * 0.50).floor(); x < (w * 0.92).ceil() && x < w; x++) {
        final i = (y * w + x) * 4;
        final b = bits[i];
        final g = bits[i + 1];
        final r = bits[i + 2];
        if (r > 160 && g < 150 && b > 30 && r > g + 50 && r > b) {
          sx += x;
          sy += y;
          n++;
        }
      }
    }
    if (n < 40) return null;
    return (x: left + sx ~/ n, y: top + sy ~/ n, n: n);
  }

  static Future<bool> _clickAt(int x, int y, {int hwnd = 0}) async {
    _a.setCursorPos(x, y);
    _sendMouseAbs(x, y, 0);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    var sent = _sendMouseAbs(x, y, 0x0002);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    sent = _sendMouseAbs(x, y, 0x0004) && sent;
    if (!sent) {
      _a.setCursorPos(x, y);
      _a.mouseEvent(0x0002, 0, 0, 0, 0);
      _a.mouseEvent(0x0004, 0, 0, 0, 0);
    }
    if (hwnd != 0) _postClientClick(hwnd, x, y);
    return true;
  }

  static bool _sendMouseAbs(int x, int y, int buttonFlag) {
    if (sizeOf<_WinMouseInput>() != 40) return false;
    final vx = _a.getSystemMetrics(76);
    final vy = _a.getSystemMetrics(77);
    final vw = _a.getSystemMetrics(78);
    final vh = _a.getSystemMetrics(79);
    final spanX = vw <= 1 ? 1 : vw - 1;
    final spanY = vh <= 1 ? 1 : vh - 1;
    final nx = ((x - vx) * 65535 / spanX).round();
    final ny = ((y - vy) * 65535 / spanY).round();
    final ptr = calloc<_WinMouseInput>();
    try {
      const moveAbs = 0x8000 | 0x0001 | 0x4000;
      ptr.ref.type = 0;
      ptr.ref.dx = nx;
      ptr.ref.dy = ny;
      ptr.ref.dwFlags = moveAbs | buttonFlag;
      return _a.sendInputMouse(1, ptr, sizeOf<_WinMouseInput>()) == 1;
    } finally {
      calloc.free(ptr);
    }
  }

  static void _postClientClick(int hwnd, int screenX, int screenY) {
    final pt = calloc<_WinPoint>();
    try {
      pt.ref.x = screenX;
      pt.ref.y = screenY;
      if (_a.screenToClient(hwnd, pt) == 0) return;
      final lp = ((pt.ref.y & 0xFFFF) << 16) | (pt.ref.x & 0xFFFF);
      _a.postMessage(hwnd, 0x0201, 1, lp);
      _a.postMessage(hwnd, 0x0202, 0, lp);
    } finally {
      calloc.free(pt);
    }
  }

  static String _exeName(int pid) {
    final h = _a.openProcess(_processQueryLimited, 0, pid);
    if (h == nullptr) return '';
    final buf = calloc<Uint16>(260);
    final size = calloc<Uint32>();
    try {
      size.value = 260;
      final ok = _a.queryFullProcessImageName(h, 0, buf.cast(), size);
      if (ok == 0) return '';
      return buf.cast<Utf16>().toDartString();
    } finally {
      calloc.free(buf);
      calloc.free(size);
      _a.closeHandle(h);
    }
  }
}

/// Ctrl / Alt / Shift + 主键。
class KwaiHotkeyChord {
  const KwaiHotkeyChord({
    required this.vk,
    this.ctrl = false,
    this.alt = false,
    this.shift = false,
  });

  final int vk;
  final bool ctrl;
  final bool alt;
  final bool shift;

  static KwaiHotkeyChord? parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (RegExp(r'^\{?enter\}?$', caseSensitive: false).hasMatch(s)) {
      return const KwaiHotkeyChord(vk: WinHotkey.vkReturn);
    }
    final looksSendKeys = RegExp(r'^[\^%+{]').hasMatch(s) &&
        !s.toLowerCase().contains('ctrl') &&
        !s.toLowerCase().contains('alt') &&
        !s.toLowerCase().contains('shift');
    if (looksSendKeys) return _parseSendKeys(s);

    var ctrl = false;
    var alt = false;
    var shift = false;
    var key = '';
    for (final part in s.split(RegExp(r'\s*\+\s*'))) {
      final p = part.trim();
      if (p.isEmpty) continue;
      switch (p.toLowerCase()) {
        case 'ctrl':
        case 'control':
          ctrl = true;
        case 'shift':
          shift = true;
        case 'alt':
          alt = true;
        default:
          key = p;
      }
    }
    final vk = _vkFromKey(key);
    if (vk == null) return null;
    return KwaiHotkeyChord(vk: vk, ctrl: ctrl, alt: alt, shift: shift);
  }

  static KwaiHotkeyChord? _parseSendKeys(String s) {
    var ctrl = false;
    var alt = false;
    var shift = false;
    var i = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == '^') {
        ctrl = true;
        i++;
        continue;
      }
      if (ch == '%') {
        alt = true;
        i++;
        continue;
      }
      if (ch == '+') {
        shift = true;
        i++;
        continue;
      }
      break;
    }
    final rest = s.substring(i);
    if (rest.isEmpty) return null;
    String key = rest;
    if (rest.startsWith('{') && rest.endsWith('}')) {
      key = rest.substring(1, rest.length - 1);
    }
    final vk = _vkFromKey(key);
    if (vk == null) return null;
    return KwaiHotkeyChord(vk: vk, ctrl: ctrl, alt: alt, shift: shift);
  }

  static int? _vkFromKey(String key) {
    final k = key.trim();
    if (k.isEmpty) return null;
    if (RegExp(r'^F\d{1,2}$', caseSensitive: false).hasMatch(k)) {
      final n = int.parse(k.substring(1));
      if (n < 1 || n > 24) return null;
      return 0x70 + n - 1;
    }
    switch (k.toLowerCase()) {
      case 'enter':
      case 'return':
        return WinHotkey.vkReturn;
      case 'esc':
      case 'escape':
        return 0x1B;
      case 'tab':
        return 0x09;
      case 'space':
        return 0x20;
    }
    if (k.length == 1) {
      final c = k.toUpperCase().codeUnitAt(0);
      if (c >= 0x41 && c <= 0x5A) return c;
      if (c >= 0x30 && c <= 0x39) return c;
    }
    return null;
  }
}

class _Wnd {
  _Wnd({
    required this.hwnd,
    required this.cls,
    required this.title,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.iconic,
  });

  final int hwnd;
  final String cls;
  final String title;
  final int left;
  final int top;
  final int width;
  final int height;
  final bool iconic;

  int get score {
    var s = width * height;
    if (cls == 'Chrome_WidgetWin_1') s += 1000000;
    if (title.contains('直播伴侣')) s += 500000;
    if (iconic) s -= 2000000;
    return s;
  }
}

/// x64 INPUT（键盘）。官方布局 40 字节：type + 对齐 + 32 字节 union。
final class _WinKbInput extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int unionAlign;
  @Uint16()
  external int wVk;
  @Uint16()
  external int wScan;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @Uint32()
  external int extraAlign;
  @Uint64()
  external int dwExtraInfo;
  @Uint32()
  external int unionPad0;
  @Uint32()
  external int unionPad1;
}

final class _WinRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _WinPoint extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _BitmapInfo extends Struct {
  @Uint32()
  external int biSize;
  @Int32()
  external int biWidth;
  @Int32()
  external int biHeight;
  @Uint16()
  external int biPlanes;
  @Uint16()
  external int biBitCount;
  @Uint32()
  external int biCompression;
  @Uint32()
  external int biSizeImage;
  @Int32()
  external int biXPelsPerMeter;
  @Int32()
  external int biYPelsPerMeter;
  @Uint32()
  external int biClrUsed;
  @Uint32()
  external int biClrImportant;
}

/// x64 INPUT（鼠标），与键盘 INPUT 同为 40 字节。
final class _WinMouseInput extends Struct {
  @Uint32()
  external int type;
  @Uint32()
  external int unionAlign;
  @Int32()
  external int dx;
  @Int32()
  external int dy;
  @Uint32()
  external int mouseData;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @Uint32()
  external int extraPad;
  @Uint64()
  external int dwExtraInfo;
}

typedef _EnumWindowsProcNative = Int32 Function(IntPtr hwnd, IntPtr lParam);

class _WinApis {
  _WinApis()
      : _u32 = DynamicLibrary.open('user32.dll'),
        _k32 = DynamicLibrary.open('kernel32.dll') {
    sendInput = _u32.lookupFunction<
        Uint32 Function(Uint32, Pointer<_WinKbInput>, Int32),
        int Function(int, Pointer<_WinKbInput>, int)>('SendInput');
    mapVirtualKey = _u32.lookupFunction<Uint32 Function(Uint32, Uint32),
        int Function(int, int)>('MapVirtualKeyW');
    enumWindows = _u32.lookupFunction<
        Int32 Function(Pointer<NativeFunction<_EnumWindowsProcNative>>, IntPtr),
        int Function(Pointer<NativeFunction<_EnumWindowsProcNative>>,
            int)>('EnumWindows');
    getWindowThreadProcessId = _u32.lookupFunction<
        Uint32 Function(IntPtr, Pointer<Uint32>),
        int Function(int, Pointer<Uint32>)>('GetWindowThreadProcessId');
    isWindowVisible = _u32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsWindowVisible',
    );
    isIconic = _u32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'IsIconic',
    );
    getClassName = _u32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Int32),
        int Function(int, Pointer<Utf16>, int)>('GetClassNameW');
    getWindowText = _u32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Utf16>, Int32),
        int Function(int, Pointer<Utf16>, int)>('GetWindowTextW');
    getWindowRect = _u32.lookupFunction<
        Int32 Function(IntPtr, Pointer<_WinRect>),
        int Function(int, Pointer<_WinRect>)>('GetWindowRect');
    setCursorPos = _u32.lookupFunction<Int32 Function(Int32, Int32),
        int Function(int, int)>('SetCursorPos');
    mouseEvent = _u32.lookupFunction<
        Void Function(Uint32, Uint32, Uint32, Uint32, IntPtr),
        void Function(int, int, int, int, int)>('mouse_event');
    printWindow = _u32.lookupFunction<Int32 Function(IntPtr, IntPtr, Uint32),
        int Function(int, int, int)>('PrintWindow');
    screenToClient = _u32.lookupFunction<
        Int32 Function(IntPtr, Pointer<_WinPoint>),
        int Function(int, Pointer<_WinPoint>)>('ScreenToClient');
    postMessage = _u32.lookupFunction<
        Int32 Function(IntPtr, Uint32, IntPtr, IntPtr),
        int Function(int, int, int, int)>('PostMessageW');
    getDc = _u32.lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GetDC');
    releaseDc = _u32.lookupFunction<Int32 Function(IntPtr, IntPtr),
        int Function(int, int)>('ReleaseDC');
    getSystemMetrics =
        _u32.lookupFunction<Int32 Function(Int32), int Function(int)>(
      'GetSystemMetrics',
    );
    sendInputMouse = _u32.lookupFunction<
        Uint32 Function(Uint32, Pointer<_WinMouseInput>, Int32),
        int Function(int, Pointer<_WinMouseInput>, int)>('SendInput');
    showWindow = _u32.lookupFunction<Int32 Function(IntPtr, Int32),
        int Function(int, int)>('ShowWindow');
    setForegroundWindow =
        _u32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'SetForegroundWindow',
    );
    bringWindowToTop =
        _u32.lookupFunction<Int32 Function(IntPtr), int Function(int)>(
      'BringWindowToTop',
    );
    getForegroundWindow = _u32.lookupFunction<IntPtr Function(), int Function()>(
      'GetForegroundWindow',
    );
    setWindowPos = _u32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos');
    attachThreadInput = _u32.lookupFunction<
        Int32 Function(Uint32, Uint32, Int32),
        int Function(int, int, int)>('AttachThreadInput');
    allowSetForegroundWindow =
        _u32.lookupFunction<Int32 Function(Uint32), int Function(int)>(
      'AllowSetForegroundWindow',
    );
    getCurrentThreadId =
        _k32.lookupFunction<Uint32 Function(), int Function()>('GetCurrentThreadId');
    openProcess = _k32.lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Uint32),
        Pointer<Void> Function(int, int, int)>('OpenProcess');
    closeHandle = _k32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CloseHandle');
    queryFullProcessImageName = _k32.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Utf16>, Pointer<Uint32>),
        int Function(Pointer<Void>, int, Pointer<Utf16>,
            Pointer<Uint32>)>('QueryFullProcessImageNameW');
  }

  final DynamicLibrary _u32;
  final DynamicLibrary _k32;

  late final int Function(int, Pointer<_WinKbInput>, int) sendInput;
  late final int Function(int, int) mapVirtualKey;
  late final int Function(
      Pointer<NativeFunction<_EnumWindowsProcNative>>, int) enumWindows;
  late final int Function(int, Pointer<Uint32>) getWindowThreadProcessId;
  late final int Function(int) isWindowVisible;
  late final int Function(int) isIconic;
  late final int Function(int, Pointer<Utf16>, int) getClassName;
  late final int Function(int, Pointer<Utf16>, int) getWindowText;
  late final int Function(int, Pointer<_WinRect>) getWindowRect;
  late final int Function(int, int) setCursorPos;
  late final void Function(int, int, int, int, int) mouseEvent;
  late final int Function(int, int, int) printWindow;
  late final int Function(int, Pointer<_WinPoint>) screenToClient;
  late final int Function(int, int, int, int) postMessage;
  late final int Function(int) getDc;
  late final int Function(int, int) releaseDc;
  late final int Function(int) getSystemMetrics;
  late final int Function(int, Pointer<_WinMouseInput>, int) sendInputMouse;
  late final int Function(int, int) showWindow;
  late final int Function(int) setForegroundWindow;
  late final int Function(int) bringWindowToTop;
  late final int Function() getForegroundWindow;
  late final int Function(int, int, int, int, int, int, int) setWindowPos;
  late final int Function(int, int, int) attachThreadInput;
  late final int Function(int) allowSetForegroundWindow;
  late final int Function() getCurrentThreadId;
  late final Pointer<Void> Function(int, int, int) openProcess;
  late final int Function(Pointer<Void>) closeHandle;
  late final int Function(
      Pointer<Void>, int, Pointer<Utf16>, Pointer<Uint32>) queryFullProcessImageName;
}
