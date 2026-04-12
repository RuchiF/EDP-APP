import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:industrial_monitoring_dashboard/alert_notification_service.dart';
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
      const AlertsScreen(),
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
            icon: Icon(Icons.warning_amber_outlined),
            selectedIcon: Icon(Icons.warning_amber_rounded),
            label: 'Alerts',
          ),
        ],
      ),
    );
  }
}

enum HealthStatus { normal, warning, fault }

class Device {
  const Device({required this.id, required this.label});

  final String id;
  final String label;
}

class SensorReading {
  const SensorReading({
    required this.temperature,
    required this.humidity,
    required this.vibration,
    required this.timestamp,
  });

  final double temperature;
  final double humidity;
  final double vibration;
  final DateTime timestamp;
}

/// Newest point by [SensorReading.timestamp] (cloud time), not Firestore doc order.
SensorReading newestReading(List<SensorReading> readings) {
  assert(readings.isNotEmpty);
  final sorted = List<SensorReading>.from(readings)
    ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
  return sorted.last;
}

/// Live alert rules (adjust thresholds here).
bool vibrationAlertActive(double vibrationMmS) => vibrationMmS > 0;

bool temperatureAlertActive(double tempC) => tempC >= 25.0;

/// Default gap between points if timestamps are missing or irregular.
const double _kDefaultSecondsPerDataPoint = 2.0;

double _estimatedSecondsPerDataPoint(List<SensorReading> readings) {
  if (readings.length < 2) return _kDefaultSecondsPerDataPoint;
  final deltas = <double>[];
  for (var i = 1; i < readings.length; i++) {
    final sec = readings[i]
        .timestamp
        .difference(readings[i - 1].timestamp)
        .inSeconds
        .abs()
        .toDouble();
    if (sec > 0) deltas.add(sec);
  }
  if (deltas.isEmpty) return _kDefaultSecondsPerDataPoint;
  final mean = deltas.reduce((a, b) => a + b) / deltas.length;
  if (mean < 0.5 || mean > 86400) return _kDefaultSecondsPerDataPoint;
  return mean;
}

/// 1 = newest sample, 3 = third-from-newest, etc.
String _ordinalFromLatest(int k) {
  return k == 1 ? '1 data point from latest' : '$k data points from latest';
}

String _formatRoughAgo(double seconds) {
  if (seconds < 55) {
    return '~${seconds.round()}s ago';
  }
  if (seconds < 3540) {
    final m = (seconds / 60).round();
    return '~${m}m ago';
  }
  if (seconds < 86400) {
    final h = (seconds / 3600).round();
    return '~${h}h ago';
  }
  final d = (seconds / 86400).round();
  return '~${d}d ago';
}

Stream<List<Device>> devicesStream() => FirebaseFirestore.instance
    .collection('devices')
    .snapshots()
    .map(
      (snapshot) {
        final list = snapshot.docs
            .map((doc) => Device(id: doc.id, label: doc.id.toUpperCase()))
            .toList(growable: false);
        debugPrint(
          '[Firestore] devices loaded: count=${list.length} '
          'ids=[${list.map((d) => d.id).join(', ')}]',
        );
        return list;
      },
    );

Stream<List<SensorReading>> sensorReadingsStream(String deviceId) =>
    FirebaseFirestore.instance
        .collection('devices')
        .doc(deviceId)
        .collection('data')
        .limit(120)
        .snapshots()
        .map((snapshot) {
      final readings = snapshot.docs
          .map((doc) => readingFromMap(doc.data()))
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
          'hum=${r.humidity.toStringAsFixed(1)} '
          'vib=${r.vibration.toStringAsFixed(3)} '
          'ts=${r.timestamp.toIso8601String()}',
        );
      }
      if (readings.isNotEmpty) {
        final newest = newestReading(readings);
        debugPrint(
          '[Firestore] devices/$deviceId newest (by timestamp) → '
          'temp=${newest.temperature.toStringAsFixed(2)} '
          'hum=${newest.humidity.toStringAsFixed(1)} '
          'vib=${newest.vibration.toStringAsFixed(3)} '
          'ts=${newest.timestamp.toIso8601String()}',
        );
      }

      return readings;
    });

