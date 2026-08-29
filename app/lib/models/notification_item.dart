enum NotifIcon { bell, clock, signal, check }

class NotificationItem {
  final String msg;
  final String route;
  final String time;
  final NotifIcon icon;
  final bool unread;

  const NotificationItem({
    required this.msg,
    required this.route,
    required this.time,
    required this.icon,
    required this.unread,
  });
}

class NotificationGroup {
  final String day;
  final List<NotificationItem> items;

  const NotificationGroup({required this.day, required this.items});
}

const List<NotificationGroup> mockNotifications = [
  NotificationGroup(day: 'Today', items: [
    NotificationItem(msg: 'Your bus is 5 minutes away', route: 'Route 12', time: '9:33 AM', icon: NotifIcon.bell, unread: true),
    NotificationItem(msg: 'Route 12 delayed 7 min near Ayarkunnam', route: 'Route 12', time: '8:58 AM', icon: NotifIcon.clock, unread: true),
    NotificationItem(msg: 'GPS signal restored on Route 27', route: 'Route 27', time: '8:41 AM', icon: NotifIcon.signal, unread: false),
  ]),
  NotificationGroup(day: 'Yesterday', items: [
    NotificationItem(msg: 'Your bus is 5 minutes away', route: 'Route 12', time: '5:12 PM', icon: NotifIcon.bell, unread: false),
    NotificationItem(msg: '3 riders shared location on your bus', route: 'Route 12', time: '5:02 PM', icon: NotifIcon.check, unread: false),
    NotificationItem(msg: 'Route 12 finished service for the day', route: 'Route 12', time: '7:40 PM', icon: NotifIcon.check, unread: false),
  ]),
];
