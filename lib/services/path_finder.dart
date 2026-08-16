import 'dart:io';

import 'package:path/path.dart' as p;

/// 开播目标平台（启动对应直播伴侣）。
enum BroadcastTarget {
  kuaishou,
  douyin,
  tiktok;

  String get label {
    switch (this) {
      case BroadcastTarget.kuaishou:
        return '快手';
      case BroadcastTarget.douyin:
        return '抖音';
      case BroadcastTarget.tiktok:
        return 'TikTok';
    }
  }

  String get companionLabel {
    switch (this) {
      case BroadcastTarget.kuaishou:
        return '快手直播伴侣';
      case BroadcastTarget.douyin:
        return '抖音直播伴侣';
      case BroadcastTarget.tiktok:
        return 'TikTok LIVE Studio';
    }
  }

  static BroadcastTarget fromStorage(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'douyin':
      case 'dy':
        return BroadcastTarget.douyin;
      case 'tiktok':
      case 'tt':
        return BroadcastTarget.tiktok;
      default:
        return BroadcastTarget.kuaishou;
    }
  }

  String get storageValue {
    switch (this) {
      case BroadcastTarget.kuaishou:
        return 'kuaishou';
      case BroadcastTarget.douyin:
        return 'douyin';
      case BroadcastTarget.tiktok:
        return 'tiktok';
    }
  }
}

class PathFinder {
  static const defaultObs = r'D:\obs-studio\bin\64bit\obs64.exe';
  static const defaultKwai = r'D:\KwaiLive\bin\5.157.3.4040\kwailive.exe';
  static const defaultDouyin = r'D:\webcast_mate\直播伴侣 Launcher.exe';
  static const defaultTiktok =
      r'D:\TikTok LIVE Studio\TikTok LIVE Studio Launcher.exe';

  static const obsRelSteam =
      r'steamapps\common\OBS Studio\bin\64bit\obs64.exe';
  static const steamLibrariesVdf = r'steamapps\libraryfolders.vdf';

  Future<String?> readSteamInstallPath() async {
    try {
      final r = await Process.run('reg', [
        'query',
        r'HKCU\Software\Valve\Steam',
        '/v',
        'SteamPath',
      ]);
      final m =
          RegExp(r'SteamPath\s+REG_SZ\s+(.+)').firstMatch(r.stdout.toString());
      if (m != null) return m.group(1)!.trim();
    } catch (_) {
      // reg 查询失败继续试下一个注册表项，属尽力而为的路径探测
    }
    try {
      final r = await Process.run('reg', [
        'query',
        r'HKLM\SOFTWARE\WOW6432Node\Valve\Steam',
        '/v',
        'InstallPath',
      ]);
      final m = RegExp(r'InstallPath\s+REG_SZ\s+(.+)')
          .firstMatch(r.stdout.toString());
      if (m != null) return m.group(1)!.trim();
    } catch (_) {
      // 同上，探测失败返回 null，让上层走手动选择
    }
    return null;
  }

