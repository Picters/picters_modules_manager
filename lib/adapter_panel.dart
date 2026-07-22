import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'iw_repository.dart';
import 'module_info.dart';
import 'theme.dart';
import 'tx_profiles.dart';
import 'widgets.dart';

const double _kMinTxPowerDbm = 0;

/// Opens the per-interface config panel for [ifaceName] as a jelly card
/// unfolding from [origin] (the tapped row's position): monitor/managed, link
/// up/down, regulatory domain unlock and tx power. Reads [controller]'s live
/// scan directly (not a snapshot), so the panel tracks the interface's real
/// state in real time — including closing itself if the adapter disappears.
Future<void> showAdapterConfigPanel(
  BuildContext context, {
  required Offset origin,
  required String ifaceName,
  required AppController controller,
}) {
  return showJellyPanel<void>(
    context,
    origin: origin,
    builder: (context) =>
        _AdapterConfigSheet(ifaceName: ifaceName, controller: controller),
  );
}

class _AdapterConfigSheet extends StatefulWidget {
  const _AdapterConfigSheet({required this.ifaceName, required this.controller});

  final String ifaceName;
  final AppController controller;

  @override
  State<_AdapterConfigSheet> createState() => _AdapterConfigSheetState();
}

class _AdapterConfigSheetState extends State<_AdapterConfigSheet> {
  bool _busyMode = false;
  bool _busyLink = false;
  bool _busyTx = false;

  /// The "stock" reference marked on the slider — the first VALID reading we
  /// ever got for this driver (persisted). Null until one is captured (these
  /// drivers often can't read tx power back, so it may take a while).
  int? _stockTxDbm;

  /// The value the slider shows (whole dBm) — the last value the user applied
  /// (persisted per driver), since the live read is unreliable. Null until load.
  double? _txSlider;

  /// The unrestricted region is set once, lazily, on the first tx-power apply —
  /// there's no region UI, it just happens under the hood so the value takes.
  bool _boSet = false;

  // Optimistic targets: set the instant a toggle is tapped so the tablet slides
  // right away, and held (with the control locked) until the action finishes
  // and the real scan catches up — then cleared to reconcile with live state.
  bool? _pendingMonitor;
  bool? _pendingUp;

  IwRepository get _iw => widget.controller.iw;

  /// The chipset tx-power envelope (recommended / danger / physical max) for the
  /// current adapter — the slider and its markers scale to this.
  TxPowerProfile get _profile {
    final iface = _iface;
    return txProfileFor(
        iface == null ? '' : widget.controller.chipTextFor(iface));
  }