SensorReading? readingFromMap(Map<String, dynamic> data) {
  final tempValue = data['temperature'];
  final humidityValue = data['humidity'];
  final vibrationValue = data['vibration'];
  final timestampValue = data['timestamp'] ?? data['timesp'] ?? data['time'];

  if (tempValue == null || vibrationValue == null || timestampValue == null) {
    return null;
  }

  final temperature = sensorToDouble(tempValue);
  final humidity = sensorToDouble(humidityValue) ?? 0.0;
  final vibration = sensorToDouble(vibrationValue);
  if (temperature == null || vibration == null) {
    return null;
  }

  DateTime timestamp;
  if (timestampValue is Timestamp) {
    timestamp = timestampValue.toDate();
  } else if (timestampValue is num) {
    timestamp = DateTime.fromMillisecondsSinceEpoch(
      (timestampValue * 1000).toInt(),
    );
  } else if (timestampValue is String) {
    final parsed = num.tryParse(timestampValue);
    if (parsed == null) return null;
    timestamp = DateTime.fromMillisecondsSinceEpoch((parsed * 1000).toInt());
  } else {
    return null;
  }

  return SensorReading(
    temperature: temperature,
    humidity: humidity,
    vibration: vibration,
    timestamp: timestamp,
  );
}

double? sensorToDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is bool) return value ? 1.0 : 0.0;
  if (value is String) return double.tryParse(value);
  return null;
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  String? _selectedDeviceId;
  String? _alertTrackingDeviceId;
  bool _prevHadVibrationAlert = false;
  bool _prevHadTemperatureAlert = false;

  void _processAlertNotifications(
    String deviceId,
    String deviceLabel,
    List<SensorReading> readings,
  ) {
    if (!mounted) return;
    if (_alertTrackingDeviceId != deviceId) {
      _alertTrackingDeviceId = deviceId;
      _prevHadVibrationAlert = false;
      _prevHadTemperatureAlert = false;
    }

    final entries = liveAlertsFromReadings(deviceLabel, readings);
    final hasVib = entries.any((e) => e.title == 'Vibration alert');
    final hasTemp = entries.any((e) => e.title == 'Temperature alert');

    if (hasVib && !_prevHadVibrationAlert) {
      final msg =
          entries.firstWhere((e) => e.title == 'Vibration alert').message;
      unawaited(AlertNotificationService.showVibrationAlert(deviceLabel, msg));
      appScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Vibration alert — $deviceLabel'),
          duration: const Duration(seconds: 6),
        ),
      );
    }

    if (hasTemp && !_prevHadTemperatureAlert) {
      final msg =
          entries.firstWhere((e) => e.title == 'Temperature alert').message;
      unawaited(AlertNotificationService.showTemperatureAlert(deviceLabel, msg));
      appScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text('Temperature alert — $deviceLabel'),
          duration: const Duration(seconds: 6),
        ),
      );
    }

    _prevHadVibrationAlert = hasVib;
    _prevHadTemperatureAlert = hasTemp;
  }

  HealthStatus _statusFromReadings(double vibration, double temp) {
    if (vibration > 3.5 || temp > 85) return HealthStatus.fault;
    if (vibration > 2.5 || temp > 70) return HealthStatus.warning;
    return HealthStatus.normal;
  }

  /// Uses peak vibration/temperature in the loaded window so status matches the chart.
  HealthStatus _statusFromReadingsList(List<SensorReading> readings) {
    if (readings.isEmpty) return HealthStatus.normal;
    final maxVibration = readings
        .map((r) => r.vibration)
        .reduce((a, b) => a > b ? a : b);
    final maxTemp = readings
        .map((r) => r.temperature)
        .reduce((a, b) => a > b ? a : b);
    return _statusFromReadings(maxVibration, maxTemp);
  }

  @override
  Widget build(BuildContext context) {
    final spacing = MediaQuery.sizeOf(context).width > 700 ? 20.0 : 14.0;

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
              final status = _statusFromReadingsList(readings);
              final vibrationSpots = _toSpots(
                readings.map((r) => r.vibration).toList(),
              );
              final temperatureSpots = _toSpots(
                readings.map((r) => r.temperature).toList(),
              );

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!context.mounted) return;
                _processAlertNotifications(
                  selectedDevice.id,
                  selectedDevice.label,
                  readings,
                );
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
                  const SizedBox(height: 14),
                  _LiveThresholdAlerts(
                    deviceLabel: selectedDevice.label,
                    readings: readings,
                  ),
                  const SizedBox(height: 14),
                  _MetricsGrid(reading: latest, spacing: spacing),
                  const SizedBox(height: 14),
                  _ChartCard(
                    title: 'Vibration Trend (mm/s)',
                    color: const Color(0xFF18B8C8),
                    spots: vibrationSpots,
                    minY: 0,
                    maxY: 5,
                  ),
                  const SizedBox(height: 14),
                  _ChartCard(
                    title: 'Temperature Trend (°C)',
                    color: const Color(0xFF3B82F6),
                    spots: temperatureSpots,
                    minY: 0,
                    maxY: 120,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Charts use the loaded window; values in cards are the newest cloud point above.',
                    style: Theme.of(context).textTheme.bodySmall,
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
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
        ),
      ],
    );
  }
}

