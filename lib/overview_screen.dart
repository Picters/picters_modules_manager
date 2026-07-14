import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'module_info.dart';
import 'theme.dart';
import 'usb_devices.dart';
import 'widgets.dart';

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({super.key, required this.controller});

  final AppController controller;

  Future<void> _toggleWifi(BuildContext context, bool toNetHunter) async {
    final err = await controller.setWifiMode(
      toNetHunter ? WifiMode.nethunter : WifiMode.stock,
    );
    if (!context.mounted) return;
    if (err != null) {
      showError(context, err);
    } else {
      showInfo(
        context,
        toNetHunter ? 'NetHunter Wi-Fi включён.' : 'Стоковый Wi-Fi восстановлен.',
      );
    }
  }

  Future<void> _loadAdapter(BuildContext context, DetectedAdapter a) async {
    final err = await controller.loadAdapter(a);
    if (!context.mounted) return;
    if (err != null) showError(context, err);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final state = controller.state;
        final recognized =
            state.adapters.where((a) => a.recognized).toList();
        final unknown = state.adapters.length - recognized.length;

        return RefreshIndicator(
          onRefresh: controller.refresh,
          color: AppColors.white,
          backgroundColor: AppColors.surfaceHigh,
          child: ListView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
            ),
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
            children: [
              const ScreenTitle('Picters Kernel Manager', subtitle: 'Обзор'),
              const SizedBox(height: 8),
              _WifiHeroCard(
                mode: state.wifiMode,
                busy: controller.wifiBusy,
                onChanged: (v) => _toggleWifi(context, v),
              ),
              const SizedBox(height: 28),
              Row(
                children: [
                  const Icon(Icons.usb, color: AppColors.gray, size: 20),
                  const SizedBox(width: 8),
                  Text('Подключённые адаптеры',
                      style: sectionLabelStyle),
                ],
              ),
              const SizedBox(height: 12),
              if (recognized.isEmpty)
                GlassCard(
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      unknown > 0
                          ? 'Wi-Fi адаптеры не найдены ($unknown других USB-устройств).'
                          : 'Воткните USB-адаптер — он появится здесь.',
                      style: const TextStyle(color: AppColors.gray, fontSize: 15),
                    ),
                  ),
                )
              else
                GlassCard(
                  child: Column(
                    children: [
                      for (var i = 0; i < recognized.length; i++) ...[
                        if (i > 0) const CardDivider(),
                        _AdapterRow(
                          adapter: recognized[i],
                          state: state,
                          busy: controller.moduleBusy
                              .contains(recognized[i].match!.driver),
                          onLoad: () => _loadAdapter(context, recognized[i]),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _WifiHeroCard extends StatelessWidget {
  const _WifiHeroCard({
    required this.mode,
    required this.busy,
    required this.onChanged,
  });

  final WifiMode mode;
  final bool busy;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final nh = mode == WifiMode.nethunter;
    final (title, subtitle, badge) = switch (mode) {
      WifiMode.stock => (
          'Стоковый Wi-Fi',
          'Работает встроенный Wi-Fi телефона. Инъекция выключена.',
          'STOCK',
        ),
      WifiMode.nethunter => (
          'NetHunter Wi-Fi',
          'Загружено наше ядро cfg80211. Можно использовать адаптеры для инъекции.',
          'NETHUNTER',
        ),
      WifiMode.off => (
          'Wi-Fi не активен',
          'Ни стоковый, ни наш стек не загружены. Включите NetHunter.',
          'OFF',
        ),
    };

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: nh ? AppColors.redDim : AppColors.surface,
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: nh ? AppColors.red.withValues(alpha: 0.6) : AppColors.outline,
          width: 1.5,
        ),
        boxShadow: nh
            ? [
                BoxShadow(
                  color: AppColors.red.withValues(alpha: 0.18),
                  blurRadius: 40,
                  spreadRadius: -6,
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ModeBadge(text: badge, active: nh),
              const Spacer(),
              if (busy)
                const SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: AppColors.white,
                  ),
                )
              else
                Switch(
                  value: nh,
                  onChanged: onChanged,
                ),
            ],
          ),
          const SizedBox(height: 20),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Column(
              key: ValueKey(mode),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.white,
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.gray,
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.text, required this.active});
  final String text;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: active ? AppColors.red : AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: active ? AppColors.white : AppColors.gray,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _AdapterRow extends StatelessWidget {
  const _AdapterRow({
    required this.adapter,
    required this.state,
    required this.busy,
    required this.onLoad,
  });

  final DetectedAdapter adapter;
  final SystemState state;
  final bool busy;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final match = adapter.match!;
    final loaded = state.modules.any((m) => m.name == match.driver && m.loaded);

    Widget trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.white),
      );
    } else if (loaded) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.bolt, color: AppColors.red, size: 18),
          SizedBox(width: 4),
          Text('активен', style: TextStyle(color: AppColors.white, fontSize: 14)),
        ],
      );
    } else {
      trailing = TextButton(
        style: TextButton.styleFrom(
          backgroundColor: AppColors.surfaceHigh,
          foregroundColor: AppColors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        onPressed: onLoad,
        child: const Text('Загрузить'),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        children: [
          const Icon(Icons.wifi_tethering, color: AppColors.white, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  adapter.device.displayName,
                  style: const TextStyle(color: AppColors.white, fontSize: 16),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${adapter.device.idPair} · ${match.driver}',
                  style: const TextStyle(color: AppColors.gray, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          trailing,
        ],
      ),
    );
  }
}
