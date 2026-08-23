import 'package:flutter_test/flutter_test.dart';
import 'package:kmxzs/services/obs_ws.dart';
import 'package:obs_websocket/obs_websocket.dart';

void main() {
  group('ObsWs.probeMediaStatus', () {
    test('游标首次停滞时立刻视为 unstable', () {
      final probed = ObsWs.probeMediaStatus(
        mediaState: ObsMediaState.playing,
        lastCursor: 1200,
        mediaCursor: 1200,
        stallTicks: 0,
      );
      expect(probed.state, PullState.unstable);
      expect(probed.stallTicks, 1);
      expect(probed.lastCursor, 1200);
    });

    test('游标连续停滞时会继续保持 unstable 并累计 stallTicks', () {
      final probed = ObsWs.probeMediaStatus(
        mediaState: ObsMediaState.playing,
        lastCursor: 1200,
        mediaCursor: 1200,
        stallTicks: 1,
      );
      expect(probed.state, PullState.unstable);
      expect(probed.stallTicks, 2);
      expect(probed.lastCursor, 1200);
    });

    test('OBS 明确 ended/error/stopped 直接视为 ended', () {
      for (final state in const [
        ObsMediaState.ended,
        ObsMediaState.error,
        ObsMediaState.stopped,
      ]) {
        final probed = ObsWs.probeMediaStatus(
          mediaState: state,
          lastCursor: 1200,
          mediaCursor: 1200,
          stallTicks: 3,
        );
        expect(probed.state, PullState.ended);
        expect(probed.stallTicks, 0);
        expect(probed.lastCursor, isNull);
      }
    });
  });

  group('PullMonitorPolicy', () {
    test('短时卡顿恢复时不触发 ended，而是触发 recovered', () {
      final policy = PullMonitorPolicy();

      expect(policy.update(PullState.playing), PullMonitorAction.none);
      expect(policy.update(PullState.unstable), PullMonitorAction.unstable);
      expect(policy.update(PullState.unstable), PullMonitorAction.none);
      expect(policy.update(PullState.playing), PullMonitorAction.none);
      expect(policy.update(PullState.playing), PullMonitorAction.none);
      expect(policy.update(PullState.playing), PullMonitorAction.recovered);
    });

    test('持续无新画面足够久后才触发 ended', () {
      final policy = PullMonitorPolicy();

      expect(policy.update(PullState.playing), PullMonitorAction.none);
      expect(policy.update(PullState.unstable), PullMonitorAction.unstable);
      for (var i = 0; i < PullMonitorPolicy.unstableTicksToEnd - 2; i++) {
        expect(policy.update(PullState.unstable), PullMonitorAction.none);
      }
      expect(policy.update(PullState.unstable), PullMonitorAction.ended);
    });

    test('明确 ended 作为辅助信号，也需要持续一段时间才自动关播', () {
      final policy = PullMonitorPolicy();

      expect(policy.update(PullState.playing), PullMonitorAction.none);
      for (var i = 0; i < PullMonitorPolicy.endedTicksToEnd - 1; i++) {
        expect(policy.update(PullState.ended), PullMonitorAction.none);
      }
      expect(policy.update(PullState.ended), PullMonitorAction.ended);
    });
  });
}
