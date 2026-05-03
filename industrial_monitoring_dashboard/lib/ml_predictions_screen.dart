import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:industrial_monitoring_dashboard/devices_catalog.dart';
import 'package:industrial_monitoring_dashboard/ml_api_client.dart';
import 'package:industrial_monitoring_dashboard/ml_api_config.dart';
import 'package:intl/intl.dart';

/// Bearing-risk prediction UI (calls `/predict` only).
class MlPredictionsScreen extends StatefulWidget {
  const MlPredictionsScreen({super.key});

  static const Color _accent = Color(0xFF18B8C8);

  @override
  State<MlPredictionsScreen> createState() => _MlPredictionsScreenState();
}

class _MlPredictionsScreenState extends State<MlPredictionsScreen>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _baseUrlController;
  late final MlApiClient _client;
  late final AnimationController _pulse;

  bool _loading = false;
  String? _error;
  MlPredictResponse? _prediction;

  String? _selectedDeviceId;

  String get _apiBase => _baseUrlController.text.trim().isEmpty
      ? MlApiConfig.embeddedBaseUrl
      : _baseUrlController.text.trim();

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController(text: MlApiConfig.embeddedBaseUrl.trim());
    _client = MlApiClient();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _client.close();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _runPrediction({String? machineId}) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prediction = await _client.predict(_apiBase, machineId: machineId);
      if (!mounted) return;
      setState(() => _prediction = prediction);
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _prediction = null;
        _error = e.toString();
      });
      HapticFeedback.heavyImpact();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final w = MediaQuery.sizeOf(context).width;
    final pad = w > 700 ? 28.0 : 20.0;

    final bgTop = Color.lerp(theme.scaffoldBackgroundColor, MlPredictionsScreen._accent, isDark ? 0.07 : 0.045)!;

    return SafeArea(
      child: StreamBuilder<List<Device>>(
        stream: devicesStream(),
        builder: (context, deviceSnapshot) {
          final devices = deviceSnapshot.data ?? const <Device>[];
          if (devices.isNotEmpty &&
              (_selectedDeviceId == null || devices.every((d) => d.id != _selectedDeviceId))) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _selectedDeviceId = devices.first.id);
            });
          }

          final selectedIndex = _selectedDeviceId == null
              ? -1
              : devices.indexWhere((d) => d.id == _selectedDeviceId);
          final selectedDevice = selectedIndex >= 0 ? devices[selectedIndex] : null;

          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  bgTop,
                  theme.scaffoldBackgroundColor,
                  theme.scaffoldBackgroundColor,
                ],
                stops: const [0.0, 0.32, 1.0],
              ),
            ),
            child: CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(pad, pad, pad, 32),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate([
                      _MlScreenHeader(isDark: isDark),
                      const SizedBox(height: 22),
                      _ApiUrlField(
                        controller: _baseUrlController,
                        isDark: isDark,
                      ),
                      if (devices.isNotEmpty) ...[
                        const SizedBox(height: 20),
                        Text(
                          'Machine',
                          style: theme.textTheme.labelLarge?.copyWith(
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 10),
                        DeviceSelector(
                          devices: devices,
                          selectedIndex: selectedIndex >= 0 ? selectedIndex : 0,
                          onSelected: (i) =>
                              setState(() => _selectedDeviceId = devices[i].id),
                        ),
                      ],
                      const SizedBox(height: 26),
                      _PredictCta(
                        loading: _loading,
                        pulse: _pulse,
                        onPressed: _loading ? null : () => _runPrediction(machineId: selectedDevice?.id),
                      ),
                      const SizedBox(height: 30),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 340),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        child: _error != null
                            ? _ErrorPanel(key: const ValueKey('err'), message: _error!)
                            : _prediction != null
                                ? _PredictionShowcase(
                                    key: ValueKey(_prediction!.timestamp ?? _prediction!.prediction),
                                    prediction: _prediction!,
                                    isDark: isDark,
                                  )
                                : _EmptyState(key: const ValueKey('empty'), isDark: isDark),
                      ),
                      const SizedBox(height: 96),
                    ]),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MlScreenHeader extends StatelessWidget {
  const _MlScreenHeader({required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                MlPredictionsScreen._accent.withValues(alpha: isDark ? 0.42 : 0.22),
                MlPredictionsScreen._accent.withValues(alpha: 0.06),
              ],
            ),
            border: Border.all(color: MlPredictionsScreen._accent.withValues(alpha: 0.4)),
            boxShadow: [
              BoxShadow(
                color: MlPredictionsScreen._accent.withValues(alpha: isDark ? 0.25 : 0.12),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: const Icon(Icons.insights_rounded, color: MlPredictionsScreen._accent, size: 28),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Bearing risk',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                      height: 1.12,
                    ),
              ),
              const SizedBox(height: 6),
              Text(
                'One tap for a fresh risk readout from your API.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: muted,
                      height: 1.38,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ApiUrlField extends StatelessWidget {
  const _ApiUrlField({required this.controller, required this.isDark});

  final TextEditingController controller;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final outline = Theme.of(context).colorScheme.outline.withValues(alpha: isDark ? 0.38 : 0.22);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: Theme.of(context).colorScheme.surface.withValues(alpha: isDark ? 0.5 : 0.92),
        border: Border.all(color: outline),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(19),
        child: TextField(
          controller: controller,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Prediction API URL',
            border: InputBorder.none,
            prefixIcon: Icon(
              Icons.hub_rounded,
              color: MlPredictionsScreen._accent.withValues(alpha: 0.95),
              size: 24,
            ),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
            hintStyle: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
            ),
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
          textInputAction: TextInputAction.done,
        ),
      ),
    );
  }
}

