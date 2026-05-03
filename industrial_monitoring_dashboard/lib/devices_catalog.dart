import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class Device {
  const Device({required this.id, required this.label});

  final String id;
  final String label;
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
    final secondary = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65);

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
                    style: TextStyle(color: secondary, fontSize: 12),
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
