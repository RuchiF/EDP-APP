import 'package:flutter/material.dart';
import 'package:industrial_monitoring_dashboard/devices_catalog.dart';
import 'package:industrial_monitoring_dashboard/ml_api_client.dart';
import 'package:industrial_monitoring_dashboard/ml_api_config.dart';
import 'package:intl/intl.dart';

/// Third bottom-nav destination: Bearing Fault Prediction API (FastAPI deployment).
class MlPredictionsScreen extends StatefulWidget {
  const MlPredictionsScreen({super.key});

  @override
  State<MlPredictionsScreen> createState() => _MlPredictionsScreenState();
}

class _MlPredictionsScreenState extends State<MlPredictionsScreen> {
  late final TextEditingController _baseUrlController;
  late final MlApiClient _client;

  bool _loadingMeta = false;
  bool _loadingPredict = false;
  String? _metaError;
  String? _predictError;

  MlHealthResponse? _health;
  MlModelInfoResponse? _modelInfo;
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
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshMeta());
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _refreshMeta() async {
    setState(() {
      _loadingMeta = true;
      _metaError = null;
    });
    try {
      final health = await _client.health(_apiBase);
      final info = await _client.modelInfo(_apiBase);
      if (!mounted) return;
      setState(() {
        _health = health;
        _modelInfo = info;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _health = null;
        _modelInfo = null;
        _metaError = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loadingMeta = false);
    }
  }

  Future<void> _runPrediction({String? machineId}) async {
    setState(() {
      _loadingPredict = true;
      _predictError = null;
    });
    try {
      final prediction = await _client.predict(_apiBase, machineId: machineId);
      if (!mounted) return;
      setState(() => _prediction = prediction);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _prediction = null;
        _predictError = e.toString();
      });
    } finally {
      if (mounted) setState(() => _loadingPredict = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final spacing = MediaQuery.sizeOf(context).width > 700 ? 24.0 : 16.0;
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72);

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

          return ListView(
            padding: EdgeInsets.all(spacing),
            children: [
              Text(
                'ML Predictions',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                'Calls your deployed predictor: health, model metadata, and /predict.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: muted),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _baseUrlController,
                onSubmitted: (_) => _refreshMeta(),
                decoration: InputDecoration(
                  labelText: 'API base URL',
                  hintText: 'https://your-api.example.com',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    tooltip: 'Reload health & model info',
                    onPressed: _loadingMeta ? null : _refreshMeta,
                    icon: _loadingMeta
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                  ),
                ),
                keyboardType: TextInputType.url,
                autocorrect: false,
              ),
              const SizedBox(height: 12),
              if (devices.isNotEmpty) ...[
                Text(
                  'Optional: machine_id for API query',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 8),
                DeviceSelector(
                  devices: devices,
                  selectedIndex: selectedIndex >= 0 ? selectedIndex : 0,
                  onSelected: (index) {
                    setState(() => _selectedDeviceId = devices[index].id);
                  },
                ),
                const SizedBox(height: 12),
              ],
              FilledButton.icon(
                onPressed: _loadingPredict
                    ? null
                    : () => _runPrediction(machineId: selectedDevice?.id),
                icon: _loadingPredict
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_graph_rounded),
                label: Text(_loadingPredict ? 'Predicting…' : 'Run prediction'),
              ),
              const SizedBox(height: 22),
              if (_metaError != null)
                _ErrorBanner(message: _metaError!)
              else ...[
                if (_loadingMeta && _health == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_health != null) ...[
                  _HealthCard(health: _health!),
                  const SizedBox(height: 14),
                  if (_modelInfo != null) _ModelInfoCard(info: _modelInfo!),
                ],
              ],
              const SizedBox(height: 14),
              Text(
                'Latest prediction',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 10),
              if (_predictError != null)
                _ErrorBanner(message: _predictError!)
              else if (_prediction != null)
                _PredictionCard(prediction: _prediction!)
              else
                Text(
                  'Tap “Run prediction” after the API URL is reachable.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final err = Theme.of(context).colorScheme.error;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: err),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: err),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthCard extends StatelessWidget {
  const _HealthCard({required this.health});

  final MlHealthResponse health;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Service health',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            _StatusChip(
              label: 'Status: ${health.status}',
              ok: health.status.toLowerCase() == 'healthy',
            ),
            const SizedBox(height: 8),
            Text(
              'Model loaded: ${health.modelLoaded ? 'yes' : 'no'}\n'
              'Firestore connected: ${health.firestoreConnected ? 'yes' : 'no'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
            ),
            if (health.timestamp != null) ...[
              const SizedBox(height: 6),
              Text(
                'Reported at: ${health.timestamp}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.ok});

  final String label;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final color = ok ? const Color(0xFF22C55E) : const Color(0xFFEF4444);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: color)),
    );
  }
}

class _ModelInfoCard extends StatelessWidget {
  const _ModelInfoCard({required this.info});

  final MlModelInfoResponse info;

  @override
  Widget build(BuildContext context) {
    final pct = NumberFormat.percentPattern();
    pct.maximumFractionDigits = 2;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Model info',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 12),
            _ModelInfoRow(label: 'Name', value: info.modelName),
            _ModelInfoRow(label: 'Balanced accuracy', value: pct.format(info.balancedAccuracy)),
            _ModelInfoRow(label: 'F1 score', value: pct.format(info.f1Score)),
            _ModelInfoRow(label: 'Features', value: '${info.nFeatures}'),
            _ModelInfoRow(label: 'Window (hours)', value: '${info.windowHours}'),
            _ModelInfoRow(label: 'Classes', value: info.classes.join(', ')),
            if (info.trainingDate != null && info.trainingDate!.isNotEmpty)
              _ModelInfoRow(label: 'Training date', value: info.trainingDate!),
          ],
        ),
      ),
    );
  }
}

class _ModelInfoRow extends StatelessWidget {
  const _ModelInfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
          ),
          Expanded(child: Text(value, style: Theme.of(context).textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

class _PredictionCard extends StatelessWidget {
  const _PredictionCard({required this.prediction});

  final MlPredictResponse prediction;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72);
    final isHigh =
        prediction.prediction.toUpperCase().contains('HIGH') || prediction.prediction == 'HIGH_RISK';
    final accent = isHigh ? const Color(0xFFEF4444) : const Color(0xFF22C55E);

    final probaSorted = prediction.probabilities.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    prediction.prediction.replaceAll('_', ' '),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                          color: accent,
                        ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: accent.withValues(alpha: 0.12),
                  ),
                  child: Text(
                    '${(prediction.confidence * 100).toStringAsFixed(1)}% conf.',
                    style: TextStyle(fontWeight: FontWeight.w700, color: accent),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Class probabilities', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...probaSorted.map((e) => _ProbabilityBar(label: e.key.replaceAll('_', ' '), value: e.value)),
            const SizedBox(height: 12),
            Text(
              'Inputs: ${prediction.rawReadingsFetched} readings · '
              '${prediction.windowHoursUsed} h window'
              '${prediction.timestamp != null ? '\nServer time: ${prediction.timestamp}' : ''}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProbabilityBar extends StatelessWidget {
  const _ProbabilityBar({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(
                value.toStringAsFixed(4),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }
}