class _PredictCta extends StatelessWidget {
  const _PredictCta({
    required this.loading,
    required this.pulse,
    required this.onPressed,
  });

  final bool loading;
  final Animation<double> pulse;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final breathe = loading ? 0.0 : 0.5 + pulse.value * 0.14;
        return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(999),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: LinearGradient(
                  colors: onPressed != null
                      ? [
                          MlPredictionsScreen._accent,
                          Color.lerp(MlPredictionsScreen._accent, const Color(0xFF0891B2), breathe)!,
                        ]
                      : [
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                        ],
                ),
                boxShadow: onPressed != null
                    ? [
                        BoxShadow(
                          color: MlPredictionsScreen._accent.withValues(alpha: 0.35 + breathe * 0.12),
                          blurRadius: 22 + breathe * 8,
                          offset: const Offset(0, 12),
                        ),
                      ]
                    : null,
              ),
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.6,
                          color: Colors.white,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.bolt_rounded, color: Colors.white, size: 24),
                          const SizedBox(width: 10),
                          Text(
                            'Get prediction',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.2,
                                ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({super.key, required this.isDark});

  final bool isDark;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55);

    return Column(
      children: [
        Container(
          width: 120,
          height: 120,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: MlPredictionsScreen._accent.withValues(alpha: 0.18),
              width: 2,
            ),
            gradient: RadialGradient(
              colors: [
                MlPredictionsScreen._accent.withValues(alpha: isDark ? 0.12 : 0.08),
                Colors.transparent,
              ],
            ),
          ),
          child: Icon(
            Icons.show_chart_rounded,
            size: 48,
            color: MlPredictionsScreen._accent.withValues(alpha: 0.45),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Ready when you are',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            'Your latest LOW / HIGH risk call will land here with confidence and split.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted, height: 1.45),
          ),
        ),
      ],
    );
  }
}