class DeviceSelector extends StatelessWidget {
  const DeviceSelector({
    super.key,
    required this.devices,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<Device> devices;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return SizedBox(
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemBuilder: (context, index) {
          final device = devices[index];
          final selected = index == selectedIndex;
          return GestureDetector(
            onTap: () => onSelected(index),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 185,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: selected
                    ? const Color(0x3320C5D6)
                    : isDark
                        ? const Color(0xFF151B23)
                        : Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: selected ? const Color(0xFF1FC9DA) : const Color(0xFF2A3340),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    device.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    device.id.toUpperCase(),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
          );
        },
        separatorBuilder: (_, _) => const SizedBox(width: 12),
        itemCount: devices.length,
      ),
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
                label: 'Humidity',
                value: '${reading.humidity.toStringAsFixed(0)} %',
                icon: Icons.water_drop_rounded,
                accent: const Color(0xFF18B8C8),
              ),
              MetricCard(
                label: 'Vibration',
                value: '${reading.vibration.toStringAsFixed(2)} mm/s',
                icon: Icons.graphic_eq_rounded,
                accent: const Color(0xFFEAB308),
              ),
              MetricCard(
                label: 'Temperature',
                value: '${reading.temperature.toStringAsFixed(1)} °C',
                icon: Icons.thermostat_rounded,
                accent: const Color(0xFF3B82F6),
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
                  Text(label, style: const TextStyle(color: Colors.white70)),
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

class _ChartCard extends StatelessWidget {
  const _ChartCard({
    required this.title,
    required this.color,
    required this.spots,
    required this.minY,
    required this.maxY,
  });

  final String title;
  final Color color;
  final List<FlSpot> spots;
  final double minY;
  final double maxY;

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
            SizedBox(
              height: 210,
              child: LineChart(
                LineChartData(
                  minY: minY,
                  maxY: maxY,
                  lineTouchData: const LineTouchData(enabled: true),
                  titlesData: const FlTitlesData(
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: true, reservedSize: 36),
                    ),
                    rightTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: (maxY - minY) / 4,
                    getDrawingHorizontalLine: (_) => const FlLine(
                      color: Color(0xFF2A3340),
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      // Straight segments: curved splines can overshoot and show
                      // fake peaks (e.g. near 1.0) while every sample is 0.
                      isCurved: false,
                      color: color,
                      barWidth: 2.4,
                      belowBarData: BarAreaData(
                        show: true,
                        color: color.withValues(alpha: 0.17),
                      ),
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                ),
              ),
            ),
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

/// Alerts use the **loaded chart window** (not only the latest point), so past
/// spikes still show after the current sample returns to zero.
List<AlertEntry> liveAlertsFromReadings(
  String deviceLabel,
  List<SensorReading> readings,
) {
  if (readings.isEmpty) return const [];

  final latest = newestReading(readings);
  final out = <AlertEntry>[];

  final peakVib = readings.reduce(
    (a, b) => a.vibration >= b.vibration ? a : b,
  );
  if (readings.any((r) => vibrationAlertActive(r.vibration))) {
    SensorReading? lastHitFromNewest;
    var kFromLatest = 0;
    for (var i = readings.length - 1; i >= 0; i--) {
      if (vibrationAlertActive(readings[i].vibration)) {
        lastHitFromNewest = readings[i];
        kFromLatest = readings.length - i;
        break;
      }
    }
    final secPerPoint = _estimatedSecondsPerDataPoint(readings);
    final estSecondsAgo = kFromLatest * secPerPoint;
    final vibMsg = lastHitFromNewest != null
        ? '${lastHitFromNewest.vibration.toStringAsFixed(2)} mm/s — '
            '${_ordinalFromLatest(kFromLatest)} : '
            '${_formatRoughAgo(estSecondsAgo)} '
            '(≈${secPerPoint.toStringAsFixed(1)}s per point). '
            'Current ${latest.vibration.toStringAsFixed(2)} mm/s. '
            'Peak in window ${peakVib.vibration.toStringAsFixed(2)} mm/s.'
        : 'Alert when any sample > 0.';

    out.add(
      AlertEntry(
        title: 'Vibration alert',
        deviceId: deviceLabel,
        timestamp: lastHitFromNewest?.timestamp ?? peakVib.timestamp,
        status: HealthStatus.warning,
        message: vibMsg,
      ),
    );
  }

  final peakTemp = readings.reduce(
    (a, b) => a.temperature >= b.temperature ? a : b,
  );
  if (readings.any((r) => temperatureAlertActive(r.temperature))) {
    SensorReading? lastTempHitFromNewest;
    var kTempFromLatest = 0;
    for (var i = readings.length - 1; i >= 0; i--) {
      if (temperatureAlertActive(readings[i].temperature)) {
        lastTempHitFromNewest = readings[i];
        kTempFromLatest = readings.length - i;
        break;
      }
    }
    final secPerPointTemp = _estimatedSecondsPerDataPoint(readings);
    final estTempSecondsAgo = kTempFromLatest * secPerPointTemp;
    final tempMsg = lastTempHitFromNewest != null
        ? '${lastTempHitFromNewest.temperature.toStringAsFixed(1)} °C — '
            '${_ordinalFromLatest(kTempFromLatest)} : '
            '${_formatRoughAgo(estTempSecondsAgo)} '
            '(≈${secPerPointTemp.toStringAsFixed(1)}s per point). '
            'Current ${latest.temperature.toStringAsFixed(1)} °C. '
            'Peak in window ${peakTemp.temperature.toStringAsFixed(1)} °C.'
        : 'Alert when any sample ≥ 25 °C.';

    out.add(
      AlertEntry(
        title: 'Temperature alert',
        deviceId: deviceLabel,
        timestamp: lastTempHitFromNewest?.timestamp ?? peakTemp.timestamp,
        status: HealthStatus.warning,
        message: tempMsg,
      ),
    );
  }

  return out;
}

class _LiveThresholdAlerts extends StatelessWidget {
  const _LiveThresholdAlerts({
    required this.deviceLabel,
    required this.readings,
  });

  final String deviceLabel;
  final List<SensorReading> readings;

  @override
  Widget build(BuildContext context) {
    final entries = liveAlertsFromReadings(deviceLabel, readings);
    if (entries.isEmpty) {
      return const SizedBox.shrink();
    }

    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Active alerts',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: scheme.error,
              ),
        ),
        const SizedBox(height: 8),
        ...entries.map(
          (e) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: scheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.notifications_active_rounded, color: scheme.error),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            e.title,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            e.message,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
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
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 6),
                Text(
                  '${entry.deviceId} • ${DateFormat('dd MMM, HH:mm').format(entry.timestamp)}',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
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
          children: const [
            Icon(Icons.inbox_rounded, size: 36, color: Colors.white54),
            SizedBox(height: 10),
            Text('No alerts available', style: TextStyle(fontWeight: FontWeight.w600)),
            SizedBox(height: 4),
            Text(
              'The selected devices are operating within normal ranges.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
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
