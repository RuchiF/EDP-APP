import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:industrial_monitoring_dashboard/alert_notification_service.dart';
import 'package:industrial_monitoring_dashboard/devices_catalog.dart';
import 'package:industrial_monitoring_dashboard/ml_predictions_screen.dart';
import 'package:intl/intl.dart';
import 'package:shimmer/shimmer.dart';

/// SnackBars when alerts fire (all platforms; system notifications on mobile).
final GlobalKey<ScaffoldMessengerState> appScaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await AlertNotificationService.init();
  runApp(const IndustrialMonitoringApp());
}

class IndustrialMonitoringApp extends StatefulWidget {
  const IndustrialMonitoringApp({super.key});

  @override
  State<IndustrialMonitoringApp> createState() => _IndustrialMonitoringAppState();
}

class _IndustrialMonitoringAppState extends State<IndustrialMonitoringApp> {
  ThemeMode _themeMode = ThemeMode.dark;

  void _toggleTheme() {
    setState(() {
      _themeMode =
          _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    });
  }

  @override
  Widget build(BuildContext context) {
    const accent = Color(0xFF18B8C8);
    final darkScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    );
    final lightScheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.light,
    );

    return MaterialApp(
      scaffoldMessengerKey: appScaffoldMessengerKey,
      title: 'Industrial Monitoring',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: lightScheme,
        scaffoldBackgroundColor: const Color(0xFFF4F7FB),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 0.5,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFDCE4EE)),
          ),
        ),
      ),
      darkTheme: ThemeData(
        colorScheme: darkScheme,
        scaffoldBackgroundColor: const Color(0xFF0D1117),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 1,
          color: const Color(0xFF151B23),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF232A34)),
          ),
        ),
      ),
      themeMode: _themeMode,
      home: AppShell(
        isDarkMode: _themeMode == ThemeMode.dark,
        onToggleTheme: _toggleTheme,
      ),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.isDarkMode,
    required this.onToggleTheme,
  });

  final bool isDarkMode;
  final VoidCallback onToggleTheme;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const DashboardScreen(),
      const FaultsScreen(),
      const MlPredictionsScreen(),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: pages,
      ),
      floatingActionButton: FloatingActionButton.small(
        tooltip: widget.isDarkMode ? 'Switch to light mode' : 'Switch to dark mode',
        onPressed: widget.onToggleTheme,
        child: Icon(widget.isDarkMode ? Icons.light_mode_rounded : Icons.dark_mode_rounded),
      ),
      bottomNavigationBar: NavigationBar(
        height: 72,
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.dashboard_outlined),
            selectedIcon: Icon(Icons.dashboard_rounded),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.report_problem_outlined),
            selectedIcon: Icon(Icons.report_problem_rounded),
            label: 'Faults',
          ),
          NavigationDestination(
            icon: Icon(Icons.psychology_outlined),
            selectedIcon: Icon(Icons.psychology_rounded),
            label: 'ML',
          ),
        ],
      ),
    );
  }
}

enum HealthStatus { normal, warning, fault }

class SensorReading {
  const SensorReading({
    required this.id,
    required this.temperature,
    required this.accelX,
    required this.accelY,
    required this.accelZ,
    required this.bpfiEnergy,
    required this.bpfoEnergy,
    required this.bsfEnergy,
    required this.ftfEnergy,
    required this.faultScore,
    required this.warnThreshold,
    required this.faultThreshold,
    required this.calibrated,
    required this.tempAlert,
    required this.vibrationAlert,
    required this.rawStatus,
    required this.timestamp,
  });

  final String id;
  final double temperature;
  final double accelX;
  final double accelY;
  final double accelZ;
  final double bpfiEnergy;
  final double bpfoEnergy;
  final double bsfEnergy;
  final double ftfEnergy;
  final double faultScore;
  final double warnThreshold;
  final double faultThreshold;
  final bool calibrated;
  final bool tempAlert;
  final bool vibrationAlert;
  final String rawStatus;
  final DateTime timestamp;

  double get accelMagnitude =>
      math.sqrt(accelX * accelX + accelY * accelY + accelZ * accelZ);

  HealthStatus get status {
    final normalized = rawStatus.toUpperCase();
    if (normalized == 'FAULT') return HealthStatus.fault;
    if (normalized == 'WARNING') return HealthStatus.warning;
    if (faultScore >= faultThreshold) return HealthStatus.fault;
    if (faultScore >= warnThreshold) return HealthStatus.warning;
    return HealthStatus.normal;
  }
}

/// Newest point by [SensorReading.timestamp] (cloud time), not Firestore doc order.
SensorReading newestReading(List<SensorReading> readings) {
  assert(readings.isNotEmpty);
  final sorted = List<SensorReading>.from(readings)
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return sorted.last;
}

