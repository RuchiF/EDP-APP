import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:industrial_monitoring_dashboard/devices_catalog.dart';
import 'package:industrial_monitoring_dashboard/ml_api_client.dart';
import 'package:industrial_monitoring_dashboard/ml_api_config.dart';
import 'package:intl/intl.dart';

/// Bearing-risk prediction UI (calls `/predict` only).
/// Styled to match Dashboard & Faults screens.
class MlPredictionsScreen extends StatefulWidget {
  const MlPredictionsScreen({super.key});

  @override
  State<MlPredictionsScreen> createState() => _MlPredictionsScreenState();
}

class _MlPredictionsScreenState extends State<MlPredictionsScreen> {
  late final TextEditingController _baseUrlController;
  late final MlApiClient _client;

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
    _baseUrlController =
        TextEditingController(text: MlApiConfig.embeddedBaseUrl.trim());
    _client = MlApiClient();
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _runPrediction({String? machineId}) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final prediction =
          await _client.predict(_apiBase, machineId: machineId);
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
    final spacing = MediaQuery.sizeOf(context).width > 700 ? 24.0 : 18.0;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return SafeArea(
      child: StreamBuilder<List<Device>>(
        stream: devicesStream(),
        builder: (context, deviceSnapshot) {
          final devices = deviceSnapshot.data ?? const <Device>[];
          if (devices.isNotEmpty &&
              (_selectedDeviceId == null ||
                  devices.every((d) => d.id != _selectedDeviceId))) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _selectedDeviceId = devices.first.id);
            });
          }

          final selectedIndex = _selectedDeviceId == null
              ? -1
              : devices.indexWhere((d) => d.id == _selectedDeviceId);
          final selectedDevice =
              selectedIndex >= 0 ? devices[selectedIndex] : null;

          return ListView(
            padding: EdgeInsets.all(spacing),
            children: [
              // ── Header (same style as Dashboard / Faults) ──
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ML Predictions',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Bearing risk assessment from deployed model',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: muted),
                  ),
                ],
              ),
              const SizedBox(height: 18),

              // ── API URL Card ──
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'API Endpoint',
                        style: theme.textTheme.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _baseUrlController,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Prediction API URL',
                          prefixIcon: Icon(
                            Icons.hub_rounded,
                            color: theme.colorScheme.primary,
                            size: 22,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isDark
                                  ? const Color(0xFF232A34)
                                  : const Color(0xFFDCE4EE),
                            ),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                              color: isDark
                                  ? const Color(0xFF232A34)
                                  : const Color(0xFFDCE4EE),
                            ),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 14),
                          hintStyle: TextStyle(color: muted),
                        ),
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        textInputAction: TextInputAction.done,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // ── Device selector ──
              if (devices.isNotEmpty) ...[
                Text(
                  'Machine',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                DeviceSelector(
                  devices: devices,
                  selectedIndex: selectedIndex >= 0 ? selectedIndex : 0,
                  onSelected: (i) =>
                      setState(() => _selectedDeviceId = devices[i].id),
                ),
                const SizedBox(height: 18),
              ],

              // ── Predict button ──
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _loading
                      ? null
                      : () =>
                          _runPrediction(machineId: selectedDevice?.id),
                  icon: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.bolt_rounded),
                  label: Text(
                    _loading ? 'Running...' : 'Get prediction',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),

              // ── Result area ──
              if (_error != null)
                _ErrorCard(message: _error!)
              else if (_prediction != null)
                _PredictionResultCard(
                  prediction: _prediction!,
                  isDark: isDark,
                )
              else
                _EmptyResultCard(muted: muted),
            ],
          );
        },
      ),
    );
  }
}

// ── Empty state ──────────────────────────────────────────────────
class _EmptyResultCard extends StatelessWidget {
  const _EmptyResultCard({required this.muted});

  final Color muted;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 14),
        child: Column(
          children: [
            Icon(Icons.show_chart_rounded, size: 40, color: muted),
            const SizedBox(height: 12),
            Text(
              'No prediction yet',
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Tap "Get prediction" to fetch a risk assessment from your API.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: muted, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Error card ───────────────────────────────────────────────────
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: err.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: err.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.wifi_tethering_error_rounded,
                  color: err, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Prediction failed',
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: err),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    message,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: err.withValues(alpha: 0.85),
                          height: 1.4,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Prediction result card ───────────────────────────────────────
class _PredictionResultCard extends StatelessWidget {
  const _PredictionResultCard({
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
    final theme = Theme.of(context);
    final high = _isHighRisk(prediction.prediction);
    final statusColor =
        high ? const Color(0xFFEF4444) : const Color(0xFF22C55E);
    final label =
        prediction.prediction.replaceAll('_', ' ').toUpperCase();
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final subtleBorder =
        isDark ? const Color(0xFF232A34) : const Color(0xFFDCE4EE);

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
    final confidence = prediction.confidence;
    final confPct = (confidence.clamp(0.0, 1.0) * 100).round();

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: statusColor.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Text(
              'Prediction Result',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),

            // Status badge + confidence
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                        color: statusColor.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, size: 10, color: statusColor),
                      const SizedBox(width: 8),
                      Text(
                        label,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  '$confPct% confidence',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Probability details
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isDark
                    ? const Color(0xFF111821)
                    : const Color(0xFFF4F7FB),
                border: Border.all(color: subtleBorder),
              ),
              child: Column(
                children: [
                  _ProbRow(
                    label: 'Low Risk',
                    value: lowP,
                    color: const Color(0xFF22C55E),
                    active: !high,
                  ),
                  const SizedBox(height: 10),
                  _ProbRow(
                    label: 'High Risk',
                    value: highP,
                    color: const Color(0xFFEF4444),
                    active: high,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Meta info
            Row(
              children: [
                Icon(Icons.data_usage_rounded, size: 14, color: muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${prediction.rawReadingsFetched} samples · '
                    '${prediction.windowHoursUsed}h window · '
                    'updated ${_formatTimestamp(prediction.timestamp)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: muted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
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

// ── Probability row ──────────────────────────────────────────────
class _ProbRow extends StatelessWidget {
  const _ProbRow({
    required this.label,
    required this.value,
    required this.color,
    required this.active,
  });

  final String label;
  final double value;
  final Color color;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(
          active ? Icons.check_circle_rounded : Icons.circle_outlined,
          size: 16,
          color: color,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              fontWeight: active ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
        ),
        SizedBox(
          width: 100,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: color.withValues(alpha: 0.12),
              color: color,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          '${(value * 100).toStringAsFixed(1)}%',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: active ? color : null,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
