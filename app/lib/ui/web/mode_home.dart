// The home in the chosen 界面 (lib/state/ui_mode_state.dart) — the native shell
// or the official web page — and the quiet switch for the drawer. A switch
// cross-fades and lands on the same conversation on the same host: the web page
// opens the native conversation; the native shell opens what the page reported
// last (WebHome keeps currentSessionProvider current).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../state/ui_mode_state.dart';
import '../shell/home_shell.dart';
import '../shell/page_frame.dart';
import '../theme/app_icons.dart';
import '../theme/theme.dart';
import 'web_target.dart';

/// The app's home in the chosen 界面.
class ModeHome extends ConsumerStatefulWidget {
  const ModeHome({super.key, this.native, this.web});

  /// Stand-ins for the two homes (tests).
  @visibleForTesting
  final Widget? native;
  @visibleForTesting
  final Widget Function(DshWebTarget? initial)? web;

  @override
  ConsumerState<ModeHome> createState() => _ModeHomeState();
}

class _ModeHomeState extends ConsumerState<ModeHome> {
  @override
  Widget build(BuildContext context) {
    // 网页模式 is gone: the home is always the native shell.
    return widget.native ?? const HomeShell();
  }
}

/// The drawer's quiet switch to 网页模式: a round glass key the height of
/// 新对话 beside it, with 界面's own mark (the globe at the drawer's foot
/// opens the web page on top; this one makes it the home).
class WebModeKey extends ConsumerWidget {
  const WebModeKey({super.key, this.size = 36, this.tier = GlassTier.chrome});

  final double size;
  final GlassTier tier;

  static String get tooltip => appL10n.webSwitchToWeb;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassIconButton(
      icon: AppIcons.swap,
      tooltip: context.l10n.webSwitchToWeb,
      size: size,
      tier: tier,
      onPressed: () => unawaited(ref.read(uiModeProvider.notifier).set(UiMode.web)),
    );
  }
}