Stream<List<SensorReading>> sensorReadingsStream(String deviceId) =>
    FirebaseFirestore.instance
        .collection('devices')
        .doc(deviceId)
        .collection('data')
        .limit(120)
        .snapshots()
        .map((snapshot) {
      final readings = snapshot.docs
          .map((doc) => readingFromMap(doc.id, doc.data()))
          .whereType<SensorReading>()
          .toList();
      readings.sort((a, b) => a.timestamp.compareTo(b.timestamp));

      debugPrint(
        '[Firestore] devices/$deviceId/data loaded: '
        '${readings.length} points (doc ids: ${snapshot.docs.length})',
      );
      for (var i = 0; i < readings.length; i++) {
        final r = readings[i];
        debugPrint(
          '  [$i] temp=${r.temperature.toStringAsFixed(2)} '
          'ax=${r.accelX.toStringAsFixed(3)} ay=${r.accelY.toStringAsFixed(3)} '
          'az=${r.accelZ.toStringAsFixed(3)} '
          'faultScore=${r.faultScore.toStringAsFixed(3)} '
          'ts=${r.timestamp.toIso8601String()}',
        );
      }
      if (readings.isNotEmpty) {
        final newest = newestReading(readings);
        debugPrint(
          '[Firestore] devices/$deviceId newest (by timestamp) → '
          'temp=${newest.temperature.toStringAsFixed(2)} '
          'ax=${newest.accelX.toStringAsFixed(3)} ay=${newest.accelY.toStringAsFixed(3)} az=${newest.accelZ.toStringAsFixed(3)} '
          'faultScore=${newest.faultScore.toStringAsFixed(3)} '
          'ts=${newest.timestamp.toIso8601String()}',
        );
      }

      return readings;
    });

DateTime? _timestampFromDynamic(dynamic timestampValue) {
  if (timestampValue is Timestamp) return timestampValue.toDate();
  if (timestampValue is DateTime) return timestampValue;
  if (timestampValue is num) {
    final value = timestampValue.toDouble();
    if (value > 1000000000000) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt());
    }
    return DateTime.fromMillisecondsSinceEpoch((value * 1000).toInt());
  }
  if (timestampValue is String) {
    final asNum = num.tryParse(timestampValue);
    if (asNum != null) return _timestampFromDynamic(asNum);
    final asDate = DateTime.tryParse(timestampValue);
    if (asDate != null) return asDate;
  }
  return null;
}

SensorReading? readingFromMap(String id, Map<String, dynamic> data) {
  final tempValue = data['temperature'];
  final accelXValue = data['accel_x'];
  final accelYValue = data['accel_y'];
  final accelZValue = data['accel_z'];
  final bpfiEnergyValue = data['bpfi_energy'];
  final bpfoEnergyValue = data['bpfo_energy'];
  final bsfEnergyValue = data['bsf_energy'];
  final ftfEnergyValue = data['ftf_energy'] ?? data['fft_energy'];
  final faultScoreValue = data['fault_score'];
  final warnThresholdValue = data['warn_threshold'];
  final faultThresholdValue = data['fault_threshold'];
  final calibratedValue = data['calibrated'];
  final tempAlertValue = data['temp_alert'];
  final vibrationAlertValue = data['vibration'];
  final statusValue = data['status'];
  final timestampValue = data['timestamp'] ?? data['timesp'] ?? data['time'];

  if (tempValue == null ||
      accelXValue == null ||
      accelYValue == null ||
      accelZValue == null ||
      timestampValue == null) {
    return null;
  }

  final temperature = sensorToDouble(tempValue);
  final accelX = sensorToDouble(accelXValue);
  final accelY = sensorToDouble(accelYValue);
  final accelZ = sensorToDouble(accelZValue);
  if (temperature == null || accelX == null || accelY == null || accelZ == null) {
    return null;
  }
  final timestamp = _timestampFromDynamic(timestampValue);
  if (timestamp == null) {
    return null;
  }

  return SensorReading(
    id: id,
    temperature: temperature,
    accelX: accelX,
    accelY: accelY,
    accelZ: accelZ,
    bpfiEnergy: sensorToDouble(bpfiEnergyValue) ?? 0,
    bpfoEnergy: sensorToDouble(bpfoEnergyValue) ?? 0,
    bsfEnergy: sensorToDouble(bsfEnergyValue) ?? 0,
    ftfEnergy: sensorToDouble(ftfEnergyValue) ?? 0,
    faultScore: sensorToDouble(faultScoreValue) ?? 0,
    warnThreshold: sensorToDouble(warnThresholdValue) ?? 0.98,
    faultThreshold: sensorToDouble(faultThresholdValue) ?? 1.24,
    calibrated: sensorToBool(calibratedValue),
    tempAlert: sensorToBool(tempAlertValue),
    vibrationAlert: sensorToBool(vibrationAlertValue),
    rawStatus: (statusValue ?? 'NORMAL').toString(),
    timestamp: timestamp,
  );
}

double? sensorToDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1.0 : 0.0;
  if (value is String) return double.tryParse(value);
  return null;
}