class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: err.withValues(alpha: 0.1),
        border: Border.all(color: err.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.wifi_tethering_error_rounded, color: err, size: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: err,
                    height: 1.4,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PredictionShowcase extends StatelessWidget {
  const _PredictionShowcase({
    super.key,
    required this.prediction,
    required this.isDark,
  });

  final MlPredictResponse prediction;
  final bool isDark;

  static bool _isHighRisk(String p) {
    final u = p.toUpperCase();
    return u.contains('HIGH') || u == 'HIGH_RISK';
  }

  @override
  Widget build(BuildContext context) {
    final high = _isHighRisk(prediction.prediction);
    final riskColor = high ? const Color(0xFFFB7185) : const Color(0xFF4ADE80);
    final riskGlow = high ? const Color(0xFFEF4444) : const Color(0xFF22C55E);
    final label = prediction.prediction.replaceAll('_', ' ').toUpperCase();

    double pickProb(bool wantHigh) {
      final directLow = prediction.probabilities['LOW_RISK'];
      final directHigh = prediction.probabilities['HIGH_RISK'];
      if (!wantHigh && directLow != null) return directLow;
      if (wantHigh && directHigh != null) return directHigh;
      for (final e in prediction.probabilities.entries) {
        final k = e.key.toUpperCase();
        if (wantHigh && k.contains('HIGH')) return e.value;
        if (!wantHigh && k.contains('LOW')) return e.value;
      }
      return 0;
    }

    final lowP = pickProb(false);
    final highP = pickProb(true);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 12 * (1 - t)),
            child: child,
          ),
        );
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(22, 24, 22, 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.surface.withValues(alpha: isDark ? 0.85 : 0.98),
              Theme.of(context).colorScheme.surface.withValues(alpha: isDark ? 0.55 : 0.92),
            ],
          ),
          border: Border.all(
            color: riskColor.withValues(alpha: 0.45),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: riskGlow.withValues(alpha: isDark ? 0.22 : 0.14),
              blurRadius: 32,
              spreadRadius: -4,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Current assessment',
                        style: Theme.of(context).textTheme.labelMedium?.copyWith(
                              letterSpacing: 1.1,
                              fontWeight: FontWeight.w700,
                              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
                            ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        label,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.8,
                              color: riskColor,
                              height: 1.05,
                            ),
                      ),
                    ],
                  ),
                ),
                _ConfidenceRing(confidence: prediction.confidence, accent: riskColor),
              ],
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: _ProbPill(
                    label: 'Low risk',
                    value: lowP,
                    active: !high,
                    color: const Color(0xFF22C55E),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ProbPill(
                    label: 'High risk',
                    value: highP,
                    active: high,
                    color: const Color(0xFFEF4444),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Text(
              '${prediction.rawReadingsFetched} samples · '
              '${prediction.windowHoursUsed}h window · '
              'updated ${_formatTimestamp(prediction.timestamp)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.45),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTimestamp(String? iso) {
    if (iso == null || iso.isEmpty) return 'just now';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return 'just now';
    return DateFormat('HH:mm').format(dt.toLocal());
  }
}

class _ConfidenceRing extends StatelessWidget {
  const _ConfidenceRing({required this.confidence, required this.accent});

  final double confidence;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final pct = (confidence.clamp(0.0, 1.0) * 100).round();

    return SizedBox(
      width: 86,
      height: 86,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 86,
            height: 86,
            child: CircularProgressIndicator(
              value: confidence.clamp(0.0, 1.0),
              strokeWidth: 5,
              backgroundColor: accent.withValues(alpha: 0.15),
              color: accent,
              strokeCap: StrokeCap.round,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$pct%',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      height: 1,
                    ),
              ),
              Text(
                'conf.',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ProbPill extends StatelessWidget {
  const _ProbPill({
    required this.label,
    required this.value,
    required this.active,
    required this.color,
  });

  final String label;
  final double value;
  final bool active;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: color.withValues(alpha: active ? 0.18 : 0.06),
        border: Border.all(
          color: color.withValues(alpha: active ? 0.55 : 0.15),
          width: active ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
          ),
          const SizedBox(height: 4),
          Text(
            '${(value * 100).toStringAsFixed(1)}%',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: color.withValues(alpha: 0.12),
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
