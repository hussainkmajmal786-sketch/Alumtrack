enum NotifIcon { bell, clock, signal, check, stop }

NotifIcon _iconFor(String? kind) {
  switch (kind) {
    case 'arriving':
      return NotifIcon.bell;
    case 'delay':
      return NotifIcon.clock;
    case 'signal':
      return NotifIcon.signal;
    case 'stop':
      return NotifIcon.stop;
    default:
      return NotifIcon.check;
  }
}

class NotificationItem {
  final String id;
  final String msg;
  final String? route;
  final DateTime createdAt;
  final NotifIcon icon;
  final bool unread;

  const NotificationItem({
    required this.id,
    required this.msg,
    required this.route,
    required this.createdAt,
    required this.icon,
    required this.unread,
  });

  factory NotificationItem.fromJson(Map<String, dynamic> json) =>
      NotificationItem(
        id: json['id'] as String,
        msg: json['message'] as String,
        route: json['routeNumber'] == null
            ? null
            : 'Route ${json['routeNumber']}',
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          (json['createdAt'] as num).toInt(),
        ),
        icon: _iconFor(json['kind'] as String?),
        unread: json['unread'] == true,
      );

  /// "9:33 AM" in the viewer's local time.
  String get time {
    final local = createdAt.toLocal();
    final hour12 = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    return '$hour12:$minute ${local.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// Alerts bucketed by day, matching the panel's "Today / Yesterday" sections.
class NotificationGroup {
  final String day;
  final List<NotificationItem> items;

  const NotificationGroup({required this.day, required this.items});

  /// Groups a flat, newest-first feed into day sections.
  static List<NotificationGroup> group(List<NotificationItem> items) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final buckets = <String, List<NotificationItem>>{};
    final order = <String>[];

    for (final item in items) {
      final d = item.createdAt.toLocal();
      final day = DateTime(d.year, d.month, d.day);

      final String label;
      if (day == today) {
        label = 'Today';
      } else if (day == yesterday) {
        label = 'Yesterday';
      } else {
        label = '${day.day}/${day.month}/${day.year}';
      }

      if (!buckets.containsKey(label)) order.add(label);
      buckets.putIfAbsent(label, () => []).add(item);
    }

    return order
        .map((label) => NotificationGroup(day: label, items: buckets[label]!))
        .toList();
  }
}