bool sensorToBool(dynamic value) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.toLowerCase();
    return normalized == 'true' || normalized == '1' || normalized == 'yes';
  }
  return false;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String? _selectedDeviceId;
  String? _alertTrackingDeviceId;
  DateTime? _lastNotifiedTimestamp;

  void _processAlertNotifications(String deviceId, String deviceLabel, SensorReading latest) {
    if (!mounted) return;
    if (_alertTrackingDeviceId != deviceId) {
      _alertTrackingDeviceId = deviceId;
      _lastNotifiedTimestamp = null;
    }
    if (_lastNotifiedTimestamp == latest.timestamp) return;
    _lastNotifiedTimestamp = latest.timestamp;

    if (latest.status == HealthStatus.fault) {
      unawaited(
        AlertNotificationService.showVibrationAlert(
          deviceLabel,
          'Fault status detected. Score ${latest.faultScore.toStringAsFixed(3)} '
          '(threshold ${latest.faultThreshold.toStringAsFixed(3)}).',
        ),
      );
    } else if (latest.tempAlert || latest.vibrationAlert) {
      unawaited(
        AlertNotificationService.showTemperatureAlert(
          deviceLabel,
          'Warning indicators raised (temperature/vibration). '
          'Score ${latest.faultScore.toStringAsFixed(3)}.',
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final spacing = MediaQuery.sizeOf(context).width > 700 ? 24.0 : 18.0;

    return SafeArea(
      child: StreamBuilder<List<Device>>(
        stream: devicesStream(),
        builder: (context, deviceSnapshot) {
          if (deviceSnapshot.connectionState == ConnectionState.waiting) {
            return _DashboardLoading(spacing: spacing);
          }

          if (deviceSnapshot.hasError) {
            return _DashboardError(
              message: 'Unable to load devices from Firestore.',
            );
          }

          final devices = deviceSnapshot.data ?? const <Device>[];
          if (devices.isEmpty) {
            return const _EmptyDataState(
              title: 'No devices found',
              message: 'Add documents under "devices" in Firestore.',
            );
          }

          if (_selectedDeviceId == null ||
              devices.every((d) => d.id != _selectedDeviceId)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              setState(() => _selectedDeviceId = devices.first.id);
            });
            return _DashboardLoading(spacing: spacing);
          }

          final selectedIndex =
              devices.indexWhere((device) => device.id == _selectedDeviceId);
          final selectedDevice = devices[selectedIndex];

          return StreamBuilder<List<SensorReading>>(
            stream: sensorReadingsStream(selectedDevice.id),
            builder: (context, readingSnapshot) {
              if (readingSnapshot.connectionState == ConnectionState.waiting) {
                return _DashboardLoading(spacing: spacing);
              }
              if (readingSnapshot.hasError) {
                return _DashboardError(
                  message:
                      'Unable to load sensor data for ${selectedDevice.label}.\n${readingSnapshot.error}',
                );
              }

              final readings = readingSnapshot.data ?? const <SensorReading>[];
              if (readings.isEmpty) {
                return ListView(
                  padding: EdgeInsets.all(spacing),
                  children: [
                    const _Header(
                      title: 'Industrial Monitoring',
                      subtitle: 'Live overview of machine health',
                    ),
                    const SizedBox(height: 14),
                    DeviceSelector(
                      devices: devices,
                      selectedIndex: selectedIndex,
                      onSelected: (index) =>
                          setState(() => _selectedDeviceId = devices[index].id),
                    ),
                    const SizedBox(height: 18),
                    const _EmptyDataState(
                      title: 'No sensor records found',
                      message:
                          'Insert documents in devices/<device>/data with temperature, humidity, vibration, timestamp.',
                    ),
                  ],
                );
              }

              final latest = newestReading(readings);
              final status = latest.status;
              final accelXSpots = _toSpots(readings.map((r) => r.accelX).toList());
              final accelYSpots = _toSpots(readings.map((r) => r.accelY).toList());
              final accelZSpots = _toSpots(readings.map((r) => r.accelZ).toList());
              final bpfiSpots = _toSpots(readings.map((r) => r.bpfiEnergy).toList());
              final bpfoSpots = _toSpots(readings.map((r) => r.bpfoEnergy).toList());
              final bsfSpots = _toSpots(readings.map((r) => r.bsfEnergy).toList());
              final ftfSpots = _toSpots(readings.map((r) => r.ftfEnergy).toList());
              final scoreSpots = _toSpots(readings.map((r) => r.faultScore).toList());
              final labels = _timeLabels(readings);
              final vibrationRange = _axisRange(
                [
                  ...readings.map((r) => r.accelX),
                  ...readings.map((r) => r.accelY),
                  ...readings.map((r) => r.accelZ),
                ],
                minSpan: 0.5,
              );
              final energyRange = _axisRange(
                [
                  ...readings.map((r) => r.bpfiEnergy),
                  ...readings.map((r) => r.bpfoEnergy),
                  ...readings.map((r) => r.bsfEnergy),
                  ...readings.map((r) => r.ftfEnergy),
                ],
                minSpan: 0.2,
              );
              final faultRange = _axisRange(
                [
                  ...readings.map((r) => r.faultScore),
                  latest.warnThreshold,
                  latest.faultThreshold,
                ],
                minFloor: 0,
                minSpan: 0.5,
              );

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                _processAlertNotifications(selectedDevice.id, selectedDevice.label, latest);
              });

              return ListView(
                padding: EdgeInsets.all(spacing),
                children: [
                  const _Header(
                    title: 'Industrial Monitoring',
                    subtitle: 'Live overview of machine health',
                  ),
                  const SizedBox(height: 14),
                  DeviceSelector(
                    devices: devices,
                    selectedIndex: selectedIndex,
                    onSelected: (index) =>
                        setState(() => _selectedDeviceId = devices[index].id),
                  ),
                  const SizedBox(height: 14),
                  StatusBadge(status: status),
                  const SizedBox(height: 18),
                  _MetricsGrid(reading: latest, spacing: spacing),
                  const SizedBox(height: 18),
                  _DashboardAnalyticsTabs(
                    deviceLabel: selectedDevice.label,
                    latest: latest,
                    readings: readings,
                    labels: labels,
                    vibrationRange: vibrationRange,
                    energyRange: energyRange,
                    faultRange: faultRange,
                    accelXSpots: accelXSpots,
                    accelYSpots: accelYSpots,
                    accelZSpots: accelZSpots,
                    bpfiSpots: bpfiSpots,
                    bpfoSpots: bpfoSpots,
                    bsfSpots: bsfSpots,
                    ftfSpots: ftfSpots,
                    scoreSpots: scoreSpots,
                    warnLine: _constantLine(latest.warnThreshold, readings.length),
                    faultLine: _constantLine(latest.faultThreshold, readings.length),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  List<FlSpot> _toSpots(List<double> values) {
    return values
        .asMap()
        .entries
        .map((entry) => FlSpot(entry.key.toDouble(), entry.value))
        .toList(growable: false);
  }

  List<FlSpot> _constantLine(double value, int count) {
    return List<FlSpot>.generate(
      count,
      (idx) => FlSpot(idx.toDouble(), value),
      growable: false,
    );
  }

  List<String> _timeLabels(List<SensorReading> readings) {
    return readings
        .map((r) => DateFormat('HH:mm:ss').format(r.timestamp))
        .toList(growable: false);
  }

  _AxisRange _axisRange(
    Iterable<double> values, {
    double? minFloor,
    double minSpan = 1,
  }) {
    final list = values.toList(growable: false);
    if (list.isEmpty) return const _AxisRange(min: 0, max: 1);
    var min = list.reduce(math.min);
    var max = list.reduce(math.max);
    if (minFloor != null && min > minFloor) min = minFloor;
    if ((max - min).abs() < minSpan) {
      final center = (max + min) / 2;
      min = center - (minSpan / 2);
      max = center + (minSpan / 2);
    }
    final padding = (max - min) * 0.12;
    return _AxisRange(min: min - padding, max: max + padding);
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
        ),
      ],
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.reading, required this.spacing});

  final SensorReading reading;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurface.withValues(alpha: 0.72);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                'Latest cloud sample',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            Text(
              DateFormat('yyyy-MM-dd HH:mm:ss').format(reading.timestamp),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: muted,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final twoColumns = constraints.maxWidth > 620;
            final cards = [
              MetricCard(
                label: 'Temperature',
                value: '${reading.temperature.toStringAsFixed(2)} °C',
                icon: Icons.thermostat_rounded,
                accent: const Color(0xFF3B82F6),
              ),
              MetricCard(
                label: 'Fault score',
                value: reading.faultScore.toStringAsFixed(4),
                icon: Icons.graphic_eq_rounded,
                accent: const Color(0xFFEF4444),
              ),
              MetricCard(
                label: 'Accel magnitude',
                value: '${reading.accelMagnitude.toStringAsFixed(3)} g',
                icon: Icons.vibration_rounded,
                accent: const Color(0xFF18B8C8),
              ),
            ];

            if (!twoColumns) {
              return Column(
                children: cards
                    .map(
                      (card) => Padding(
                        padding: EdgeInsets.only(bottom: spacing),
                        child: card,
                      ),
                    )
                    .toList(),
              );
            }

            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: cards
                  .map(
                    (card) => SizedBox(
                      width: (constraints.maxWidth - spacing) / 2,
                      child: card,
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.accent,
  });

  final String label;
  final String value;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: accent),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
                  const SizedBox(height: 6),
                  Text(
                    value,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
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

class _LineSeries {
  const _LineSeries({
    required this.name,
    required this.color,
    required this.spots,
  });

  final String name;
  final Color color;
  final List<FlSpot> spots;
}

class _AxisRange {
  const _AxisRange({required this.min, required this.max});

  final double min;
  final double max;
}

class _MultiLineChartCard extends StatelessWidget {
  const _MultiLineChartCard({
    required this.title,
    required this.series,
    required this.labels,
    this.minY,
    this.maxY,
  });

  final String title;
  final List<_LineSeries> series;
  final List<String> labels;
  final double? minY;
  final double? maxY;

  @override
  Widget build(BuildContext context) {
    final maxX = labels.isEmpty ? 0.0 : (labels.length - 1).toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: series
                  .map((s) => Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(width: 10, height: 10, decoration: BoxDecoration(color: s.color, shape: BoxShape.circle)),
                          const SizedBox(width: 6),
                          Text(s.name, style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ))
                  .toList(),
            ),
            const SizedBox(height: 14),
            SizedBox(
              height: 280,
              child: LineChart(
                LineChartData(
                  minY: minY,
                  maxY: maxY,
                  minX: 0,
                  maxX: maxX,
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (items) {
                        return items.map((item) {
                          final idx = item.x.toInt().clamp(0, labels.length - 1);
                          return LineTooltipItem(
                            '${series[item.barIndex].name}: ${item.y.toStringAsFixed(3)}\n${labels[idx]}',
                            TextStyle(color: series[item.barIndex].color, fontWeight: FontWeight.w600),
                          );
                        }).toList();
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 38)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 34,
                        interval: labels.length <= 1
                            ? 1
                            : ((labels.length - 1) / 3).toDouble(),
                        getTitlesWidget: (value, _) {
                          if (labels.isEmpty) return const SizedBox.shrink();
                          final idx = value.toInt().clamp(0, labels.length - 1);
                          final keyTicks = {
                            0,
                            labels.length ~/ 3,
                            (labels.length * 2) ~/ 3,
                            labels.length - 1,
                          };
                          if (!keyTicks.contains(idx)) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(labels[idx], style: const TextStyle(fontSize: 10)),
                          );
                        },
                      ),
                    ),
                  ),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (_) => const FlLine(color: Color(0xFF2A3340), strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: series
                      .map(
                        (s) => LineChartBarData(
                          spots: s.spots,
                          isCurved: false,
                          color: s.color,
                          barWidth: 2.3,
                          dotData: const FlDotData(show: false),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardAnalyticsTabs extends StatelessWidget {
  const _DashboardAnalyticsTabs({
    required this.deviceLabel,
    required this.latest,
    required this.readings,
    required this.labels,
    required this.vibrationRange,
    required this.energyRange,
    required this.faultRange,
    required this.accelXSpots,
    required this.accelYSpots,
    required this.accelZSpots,
    required this.bpfiSpots,
    required this.bpfoSpots,
    required this.bsfSpots,
    required this.ftfSpots,
    required this.scoreSpots,
    required this.warnLine,
    required this.faultLine,
  });

  final String deviceLabel;
  final SensorReading latest;
  final List<SensorReading> readings;
  final List<String> labels;
  final _AxisRange vibrationRange;
  final _AxisRange energyRange;
  final _AxisRange faultRange;
  final List<FlSpot> accelXSpots;
  final List<FlSpot> accelYSpots;
  final List<FlSpot> accelZSpots;
  final List<FlSpot> bpfiSpots;
  final List<FlSpot> bpfoSpots;
  final List<FlSpot> bsfSpots;
  final List<FlSpot> ftfSpots;
  final List<FlSpot> scoreSpots;
  final List<FlSpot> warnLine;
  final List<FlSpot> faultLine;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Analytics',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 10),
              TabBar(
                tabAlignment: TabAlignment.start,
                isScrollable: true,
                tabs: const [
                  Tab(text: 'Overview'),
                  Tab(text: 'Vibration'),
                  Tab(text: 'Energy'),
                  Tab(text: 'Fault & Alerts'),
                ],
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 500,
                child: TabBarView(
                  children: [
                    ListView(
                      children: [
                        _MiniInfoCard(latest: latest),
                        const SizedBox(height: 12),
                        _MultiLineChartCard(
                          title: 'Fault Score Trend',
                          labels: labels,
                          minY: faultRange.min,
                          maxY: faultRange.max,
                          series: [
                            _LineSeries(
                              name: 'Fault score',
                              color: const Color(0xFFEF4444),
                              spots: scoreSpots,
                            ),
                          ],
                        ),
                      ],
                    ),
                    _MultiLineChartCard(
                      title: 'Vibration by Axis (g)',
                      labels: labels,
                      minY: vibrationRange.min,
                      maxY: vibrationRange.max,
                      series: [
                        _LineSeries(name: 'X axis', color: const Color(0xFF18B8C8), spots: accelXSpots),
                        _LineSeries(name: 'Y axis', color: const Color(0xFFEAB308), spots: accelYSpots),
                        _LineSeries(name: 'Z axis', color: const Color(0xFF3B82F6), spots: accelZSpots),
                      ],
                    ),
                    _MultiLineChartCard(
                      title: 'Bearing Energy Bands (a.u.)',
                      labels: labels,
                      minY: energyRange.min,
                      maxY: energyRange.max,
                      series: [
                        _LineSeries(name: 'BPFI', color: const Color(0xFF14B8A6), spots: bpfiSpots),
                        _LineSeries(name: 'BPFO', color: const Color(0xFF06B6D4), spots: bpfoSpots),
                        _LineSeries(name: 'BSF', color: const Color(0xFF6366F1), spots: bsfSpots),
                        _LineSeries(name: 'FTF', color: const Color(0xFFEC4899), spots: ftfSpots),
                      ],
                    ),
                    ListView(
                      children: [
                        _MultiLineChartCard(
                          title: 'Fault Score vs Thresholds',
                          labels: labels,
                          minY: faultRange.min,
                          maxY: faultRange.max,
                          series: [
                            _LineSeries(name: 'Fault score', color: const Color(0xFFEF4444), spots: scoreSpots),
                            _LineSeries(name: 'Warn threshold', color: const Color(0xFFEAB308), spots: warnLine),
                            _LineSeries(name: 'Fault threshold', color: const Color(0xFFDC2626), spots: faultLine),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _FaultHistoryCard(deviceLabel: deviceLabel, readings: readings),
                      ],
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

class _MiniInfoCard extends StatelessWidget {
  const _MiniInfoCard({required this.latest});

  final SensorReading latest;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Latest Snapshot',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            const SizedBox(height: 8),
            Text('Timestamp: ${DateFormat('yyyy-MM-dd HH:mm:ss').format(latest.timestamp)}'),
            const SizedBox(height: 4),
            Text('Temperature: ${latest.temperature.toStringAsFixed(2)} °C'),
            const SizedBox(height: 4),
            Text('Fault score: ${latest.faultScore.toStringAsFixed(4)}'),
          ],
        ),
      ),
    );
  }
}

class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.status});

  final HealthStatus status;

  Color get color {
    switch (status) {
      case HealthStatus.normal:
        return const Color(0xFF22C55E);
      case HealthStatus.warning:
        return const Color(0xFFEAB308);
      case HealthStatus.fault:
        return const Color(0xFFEF4444);
    }
  }

  String get label {
    switch (status) {
      case HealthStatus.normal:
        return 'NORMAL';
      case HealthStatus.warning:
        return 'WARNING';
      case HealthStatus.fault:
        return 'FAULT';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 10, color: color),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(fontWeight: FontWeight.w700, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardLoading extends StatelessWidget {
  const _DashboardLoading({required this.spacing});

  final double spacing;

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xFF1C2430),
      highlightColor: const Color(0xFF2A3544),
      child: ListView(
        padding: EdgeInsets.all(spacing),
        children: [
          Container(height: 28, width: 180, color: Colors.white),
          const SizedBox(height: 8),
          Container(height: 16, width: 240, color: Colors.white),
          const SizedBox(height: 16),
          Container(height: 88, color: Colors.white),
          const SizedBox(height: 16),
          Container(height: 42, width: 120, color: Colors.white),
          const SizedBox(height: 16),
          ...List.generate(
            3,
            (_) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Container(height: 84, color: Colors.white),
            ),
          ),
          Container(height: 220, color: Colors.white),
          const SizedBox(height: 16),
          Container(height: 220, color: Colors.white),
        ],
      ),
    );
  }
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, size: 42),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyDataState extends StatelessWidget {
  const _EmptyDataState({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 14),
        child: Column(
          children: [
            const Icon(Icons.inbox_rounded, size: 36),
            const SizedBox(height: 10),
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class AlertEntry {
  const AlertEntry({
    required this.title,
    required this.deviceId,
    required this.timestamp,
    required this.status,
    required this.message,
  });

  final String title;
  final String deviceId;
  final DateTime timestamp;
  final HealthStatus status;
  final String message;
}

List<AlertEntry> liveAlertsFromReadings(
  String deviceLabel,
  List<SensorReading> readings,
) {
  if (readings.isEmpty) return const [];

  final latest = newestReading(readings);
  final out = <AlertEntry>[];
  if (latest.status == HealthStatus.fault) {
    out.add(
      AlertEntry(
        title: 'Fault status',
        deviceId: deviceLabel,
        timestamp: latest.timestamp,
        status: HealthStatus.fault,
        message:
            'Fault score ${latest.faultScore.toStringAsFixed(4)} is above fault threshold ${latest.faultThreshold.toStringAsFixed(4)}.',
      ),
    );
  } else if (latest.status == HealthStatus.warning) {
    out.add(
      AlertEntry(
        title: 'Warning status',
        deviceId: deviceLabel,
        timestamp: latest.timestamp,
        status: HealthStatus.warning,
        message:
            'Fault score ${latest.faultScore.toStringAsFixed(4)} is above warning threshold ${latest.warnThreshold.toStringAsFixed(4)}.',
      ),
    );
  }
  if (latest.tempAlert) {
    out.add(
      AlertEntry(
        title: 'Temperature alert',
        deviceId: deviceLabel,
        timestamp: latest.timestamp,
        status: HealthStatus.warning,
        message: 'Temperature alert flag is active (${latest.temperature.toStringAsFixed(2)} °C).',
      ),
    );
  }
  if (latest.vibrationAlert) {
    out.add(
      AlertEntry(
        title: 'Vibration alert',
        deviceId: deviceLabel,
        timestamp: latest.timestamp,
        status: HealthStatus.warning,
        message:
            'Vibration alert flag is active. Axes: X=${latest.accelX.toStringAsFixed(3)} g, Y=${latest.accelY.toStringAsFixed(3)} g, Z=${latest.accelZ.toStringAsFixed(3)} g.',
      ),
    );
  }

  return out;
}

class _FaultHistoryCard extends StatelessWidget {
  const _FaultHistoryCard({required this.deviceLabel, required this.readings});

  final String deviceLabel;
  final List<SensorReading> readings;

  @override
  Widget build(BuildContext context) {
    final events = readings.where((r) => r.status != HealthStatus.normal || r.tempAlert || r.vibrationAlert).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Fault History & Alerts', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            if (events.isEmpty)
              const Text('No warning/fault events in the loaded window.')
            else
              ...events.take(12).map((event) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _HistoryRow(deviceLabel: deviceLabel, reading: event),
                  )),
          ],
        ),
      ),
    );
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.deviceLabel, required this.reading});

  final String deviceLabel;
  final SensorReading reading;

  @override
  Widget build(BuildContext context) {
    final color = switch (reading.status) {
      HealthStatus.normal => const Color(0xFF22C55E),
      HealthStatus.warning => const Color(0xFFEAB308),
      HealthStatus.fault => const Color(0xFFEF4444),
    };
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
        color: color.withValues(alpha: 0.1),
      ),
      child: Row(
        children: [
          Icon(Icons.timeline_rounded, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${reading.status.name.toUpperCase()} • score ${reading.faultScore.toStringAsFixed(4)} '
              '• ${DateFormat('yyyy-MM-dd HH:mm:ss').format(reading.timestamp)} '
              '• $deviceLabel'
              '${reading.tempAlert ? ' • Temp alert' : ''}'
              '${reading.vibrationAlert ? ' • Vib alert' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: StreamBuilder<List<Device>>(
        stream: devicesStream(),
        builder: (context, deviceSnapshot) {
          if (deviceSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (deviceSnapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Unable to load devices.\n${deviceSnapshot.error}'),
              ),
            );
          }

          final devices = deviceSnapshot.data ?? const <Device>[];
          if (devices.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: const [
                _Header(
                  title: 'Alerts & Fault History',
                  subtitle: 'Live rules from Firestore',
                ),
                SizedBox(height: 16),
                _EmptyAlertsState(),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const _Header(
                title: 'Alerts & Fault History',
                subtitle:
                    'Chart window: any sample with vibration > 0 or temperature ≥ 25 °C',
              ),
              const SizedBox(height: 16),
              ...devices.map(
                (d) => _DeviceLiveAlertsSection(device: d),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'If nothing appears above, no sample in the loaded window exceeded the thresholds.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DeviceLiveAlertsSection extends StatelessWidget {
  const _DeviceLiveAlertsSection({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SensorReading>>(
      stream: sensorReadingsStream(device.id),
      builder: (context, readingSnapshot) {
        if (readingSnapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        if (readingSnapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '${device.label}: ${readingSnapshot.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        }

        final readings = readingSnapshot.data ?? const <SensorReading>[];
        if (readings.isEmpty) {
          return const SizedBox.shrink();
        }

        final entries = liveAlertsFromReadings(device.label, readings);
        if (entries.isEmpty) {
          return const SizedBox.shrink();
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: _AlertGroup(title: 'Live • ${device.label}', entries: entries),
        );
      },
    );
  }
}

class _AlertGroup extends StatelessWidget {
  const _AlertGroup({required this.title, required this.entries});

  final String title;
  final List<AlertEntry> entries;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            ...entries.map((entry) => _AlertRow(entry: entry)),
          ],
        ),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.entry});

  final AlertEntry entry;

  Color get severityColor {
    switch (entry.status) {
      case HealthStatus.normal:
        return const Color(0xFF22C55E);
      case HealthStatus.warning:
        return const Color(0xFFEAB308);
      case HealthStatus.fault:
        return const Color(0xFFEF4444);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF111821) : const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDark ? const Color(0xFF27313E) : const Color(0xFFD8E1EC),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: severityColor.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.notification_important, color: severityColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
                const SizedBox(height: 4),
                Text(
                  entry.message,
                  style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7)),
                ),
                const SizedBox(height: 6),
                Text(
                  '${entry.deviceId} • ${DateFormat('dd MMM, HH:mm').format(entry.timestamp)}',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyAlertsState extends StatelessWidget {
  const _EmptyAlertsState();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 14),
        child: Column(
          children: [
            Icon(Icons.inbox_rounded, size: 36, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5)),
            const SizedBox(height: 10),
            const Text('No alerts available', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(
              'The selected devices are operating within normal ranges.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dedicated Faults screen – detailed drilldown for every warning/fault reading.
class FaultsScreen extends StatelessWidget {
  const FaultsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.6);

    return SafeArea(
      child: StreamBuilder<List<Device>>(
        stream: devicesStream(),
        builder: (context, deviceSnapshot) {
          if (deviceSnapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (deviceSnapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Unable to load devices.\n${deviceSnapshot.error}'),
              ),
            );
          }

          final devices = deviceSnapshot.data ?? const <Device>[];
          if (devices.isEmpty) {
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _Header(
                  title: 'Fault Details',
                  subtitle: 'Detailed breakdown of every fault and warning event',
                ),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 14),
                    child: Column(
                      children: [
                        Icon(Icons.verified_user_rounded, size: 42, color: muted),
                        const SizedBox(height: 10),
                        const Text('No devices found', style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                          'Add devices in Firestore to see fault details.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: muted),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          }

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const _Header(
                title: 'Fault Details',
                subtitle: 'Detailed breakdown of every fault and warning event',
              ),
              const SizedBox(height: 20),
              ...devices.map((d) => _DeviceFaultDetailSection(device: d)),
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 20),
                child: Text(
                  'Showing up to 120 samples per device from the loaded window.',
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DeviceFaultDetailSection extends StatelessWidget {
  const _DeviceFaultDetailSection({required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<SensorReading>>(
      stream: sensorReadingsStream(device.id),
      builder: (context, readingSnapshot) {
        if (readingSnapshot.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: LinearProgressIndicator(minHeight: 2),
          );
        }
        if (readingSnapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              '${device.label}: ${readingSnapshot.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          );
        }

        final readings = readingSnapshot.data ?? const <SensorReading>[];
        final faultEvents = readings
            .where((r) => r.status != HealthStatus.normal || r.tempAlert || r.vibrationAlert)
            .toList()
          ..sort((a, b) => b.timestamp.compareTo(a.timestamp));

        if (faultEvents.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Icon(Icons.precision_manufacturing_rounded,
                        size: 20, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text(
                      device.label,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                      ),
                      child: Text(
                        '${faultEvents.length} event${faultEvents.length == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
              ...faultEvents.take(20).map((reading) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _FaultDetailCard(deviceLabel: device.label, reading: reading),
                  )),
            ],
          ),
        );
      },
    );
  }
}

class _FaultDetailCard extends StatelessWidget {
  const _FaultDetailCard({required this.deviceLabel, required this.reading});

  final String deviceLabel;
  final SensorReading reading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final statusColor = switch (reading.status) {
      HealthStatus.normal => const Color(0xFF22C55E),
      HealthStatus.warning => const Color(0xFFEAB308),
      HealthStatus.fault => const Color(0xFFEF4444),
    };
    final muted = theme.colorScheme.onSurface.withValues(alpha: 0.55);
    final subtleBorder = isDark ? const Color(0xFF232A34) : const Color(0xFFDCE4EE);

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
            // Header row: status badge + timestamp
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.circle, size: 8, color: statusColor),
                      const SizedBox(width: 6),
                      Text(
                        reading.status.name.toUpperCase(),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          color: statusColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Icon(Icons.schedule_rounded, size: 14, color: muted),
                const SizedBox(width: 4),
                Text(
                  DateFormat('dd MMM yyyy, HH:mm:ss').format(reading.timestamp),
                  style: theme.textTheme.labelSmall?.copyWith(
                        color: muted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            // Metrics grid
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isDark ? const Color(0xFF111821) : const Color(0xFFF4F7FB),
                border: Border.all(color: subtleBorder),
              ),
              child: Column(
                children: [
                  _FaultMetricRow(
                    icon: Icons.graphic_eq_rounded,
                    label: 'Fault Score',
                    value: reading.faultScore.toStringAsFixed(4),
                    accent: const Color(0xFFEF4444),
                  ),
                  const SizedBox(height: 8),
                  _FaultMetricRow(
                    icon: Icons.warning_amber_rounded,
                    label: 'Warn Threshold',
                    value: reading.warnThreshold.toStringAsFixed(4),
                    accent: const Color(0xFFEAB308),
                  ),
                  const SizedBox(height: 8),
                  _FaultMetricRow(
                    icon: Icons.error_outline_rounded,
                    label: 'Fault Threshold',
                    value: reading.faultThreshold.toStringAsFixed(4),
                    accent: const Color(0xFFDC2626),
                  ),
                  const Divider(height: 20),
                  _FaultMetricRow(
                    icon: Icons.thermostat_rounded,
                    label: 'Temperature',
                    value: '${reading.temperature.toStringAsFixed(2)} °C',
                    accent: const Color(0xFF3B82F6),
                  ),
                  const SizedBox(height: 8),
                  _FaultMetricRow(
                    icon: Icons.vibration_rounded,
                    label: 'Accel (X / Y / Z)',
                    value:
                        '${reading.accelX.toStringAsFixed(3)} / ${reading.accelY.toStringAsFixed(3)} / ${reading.accelZ.toStringAsFixed(3)} g',
                    accent: const Color(0xFF18B8C8),
                  ),
                  const SizedBox(height: 8),
                  _FaultMetricRow(
                    icon: Icons.speed_rounded,
                    label: 'Accel Magnitude',
                    value: '${reading.accelMagnitude.toStringAsFixed(3)} g',
                    accent: const Color(0xFF8B5CF6),
                  ),
                ],
              ),
            ),
            // Alert flags
            if (reading.tempAlert || reading.vibrationAlert) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  if (reading.tempAlert)
                    _AlertFlagChip(
                      label: 'Temp Alert',
                      icon: Icons.thermostat_auto_rounded,
                      color: const Color(0xFFF97316),
                    ),
                  if (reading.vibrationAlert)
                    _AlertFlagChip(
                      label: 'Vibration Alert',
                      icon: Icons.vibration_rounded,
                      color: const Color(0xFFEC4899),
                    ),
                ],
              ),
            ],
            // Energy bands
            if (reading.bpfiEnergy > 0 || reading.bpfoEnergy > 0 || reading.bsfEnergy > 0 || reading.ftfEnergy > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: isDark ? const Color(0xFF0D1117) : const Color(0xFFF8FAFC),
                  border: Border.all(color: subtleBorder),
                ),
                child: Row(
                  children: [
                    Icon(Icons.bar_chart_rounded, size: 16, color: muted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'BPFI: ${reading.bpfiEnergy.toStringAsFixed(4)}  •  '
                        'BPFO: ${reading.bpfoEnergy.toStringAsFixed(4)}  •  '
                        'BSF: ${reading.bsfEnergy.toStringAsFixed(4)}  •  '
                        'FTF: ${reading.ftfEnergy.toStringAsFixed(4)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                              color: muted,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FaultMetricRow extends StatelessWidget {
  const _FaultMetricRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: accent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
                ),
          ),
        ),
        Text(
          value,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
        ),
      ],
    );
  }
}

class _AlertFlagChip extends StatelessWidget {
  const _AlertFlagChip({
    required this.label,
    required this.icon,
    required this.color,
  });

  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    return const FirebaseOptions(
      apiKey: 'AIzaSyBtOPwjBVuFuDDhUNnMbCCs45hLT6c2Vvc',
      appId: '1:743963434125:web:f841e9edeebd8aa9b156c4',
      messagingSenderId: '743963434125',
      projectId: 'thermo-vibro-monitor',
      storageBucket: 'thermo-vibro-monitor.firebasestorage.app',
      authDomain: 'thermo-vibro-monitor.firebaseapp.com',
      measurementId: 'G-0FSH56XP4R',
    );
  }
}
