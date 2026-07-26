import 'dart:async';

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
  /// Only latched once the region command actually reports success, so a failed
  /// attempt is retried instead of being assumed done.
  bool _boSet = false;

  /// A tx power the user asked for that couldn't be programmed yet because the
  /// radio wasn't on a channel. Re-tried on every scan until it takes — before
  /// this, the value was silently dropped and the only way out was to nudge the
  /// slider again once the interface happened to be tuned.
  int? _pendingTxDbm;

  /// The interface type cfg80211 reports, from the last `iw dev info`. The
  /// mode tablet reflects the netdev's ARPHRD type instead; when the two
  /// disagree the radio is not in the mode everything says it is.
  String? _iwType;

  /// True when sysfs and cfg80211 disagree about the mode — the radio is really
  /// in station mode while the UI (and airmon-style tooling) reads "monitor",
  /// or the reverse. Re-applying the mode is what puts them back in sync.
  bool get _modeDesync {
    final t = _iwType;
    final iface = _iface;
    if (t == null || iface == null) return false;
    if (t != 'monitor' && t != 'managed' && t != 'station') return false;
    return (t == 'monitor') != iface.monitor;
  }

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
    if (_pendingTxDbm != null) unawaited(_retryPendingTx());
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
      _iwType = info?.type;
      _stockTxDbm = stock;
      // Default the slider to the last-set value; failing that, to what the
      // radio actually reports right now, and only then to the recommended one
      // — opening at 24 while the driver sits at 20 just looked like a lie.
      _txSlider ??= (lastSet ?? tx?.round() ?? _profile.recommended)
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
    // Re-read cfg80211's own view so the desync banner reflects the new state.
    await _load();
  }

  /// Re-applies [monitor] through the full down/set-type/up sequence even though
  /// the app already believes the interface is in that mode — that's the point:
  /// it drives cfg80211 back into agreement with the netdev after some other
  /// tool moved only one of them.
  Future<void> _resyncMode(bool monitor) async {
    if (_busyMode) return;
    HapticFeedback.selectionClick();
    setState(() => _busyMode = true);
    final r = await _iw.setMode(iface: widget.ifaceName, monitor: monitor);
    if (mounted && !r.stdout.contains('OK_MODE')) {
      showError(context, 'Could not re-apply the mode: ${r.errorSummary}');
    }
    await widget.controller.refresh();
    if (!mounted) return;
    setState(() => _busyMode = false);
    await _load();
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
    final target = dbm.round();
    // Tx power only takes with the unrestricted region — set it once, silently.
    if (!_boSet) {
      final reg = await _iw.setRegulatoryDomain(kUnrestrictedRegDomain);
      _boSet = reg.stdout.contains('OK_REG');
    }
    final r = await _iw.setTxPower(iface: widget.ifaceName, dbm: target);
    final noChannel = r.stdout.contains(kTxNoChannel);
    _pendingTxDbm = noChannel ? target : null;
    if (mounted && noChannel) {
      showInfo(context, 'Saved — it will be applied as soon as the interface '
          'is up on a channel.');
    } else if (mounted && !r.stdout.contains('OK_TXPOWER')) {
      showError(context, 'Could not set tx power.');
    }
    if (iface.driver.isNotEmpty) {
      await _iw.recordSetTx(iface.driver, target); // remember what we set
    }
    await _load();
    if (!mounted) return;
    setState(() => _busyTx = false);
  }

  /// Retries a tx power that was deferred for want of a channel. Cheap: the
  /// script checks the channel itself and does nothing until there is one.
  Future<void> _retryPendingTx() async {
    final target = _pendingTxDbm;
    if (target == null || _busyTx) return;
    _busyTx = true;
    final r = await _iw.setTxPower(iface: widget.ifaceName, dbm: target);
    if (!mounted) return;
    _busyTx = false;
    if (r.stdout.contains(kTxNoChannel)) return; // still untuned, try again later
    setState(() => _pendingTxDbm = null);
    await _load();
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
              if (_modeDesync) ...[
                const SizedBox(height: 12),
                _ModeDesyncNote(
                  iwType: _iwType!,
                  busy: _busyMode,
                  onFix: () => _resyncMode(iface.monitor),
                ),
              ],
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

/// Shown when cfg80211 and the netdev disagree about the interface mode — the
/// state old nexmon-era tooling leaves behind when it switches modes through
/// the WEXT ioctl. It matters beyond cosmetics: a radio still in station mode
/// can associate, and that path has panicked these drivers.
class _ModeDesyncNote extends StatelessWidget {
  const _ModeDesyncNote({
    required this.iwType,
    required this.busy,
    required this.onFix,
  });

  final String iwType;
  final bool busy;
  final VoidCallback onFix;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: scheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(Icons.sync_problem, size: 20, color: scheme.error),
          const SizedBox(width: 11),
          Expanded(
            child: Text(
              'The radio reports "$iwType" — another tool changed the mode '
              'halfway. Re-apply it to put them back in sync.',
              style: textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurface, height: 1.3),
            ),
          ),
          const SizedBox(width: 6),
          Jelly(child: TextButton(
            onPressed: busy ? null : onFix,
            child: const Text('Fix'),
          )),
        ],
      ),
    );
  }
}
