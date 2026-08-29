enum BusStatus { onTime, late, weak, off }

class Bus {
  final String no;
  final String name;
  final BusStatus status;
  final String statusLabel;
  final String eta;

  const Bus({
    required this.no,
    required this.name,
    required this.status,
    required this.statusLabel,
    required this.eta,
  });

  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return '$no $name $statusLabel'.toLowerCase().contains(q);
  }
}

const List<Bus> mockBuses = [
  Bus(no: '12', name: 'Kottayam ⇄ CEK Kidangoor', status: BusStatus.onTime, statusLabel: 'On Time', eta: '6 min'),
  Bus(no: '04', name: 'Town ⇄ Ayarkunnam', status: BusStatus.late, statusLabel: 'Delayed 7 min', eta: '18 min'),
  Bus(no: '27', name: 'Manthadi Loop', status: BusStatus.weak, statusLabel: 'GPS Signal Weak', eta: '~11 min'),
  Bus(no: '08', name: 'CEK ⇄ Kidangoor Junction', status: BusStatus.onTime, statusLabel: 'On Time', eta: '3 min'),
  Bus(no: '19', name: 'KSRTC Stand ⇄ Manthadi', status: BusStatus.onTime, statusLabel: 'On Time', eta: '24 min'),
  Bus(no: '33', name: 'Oravakal ⇄ Malam', status: BusStatus.off, statusLabel: 'Offline', eta: '—'),
];