  Future<String?> findOBSInSteam() async {
    final steam = await readSteamInstallPath();
    if (steam == null) return null;
    final roots = <String>{steam};
    final vdf = File(p.join(steam, steamLibrariesVdf));
    if (await vdf.exists()) {
      final text = await vdf.readAsString();
      for (final m in RegExp(r'"path"\s+"([^"]+)"').allMatches(text)) {
        roots.add(m.group(1)!.replaceAll(r'\\', r'\'));
      }
    }
    for (final root in roots) {
      final candidate = p.join(root, obsRelSteam);
      if (await File(candidate).exists()) return candidate;
    }
    return null;
  }

  Future<String?> searchUninstall(
    List<String> nameHints,
    List<String> exeNames,
  ) async {
    final keys = [
      r'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
      r'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
      r'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    ];
    for (final key in keys) {
      try {
        final list = await Process.run('reg', ['query', key]);
        for (final line in list.stdout.toString().split('\n')) {
          final sub = line.trim();
          if (!sub.startsWith('HKEY_')) continue;
          final q = await Process.run('reg', ['query', sub]);
          final out = q.stdout.toString();
          final display = RegExp(r'DisplayName\s+REG_SZ\s+(.+)')
              .firstMatch(out)
              ?.group(1)
              ?.trim();
          final loc = RegExp(r'InstallLocation\s+REG_SZ\s+(.+)')
              .firstMatch(out)
              ?.group(1)
              ?.trim();
          if (display == null || loc == null) continue;
          if (!nameHints
              .any((h) => display.toLowerCase().contains(h.toLowerCase()))) {
            continue;
          }
          for (final exeName in exeNames) {
            final direct = p.join(loc, exeName);
            if (await File(direct).exists()) return direct;
            for (final subDir in ['bin\\64bit', 'Bin', 'bin', '']) {
              final c = p.join(loc, subDir, exeName);
              if (await File(c).exists()) return c;
            }
          }
          // 在安装目录下递归浅搜目标 exe（限两层）
          final found = await _shallowFindExe(loc, exeNames, maxDepth: 2);
          if (found != null) return found;
        }
      } catch (_) {
        // 目录扫描失败跳过该安装位置，继续探测其它位置
      }
    }
    return null;
  }

  Future<String?> _shallowFindExe(
    String root,
    List<String> exeNames, {
    int maxDepth = 2,
  }) async {
    final dir = Directory(root);
    if (!await dir.exists()) return null;
    final lowerNames = exeNames.map((e) => e.toLowerCase()).toSet();

    Future<String?> walk(Directory d, int depth) async {
      try {
        await for (final entity in d.list()) {
          if (entity is File) {
            final name = p.basename(entity.path).toLowerCase();
            if (lowerNames.contains(name)) return entity.path;
          } else if (entity is Directory && depth < maxDepth) {
            final hit = await walk(entity, depth + 1);
            if (hit != null) return hit;
          }
        }
      } catch (_) {
        // 某子目录不可读时返回 null，放弃该目录的浅搜
      }
      return null;
    }

    return walk(dir, 0);
  }

  Future<String?> _firstExisting(List<String> candidates) async {
    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }
    return null;
  }

  /// 优先用你本机固定目录，再 Steam / 卸载项。
  Future<String?> detectObsPath() async {
    if (await File(defaultObs).exists()) return defaultObs;
    return await findOBSInSteam() ??
        await searchUninstall(
          ['OBS Studio', 'obs-studio'],
          ['obs64.exe'],
        );
  }

  Future<String?> detectKwailivePath() async {
    if (await File(defaultKwai).exists()) return defaultKwai;
    // 扫描 D:\KwaiLive\bin\*\\kwailive.exe
    final bin = Directory(r'D:\KwaiLive\bin');
    if (await bin.exists()) {
      await for (final entity in bin.list()) {
        if (entity is! Directory) continue;
        final exe = File(p.join(entity.path, 'kwailive.exe'));
        if (await exe.exists()) return exe.path;
      }
    }
    return searchUninstall(
      ['快手直播伴侣', 'KwaiLive', 'kwailive'],
      ['kwailive.exe'],
    );
  }

  Future<String?> detectDouyinMatePath() async {
    final hit = await _firstExisting([
      defaultDouyin,
      r'D:\webcast_mate\直播伴侣.exe',
      r'D:\webcast_mate\WebcastMate.exe',
      r'C:\Program Files\webcast_mate\直播伴侣 Launcher.exe',
      r'C:\Program Files (x86)\webcast_mate\直播伴侣 Launcher.exe',
    ]);
    if (hit != null) return hit;

    final root = Directory(r'D:\webcast_mate');
    if (await root.exists()) {
      final found = await _shallowFindExe(
        root.path,
        ['直播伴侣 Launcher.exe', '直播伴侣.exe', 'WebcastMate.exe'],
        maxDepth: 2,
      );
      if (found != null) return found;
    }

    return searchUninstall(
      ['抖音直播伴侣', '直播伴侣', 'webcast_mate', 'WebcastMate'],
      ['直播伴侣 Launcher.exe', '直播伴侣.exe', 'WebcastMate.exe'],
    );
  }

  Future<String?> detectTiktokStudioPath() async {
    final hit = await _firstExisting([
      defaultTiktok,
      r'D:\TikTok LIVE Studio\TikTok LIVE Studio.exe',
      r'C:\Program Files\TikTok LIVE Studio\TikTok LIVE Studio Launcher.exe',
      r'C:\Program Files\TikTok LIVE Studio\TikTok LIVE Studio.exe',
    ]);
    if (hit != null) return hit;

    final root = Directory(r'D:\TikTok LIVE Studio');
    if (await root.exists()) {
      final found = await _shallowFindExe(
        root.path,
        [
          'TikTok LIVE Studio Launcher.exe',
          'TikTok LIVE Studio.exe',
          'LIVE Studio Launcher.exe',
        ],
        maxDepth: 2,
      );
      if (found != null) return found;
    }

    return searchUninstall(
      ['TikTok LIVE Studio', 'LIVE Studio', 'TikTokLiveStudio'],
      [
        'TikTok LIVE Studio Launcher.exe',
        'TikTok LIVE Studio.exe',
        'LIVE Studio Launcher.exe',
      ],
    );
  }

  /// 探测本机任意常见直播伴侣（快手 / 抖音 / TikTok）。
  Future<String?> detectCompanionPath() async {
    return await detectKwailivePath() ??
        await detectDouyinMatePath() ??
        await detectTiktokStudioPath();
  }
}
