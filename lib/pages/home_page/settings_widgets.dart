part of '../home_page.dart';

/// 账户信息横幅：卡密 / 剩余时长 / 设备数 + 充值 / 退出登录。
class _AccountBanner extends StatelessWidget {
  const _AccountBanner({
    required this.auth,
    required this.onTopup,
    required this.onLogout,
  });

  final Auth auth;
  final VoidCallback onTopup;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final a = auth.current;
    final card = a?.card ?? '—';
    final remain = a?.remainingLabel ?? '未知';
    final expires = a?.expiresLabel ?? '未知';
    final device = a?.deviceId ?? '—';
    final used = a?.deviceCount;
    final max = a?.maxDevices;
    final deviceLine = (used != null && max != null)
        ? '设备 $used/$max · $device'
        : '设备 · $device';
    final low = (a?.remainingHours ?? 999) < 24;
    final expired = (a?.remainingHours ?? 1) <= 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: expired
            ? const Color(0xFFFEF2F2)
            : low
                ? const Color(0xFFFFF7ED)
                : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: expired
              ? const Color(0xFFFECACA)
              : low
                  ? const Color(0xFFFED7AA)
                  : const Color(0xFFE2E8F0),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '卡密 $card',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '剩余 $remain · 到期 $expires',
                  style: TextStyle(
                    fontSize: 12,
                    color: expired
                        ? const Color(0xFFB91C1C)
                        : low
                            ? const Color(0xFFC2410C)
                            : const Color(0xFF475569),
                    fontWeight:
                        low || expired ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  deviceLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onTopup,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('卡密充值'),
              ),
              TextButton(
                onPressed: onLogout,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: const Color(0xFF64748B),
                ),
                child: const Text('退出登录'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ok = value == '已连接' ||
        value == '已就绪' ||
        value == '已登录';
    final color = ok ? const Color(0xFF15803D) : const Color(0xFF64748B);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label · $value',
        style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.label,
    required this.controller,
    required this.onDetect,
    required this.onPick,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onDetect;
  final VoidCallback onPick;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            decoration: InputDecoration(
              labelText: label,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: onDetect, child: const Text('检测')),
        const SizedBox(width: 4),
        OutlinedButton(onPressed: onPick, child: const Text('手动选择')),
      ],
    );
  }
}

/// 设置面板：OBS/伴侣路径、WebSocket 地址、快手登录、TikTok Cookie、内存与自动停。
///
/// 通过持有的 `_HomePageState` 直接读写状态，行为与原先内联在 build() 中完全一致；
/// 展开/收起由本组件自管，不再占主 State 的字段。
class _SettingsPanel extends StatefulWidget {
  const _SettingsPanel({required this.state});

  final _HomePageState state;

  @override
  State<_SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends State<_SettingsPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        initiallyExpanded: false,
        tilePadding: EdgeInsets.zero,
        onExpansionChanged: (v) => setState(() => _open = v),
        title: Text(
          _open ? '收起设置' : '设置',
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          _PathRow(
            label: 'OBS Studio 安装路径',
            controller: s._obsPathCtrl,
            onDetect: () => s._detectObsPath(),
            onPick: s._pickObsPath,
            onChanged: (_) => s._schedulePersist(),
          ),
          const SizedBox(height: 8),
          _PathRow(
            label: '直播伴侣',
            controller: s._companionPathCtrl,
            onDetect: () => s._detectCompanionPath(),
            onPick: s._pickCompanionPath,
            onChanged: (_) {
              s._skipCompanion = false;
              s._schedulePersist();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('跳过直播伴侣路径设置'),
            subtitle: const Text('没有有效路径时不弹窗；已设置路径时仍会自动启动'),
            value: s._skipCompanion,
            onChanged: (v) {
              setState(() => s._skipCompanion = v);
              s._persist();
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: s._wsUrlCtrl,
            onChanged: (_) => s._schedulePersist(),
            decoration: InputDecoration(
              labelText: 'OBS WebSocket 地址',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      s._ksLoggedIn
                          ? Icons.verified_user
                          : Icons.login,
                      size: 18,
                      color: s._ksLoggedIn
                          ? Colors.green.shade700
                          : Colors.blueGrey,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        s._ksLoggedIn
                            ? '快手网页账号：已登录（拉流可用）'
                            : '快手网页账号：未登录（拉流易被风控）',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  s._ksLoggedIn
                      ? 'Cookie 已自动保存。失效时可重新登录。'
                      : '点击下方按钮打开快手官网登录，完成后自动获取 Cookie。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade700,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: s._busy
                          ? null
                          : () => s._loginKuaishouAccount(),
                      icon: const Icon(Icons.open_in_browser, size: 18),
                      label: Text(s._ksLoggedIn ? '重新登录' : '登录快手账号'),
                    ),
                    const SizedBox(width: 8),
                    if (s._ksLoggedIn)
                      TextButton(
                        onPressed: s._busy ? null : s._clearKuaishouCookie,
                        child: const Text('退出登录'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: s._ttCookieCtrl,
            onChanged: (_) => s._schedulePersist(),
            maxLines: 2,
            decoration: InputDecoration(
              labelText: 'TikTok Cookie（可选）',
              hintText: '浏览器登录 www.tiktok.com 后粘贴，部分地区/18+需要',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('优化直播伴侣内存'),
            value: s._memOpt,
            onChanged: (v) async {
              setState(() => s._memOpt = v);
              await s._persist();
              if (v) {
                s._startMemOpt();
                s._appendLog('已开启内存优化');
              } else {
                s._stopMemOpt();
                s._appendLog('已关闭内存优化');
              }
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('关播自动停止虚拟摄像机'),
            value: s._autoStopOnMediaEnd,
            onChanged: (v) async {
              setState(() => s._autoStopOnMediaEnd = v);
              await s._persist();
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.info_outline),
            title: const Text('关于'),
            subtitle: const Text(
              '${AppConfig.productName}  v${AppVersion.name}\n${AppAbout.publisherLine}',
            ),
            onTap: () => AppAbout.show(context),
          ),
        ],
      ),
    );
  }
}