  /// The live interface record, re-read from the controller's own poll on
  /// every one of its notifications — never a snapshot, so mode/up-down here
  /// always match what the rest of the app shows.
  WifiInterface? get _iface {
    for (final i in widget.controller.state.interfaces) {
      if (i.name == widget.ifaceName) return i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _load();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (!mounted) return;
    if (_iface == null) {
      // The adapter vanished (unplugged / driver unloaded) — nothing left to
      // configure, so close instead of showing a dead panel.
      Navigator.of(context).maybePop();
      return;
    }
    setState(() {});
  }

  Future<void> _load() async {
    final info = await _iw.query(widget.ifaceName);
    if (!mounted) return;
    final maxDbm = _profile.max.toDouble();
    final driver = _iface?.driver ?? '';
    final tx = info?.txPowerDbm; // null when the driver won't read it back
    // Record stock only from a VALID reading; retrieve the persisted stock
    // (and last-set) regardless — so a bogus -100 read never wipes them.
    if (tx != null && driver.isNotEmpty) {
      await _iw.recordStockTx(driver, tx.clamp(_kMinTxPowerDbm, maxDbm).round());
    }
    final stock = driver.isEmpty ? null : await _iw.stockTx(driver);
    final lastSet = driver.isEmpty ? null : await _iw.lastSetTx(driver);
    if (!mounted) return;
    setState(() {
      _stockTxDbm = stock;
      // Default the slider to the last-set value, else the recommended — never
      // the live read (it's unreliable and would fight the persisted value).
      _txSlider ??= (lastSet ?? _profile.recommended)
          .toDouble()
          .clamp(_kMinTxPowerDbm, maxDbm);
    });
  }

  /// Polls the live state (up to ~2.5s) until [ok] holds, so a toggle's
  /// optimistic value is held until reality actually catches up — this is what
  /// stops the tablets flip-flopping on the transient reads a mode change causes
  /// (the driver bounces the link down→up, and the scan can catch either).
  Future<void> _awaitConfirm(bool Function() ok) async {
    for (var i = 0; i < 6; i++) {
      await widget.controller.refresh();
      if (!mounted || ok()) return;
      await Future<void>.delayed(const Duration(milliseconds: 350));
    }
  }

  Future<void> _toggleMode(bool monitor) async {
    final iface = _iface;
    // Compare against the displayed (commanded-or-live) value so a fast double
    // tap doesn't queue a redundant switch.
    if (_busyMode || iface == null || (_pendingMonitor ?? iface.monitor) == monitor) {
      return;
    }
    HapticFeedback.selectionClick();
    // Slide the mode tablet immediately, and pin Up (the switch ends with
    // `ip link up`) so the Up/Down tablet doesn't flicker during the bounce.
    setState(() {
      _busyMode = true;
      _pendingMonitor = monitor;
      _pendingUp = true;
    });
    final r = await _iw.setMode(iface: widget.ifaceName, monitor: monitor);
    if (mounted && !r.stdout.contains('OK_MODE')) {
      showError(context, 'Could not switch mode: ${r.errorSummary}');
    }
    // Hold the optimistic view until the poll confirms the new mode.
    await _awaitConfirm(() => _iface?.monitor == monitor);
    if (!mounted) return;
    setState(() {
      _busyMode = false;
      _pendingMonitor = null;
      _pendingUp = null;
    });
  }

  Future<void> _toggleLink(bool up) async {
    final iface = _iface;
    if (_busyLink || iface == null || (_pendingUp ?? iface.up) == up) return;
    HapticFeedback.selectionClick();
    setState(() {
      _busyLink = true;
      _pendingUp = up;
    });
    final r = await _iw.setLinkUp(iface: widget.ifaceName, up: up);
    if (mounted && !r.stdout.contains('OK_LINK')) {
      showError(context, "Could not bring the interface ${up ? 'up' : 'down'}.");
    }
    await _awaitConfirm(() => _iface?.up == up);
    if (!mounted) return;
    setState(() {
      _busyLink = false;
      _pendingUp = null;
    });
  }

  Future<void> _applyTxPower(double dbm) async {
    final iface = _iface;
    if (iface == null) return;
    setState(() => _busyTx = true);
    // Tx power only takes with the unrestricted region — set it once, silently.
    if (!_boSet) {
      await _iw.setRegulatoryDomain(kUnrestrictedRegDomain);
      _boSet = true;
    }
    final r = await _iw.setTxPower(iface: widget.ifaceName, dbm: dbm.round());
    if (mounted && !r.stdout.contains('OK_TXPOWER')) {
      showError(context, 'Could not set tx power.');
    }
    if (iface.driver.isNotEmpty) {
      await _iw.recordSetTx(iface.driver, dbm.round()); // remember what we set
    }
    await _load();
    if (!mounted) return;
    setState(() => _busyTx = false);
  }

  @override
  Widget build(BuildContext context) {
    final iface = _iface;
    if (iface == null) {
      // Vanished between builds — _onControllerChanged pops the route on the
      // next notification; this just keeps this one frame from crashing.
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final width = (MediaQuery.sizeOf(context).width * 0.88).clamp(0.0, 380.0);
    final profile = _profile;
    final maxDbm = profile.max.toDouble();
    // Resolve the slider value and stock from the in-memory store synchronously
    // (warmed at startup) so the panel opens straight at the saved value — the
    // async _load then just reconciles, no visible jump.
    final driver = iface.driver;
    final txSlider = (_txSlider ??
            _iw.lastSetTxSync(driver)?.toDouble() ??
            profile.recommended.toDouble())
        .clamp(_kMinTxPowerDbm, maxDbm);
    final stock = _stockTxDbm ?? _iw.stockTxSync(driver);

    return Material(
      color: scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(iface.monitor ? Icons.radar : Icons.wifi,
                      size: 20, color: scheme.primary),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(
                          text: iface.name,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                        if (iface.driver.isNotEmpty)
                          TextSpan(
                            text: '  ·  ${iface.driver}',
                            style: textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  JellyTap(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 32,
                      height: 32,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainerHighest,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.close,
                          size: 18, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _SlidingToggle(
                // Lock both toggles during any action so a mode + link change
                // can't race and fight each other.
                busy: _busyMode || _busyLink,
                selectedIndex: (_pendingMonitor ?? iface.monitor) ? 1 : 0,
                labels: const ['Managed', 'Monitor'],
                icons: const [Icons.wifi, Icons.radar],
                onSelect: (i) => _toggleMode(i == 1),
              ),
              const SizedBox(height: 8),
              _SlidingToggle(
                busy: _busyMode || _busyLink,
                selectedIndex: (_pendingUp ?? iface.up) ? 0 : 1,
                labels: const ['Up', 'Down'],
                icons: const [Icons.power, Icons.power_off],
                onSelect: (i) => _toggleLink(i == 0),
              ),
              // Tx power lives only in Monitor mode (managed is for normal
              // Android Wi-Fi use). Just the slider — the region is handled
              // silently on apply, no region UI.
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: !iface.monitor
                    ? const SizedBox(key: ValueKey('no-tx'), width: double.infinity)
                    : Column(
                        key: const ValueKey('tx'),
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(height: 14),
                          const CardDivider(),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Text('Tx power', style: textTheme.bodyMedium),
                              const SizedBox(width: 8),
                              Text(
                                profile.chip,
                                style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant),
                              ),
                              const Spacer(),
                              Text(
                                '${txSlider.round()} dBm',
                                style: textTheme.bodyMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          IgnorePointer(
                            ignoring: _busyTx,
                            child: Opacity(
                              opacity: _busyTx ? 0.5 : 1,
                              child: _TxSlider(
                                value: txSlider,
                                min: _kMinTxPowerDbm,
                                max: maxDbm,
                                stock: stock?.toDouble(),
                                recommended: profile.recommended.toDouble(),
                                warnAt: (profile.danger + 1).toDouble(),
                                onChanged: (v) => setState(() => _txSlider = v),
                                onChangeEnd: _applyTxPower,
                              ),
                            ),
                          ),
                          // Past the chip's danger threshold the PA overdrives.
                          AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.topCenter,
                            child: txSlider.round() > profile.danger
                                ? Padding(
                                    key: const ValueKey('tx-warn'),
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.warning_amber_rounded,
                                            size: 16, color: scheme.error),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            'Past ${profile.danger} dBm the '
                                            "${profile.chip}'s amplifier "
                                            'overdrives — the signal gets noisy '
                                            '(distortion/EVM, splatter into '
                                            'nearby channels) and range can drop '
                                            'instead of rise. Recommended: '
                                            '${profile.recommended} dBm.',
                                            style: textTheme.bodySmall?.copyWith(
                                                color: scheme.error),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : const SizedBox(
                                    key: ValueKey('tx-nowarn'), width: 0),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A compact two-choice segmented control with a single tablet that *slides*
/// between the options (matching the Wi-Fi hero switch) — Managed/Monitor and
/// Up/Down both use it. The whole control greys out while its action is in
/// flight so a second tap can't stack over the first.
class _SlidingToggle extends StatelessWidget {
  const _SlidingToggle({
    required this.selectedIndex,
    required this.labels,
    required this.icons,
    required this.onSelect,
    required this.busy,
  });

  final int selectedIndex;
  final List<String> labels;
  final List<IconData> icons;
  final ValueChanged<int> onSelect;
  final bool busy;

  static const double _pad = 4;
  static const double _height = 44;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final track = LayoutBuilder(
      builder: (context, constraints) {
        final cellW = (constraints.maxWidth - _pad * 2) / labels.length;
        return Container(
          height: _height,
          padding: const EdgeInsets.all(_pad),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Stack(
            children: [
              // The single sliding tablet.
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                top: 0,
                bottom: 0,
                left: cellW * selectedIndex,
                width: cellW,
                child: JellyStretch(
                  trigger: selectedIndex,
                  amount: 0.12,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: Row(
                  children: [
                    for (var i = 0; i < labels.length; i++)
                      Expanded(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onSelect(i),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                icons[i],
                                size: 16,
                                color: i == selectedIndex
                                    ? scheme.onPrimary
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(width: 7),
                              Text(
                                labels[i],
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: i == selectedIndex
                                      ? scheme.onPrimary
                                      : scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
    return IgnorePointer(
      ignoring: busy,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 160),
        opacity: busy ? 0.5 : 1,
        child: track,
      ),
    );
  }
}

/// A tx-power slider that marks two reference points directly on the track:
/// the adapter's original ("stock") power and the recommended value, so the
/// user can always see — and snap back to — either. Past the recommended
/// ceiling the fill turns to the error colour to reinforce the "too hot" state.
class _TxSlider extends StatelessWidget {
  const _TxSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.stock,
    required this.recommended,
    required this.warnAt,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final double value;
  final double min;
  final double max;
  final double? stock;
  final double recommended;
  final double warnAt;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  static const double _pad = 11; // side inset so the thumb never clips
  static const double _height = 44;

  double _valueForX(double x, double width) {
    final t = ((x - _pad) / (width - 2 * _pad)).clamp(0.0, 1.0);
    return (min + t * (max - min)).roundToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, c) {
        final width = c.maxWidth;
        void drive(double dx) => onChanged(_valueForX(dx, width));
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            HapticFeedback.selectionClick();
            drive(d.localPosition.dx);
          },
          onTapUp: (d) => onChangeEnd(_valueForX(d.localPosition.dx, width)),
          onHorizontalDragStart: (d) => drive(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => drive(d.localPosition.dx),
          onHorizontalDragEnd: (_) => onChangeEnd(value),
          child: SizedBox(
            height: _height,
            width: double.infinity,
            child: CustomPaint(
              painter: _TxSliderPainter(
                value: value,
                min: min,
                max: max,
                stock: stock,
                recommended: recommended,
                warn: value >= warnAt,
                pad: _pad,
                trackColor: scheme.surfaceContainerHighest,
                activeColor: scheme.primary,
                warnColor: scheme.error,
                stockColor: scheme.onSurfaceVariant,
                ringColor: scheme.surfaceContainerHigh,
                labelColor: scheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TxSliderPainter extends CustomPainter {
  _TxSliderPainter({
    required this.value,
    required this.min,
    required this.max,
    required this.stock,
    required this.recommended,
    required this.warn,
    required this.pad,
    required this.trackColor,
    required this.activeColor,
    required this.warnColor,
    required this.stockColor,
    required this.ringColor,
    required this.labelColor,
  });

  final double value, min, max, recommended, pad;
  final double? stock;
  final bool warn;
  final Color trackColor, activeColor, warnColor, stockColor, ringColor, labelColor;

  static const double _trackY = 12;
  static const double _trackH = 5;
  static const double _thumbR = 9;

  @override
  void paint(Canvas canvas, Size size) {
    final left = pad, right = size.width - pad, span = right - left;
    double xFor(double v) => left + ((v - min) / (max - min)) * span;
    final active = warn ? warnColor : activeColor;

    // Background + active fill.
    final bg = Paint()..color = trackColor;
    final rrect = RRect.fromLTRBR(left, _trackY - _trackH / 2, right,
        _trackY + _trackH / 2, const Radius.circular(_trackH / 2));
    canvas.drawRRect(rrect, bg);
    final fillR = RRect.fromLTRBR(left, _trackY - _trackH / 2, xFor(value),
        _trackY + _trackH / 2, const Radius.circular(_trackH / 2));
    canvas.drawRRect(fillR, Paint()..color = active);

    // Reference ticks: stock (neutral) and recommended (accent).
    void tick(double v, Color color) {
      final x = xFor(v);
      final p = Paint()
        ..color = color
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(x, _trackY - 8), Offset(x, _trackY + 8), p);
    }

    void label(double v, String text, Color color) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
              color: color, fontSize: 10.5, fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final x = (xFor(v) - tp.width / 2).clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(x, _trackY + 12));
    }

    if (stock != null) tick(stock!, stockColor);
    tick(recommended, activeColor);
    if (stock != null) label(stock!, 'stock', stockColor);
    label(recommended, 'rec', activeColor);

    // Thumb: an accent disc with a ring so it reads on top of the ticks.
    final cx = xFor(value);
    canvas.drawCircle(Offset(cx, _trackY), _thumbR, Paint()..color = ringColor);
    canvas.drawCircle(Offset(cx, _trackY), _thumbR - 2.5, Paint()..color = active);
  }

  @override
  bool shouldRepaint(_TxSliderPainter old) =>
      old.value != value ||
      old.stock != stock ||
      old.recommended != recommended ||
      old.warn != warn ||
      old.activeColor != activeColor;
}
