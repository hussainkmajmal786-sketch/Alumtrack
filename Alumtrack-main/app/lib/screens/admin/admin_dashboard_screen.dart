import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../data/admin_service.dart';
import '../../data/api_client.dart';
import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';
import 'route_stops_screen.dart';

String _timeAgo(int epochMs) {
  final seconds = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(epochMs)).inSeconds;
  if (seconds < 45) return 'just now';
  final minutes = (seconds / 60).round();
  if (minutes < 60) return '$minutes min ago';
  final hours = (minutes / 60).round();
  if (hours < 24) return '$hours h ago';
  return '${(hours / 24).round()} d ago';
}

/// Staff dashboard: buses & trackers, admin accounts (superadmin only),
/// students, and a broadcast composer — the four capabilities the college
/// asked for, all gated behind [AdminLoginScreen].
class AdminDashboardScreen extends StatelessWidget {
  const AdminDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;
    final session = state.adminSession;
    final isSuper = session?.isSuperadmin ?? false;

    final tabs = <Tab>[
      const Tab(text: 'Buses'),
      if (isSuper) const Tab(text: 'Admins'),
      const Tab(text: 'Students'),
      const Tab(text: 'Notify'),
    ];
    final views = <Widget>[
      const _BusesTab(),
      if (isSuper) const _AdminsTab(),
      const _StudentsTab(),
      const _NotifyTab(),
    ];

    return DefaultTabController(
      length: tabs.length,
      child: Container(
        color: c.bg,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 12, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(session?.name ?? 'Staff',
                              style: sfText(size: 20, weight: FontWeight.w700, color: c.label)),
                          Text(isSuper ? 'Superadmin' : 'Admin',
                              style: sfText(size: 13, weight: FontWeight.w500, color: c.lab3)),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: state.adminSignOut,
                      icon: Icon(Icons.logout_rounded, color: c.label),
                      tooltip: 'Sign out',
                    ),
                  ],
                ),
              ),
              TabBar(
                isScrollable: true,
                labelColor: c.acc,
                unselectedLabelColor: c.lab3,
                indicatorColor: c.acc,
                tabs: tabs,
              ),
              Expanded(child: TabBarView(children: views)),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Buses & trackers
// ---------------------------------------------------------------------------

class _BusesTab extends StatefulWidget {
  const _BusesTab();

  @override
  State<_BusesTab> createState() => _BusesTabState();
}

class _BusesTabState extends State<_BusesTab> {
  List<AdminBus>? _buses;
  List<AdminDevice>? _devices;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().adminApi;
    try {
      final buses = await api.buses();
      final devices = await api.devices();
      if (!mounted) return;
      setState(() {
        _buses = buses;
        _devices = devices;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _addBus() async {
    final numberCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a bus route'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: numberCtrl, decoration: const InputDecoration(labelText: 'Route number')),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Route name')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true || numberCtrl.text.trim().isEmpty || nameCtrl.text.trim().isEmpty) return;

    try {
      await context.read<AppState>().adminApi.createBus(
            number: numberCtrl.text.trim(),
            name: nameCtrl.text.trim(),
          );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleBus(AdminBus bus) async {
    try {
      await context.read<AppState>().adminApi.setBusActive(bus.id, !bus.active);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addDevice() async {
    final buses = _buses ?? const [];
    if (buses.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add a bus route first.')),
      );
      return;
    }
    final deviceIdCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    String routeId = buses.first.id;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add a tracker'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: deviceIdCtrl,
                decoration: const InputDecoration(labelText: 'Device ID (from the ESP32)'),
              ),
              TextField(controller: labelCtrl, decoration: const InputDecoration(labelText: 'Label (optional)')),
              const SizedBox(height: 8),
              DropdownButton<String>(
                value: routeId,
                isExpanded: true,
                items: buses
                    .map((b) => DropdownMenuItem(value: b.id, child: Text('${b.number} — ${b.name}')))
                    .toList(),
                onChanged: (v) => setDialogState(() => routeId = v ?? routeId),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
          ],
        ),
      ),
    );
    if (ok != true || deviceIdCtrl.text.trim().isEmpty) return;

    try {
      final token = await context.read<AppState>().adminApi.provisionDevice(
            deviceId: deviceIdCtrl.text.trim(),
            routeId: routeId,
            label: labelCtrl.text.trim().isEmpty ? null : labelCtrl.text.trim(),
          );
      await _load();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Tracker token'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Flash this into the ESP32 now — it is shown only once.'),
              const SizedBox(height: 12),
              SelectableText(token, style: const TextStyle(fontFamily: 'monospace')),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: token)),
              child: const Text('Copy'),
            ),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _revokeDevice(AdminDevice device) async {
    try {
      await context.read<AppState>().adminApi.revokeDevice(device.deviceId);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _ErrorState(message: _error!, onRetry: _load);
    if (_buses == null) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader(title: 'Routes', onAdd: _addBus),
          if (_buses!.isEmpty) const _EmptyRow(text: 'No routes yet.'),
          for (final b in _buses!)
            Card(
              child: ListTile(
                title: Text('${b.number} — ${b.name}'),
                subtitle: Text(
                  '${b.active ? 'Active' : 'Inactive'} · ${b.stops.length} stop${b.stops.length == 1 ? '' : 's'}',
                ),
                onTap: () async {
                  final changed = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(builder: (_) => RouteStopsScreen(bus: b)),
                  );
                  if (changed == true) await _load();
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Switch(value: b.active, onChanged: (_) => _toggleBus(b)),
                    const Icon(Icons.chevron_right_rounded),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 20),
          _SectionHeader(title: 'Trackers', onAdd: _addDevice),
          if ((_devices ?? const []).isEmpty) const _EmptyRow(text: 'No trackers provisioned yet.'),
          for (final d in _devices ?? const <AdminDevice>[])
            Card(
              child: ListTile(
                title: Text(d.label?.isNotEmpty == true ? d.label! : d.deviceId),
                subtitle: Text(
                  'Route ${d.routeNumber ?? '—'} · '
                  '${d.revoked ? 'Revoked' : d.lastSeen == null ? 'Never reported in' : 'Last seen ${_timeAgo(d.lastSeen!)}'}',
                ),
                trailing: d.revoked
                    ? null
                    : TextButton(onPressed: () => _revokeDevice(d), child: const Text('Revoke')),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Admins (superadmin only)
// ---------------------------------------------------------------------------

class _AdminsTab extends StatefulWidget {
  const _AdminsTab();

  @override
  State<_AdminsTab> createState() => _AdminsTabState();
}

class _AdminsTabState extends State<_AdminsTab> {
  List<AdminAccount>? _admins;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await context.read<AppState>().adminApi.admins();
      if (!mounted) return;
      setState(() {
        _admins = list;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  Future<void> _addAdmin() async {
    final activeAdmins = (_admins ?? const []).where((a) => a.role == AdminRole.admin && a.active).length;
    if (activeAdmins >= 4) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Only 4 admins are allowed at a time. Deactivate one first.')),
      );
      return;
    }

    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add an admin'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email')),
            TextField(
              controller: passwordCtrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Temporary password (8+ chars)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true) return;
    if (nameCtrl.text.trim().isEmpty || emailCtrl.text.trim().isEmpty || passwordCtrl.text.length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Name, email and an 8+ character password are required.')),
      );
      return;
    }

    try {
      await context.read<AppState>().adminApi.createAdmin(
            email: emailCtrl.text.trim(),
            password: passwordCtrl.text,
            name: nameCtrl.text.trim(),
          );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleAdmin(AdminAccount admin) async {
    try {
      await context.read<AppState>().adminApi.setAdminActive(admin.id, !admin.active);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _ErrorState(message: _error!, onRetry: _load);
    if (_admins == null) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _SectionHeader(title: 'Admins (max 4)', onAdd: _addAdmin),
          for (final a in _admins!)
            Card(
              child: ListTile(
                title: Text(a.name),
                subtitle: Text(
                  '${a.email} · ${a.role == AdminRole.superadmin ? 'Superadmin' : a.active ? 'Active' : 'Deactivated'}',
                ),
                trailing: a.role == AdminRole.superadmin
                    ? null
                    : Switch(value: a.active, onChanged: (_) => _toggleAdmin(a)),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Students
// ---------------------------------------------------------------------------

class _StudentsTab extends StatefulWidget {
  const _StudentsTab();

  @override
  State<_StudentsTab> createState() => _StudentsTabState();
}

class _StudentsTabState extends State<_StudentsTab> {
  List<AdminStudent>? _students;
  List<AdminBus>? _buses;
  String? _error;
  final Set<String> _selected = {};
  bool _assigning = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = context.read<AppState>().adminApi;
      final results = await Future.wait([api.students(), api.buses()]);
      if (!mounted) return;
      setState(() {
        _students = results[0] as List<AdminStudent>;
        _buses = results[1] as List<AdminBus>;
        _selected.removeWhere((subject) => !_students!.any((s) => s.subject == subject));
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    }
  }

  void _toggleSelected(String subject) {
    setState(() {
      if (_selected.contains(subject)) {
        _selected.remove(subject);
      } else {
        _selected.add(subject);
      }
    });
  }

  Future<void> _remove(AdminStudent student) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this student?'),
        content: Text('${student.name ?? student.email ?? 'This student'} will be signed out and their account deleted.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await context.read<AppState>().adminApi.removeStudent(student.subject);
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  /// Bulk-assigns the selected students to one bus — or clears their
  /// assignment, via the "No bus (unassigned)" option — and optionally pins
  /// them to one specific stop on that bus (their usual boarding point), so
  /// each student's app only ever shows the bus (and stop) their admin
  /// picked for them.
  Future<void> _assignSelected() async {
    final buses = _buses ?? const [];
    String? routeId = buses.isNotEmpty ? buses.first.id : null;
    const unassignedValue = '__unassigned__';
    const anyStopValue = '__any_stop__';
    String dropdownValue = routeId ?? unassignedValue;
    String stopDropdownValue = anyStopValue;

    List<AdminStop> stopsFor(String? id) =>
        buses.firstWhere((b) => b.id == id, orElse: () => AdminBus(id: '', number: '', name: '', active: true)).stops;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final stops = stopsFor(routeId);
          return AlertDialog(
            title: Text('Assign ${_selected.length} student${_selected.length == 1 ? '' : 's'}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('They will only see this bus in the app.'),
                const SizedBox(height: 12),
                DropdownButton<String>(
                  value: dropdownValue,
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(value: unassignedValue, child: Text('No bus (unassigned)')),
                    for (final b in buses)
                      DropdownMenuItem(value: b.id, child: Text('${b.number} — ${b.name}')),
                  ],
                  onChanged: (v) => setDialogState(() {
                    dropdownValue = v ?? dropdownValue;
                    routeId = dropdownValue == unassignedValue ? null : dropdownValue;
                    stopDropdownValue = anyStopValue;
                  }),
                ),
                if (routeId != null) ...[
                  const SizedBox(height: 16),
                  const Text('Pickup stop (optional) — fixes exactly where they board.'),
                  const SizedBox(height: 8),
                  DropdownButton<String>(
                    value: stopDropdownValue,
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(value: anyStopValue, child: Text('No fixed stop')),
                      for (final st in stops)
                        DropdownMenuItem(value: st.id, child: Text(st.name)),
                    ],
                    onChanged: (v) => setDialogState(() => stopDropdownValue = v ?? stopDropdownValue),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Assign')),
            ],
          );
        },
      ),
    );
    if (ok != true) return;

    final stopId = (routeId != null && stopDropdownValue != anyStopValue) ? stopDropdownValue : null;

    setState(() => _assigning = true);
    try {
      final api = context.read<AppState>().adminApi;
      // assign-route always clears any previously pinned stop server-side
      // (a stop only makes sense within its own route), so this order is
      // safe: set the bus first, then pin the stop within it.
      await api.assignStudentsToRoute(_selected.toList(), routeId);
      if (stopId != null) {
        await api.assignStudentsToStop(_selected.toList(), stopId);
      }
      setState(() => _selected.clear());
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _assigning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) return _ErrorState(message: _error!, onRetry: _load);
    if (_students == null) return const Center(child: CircularProgressIndicator());

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_students!.length} student${_students!.length == 1 ? '' : 's'} signed in',
                  style: sfText(size: 13, weight: FontWeight.w500, color: Colors.grey),
                ),
              ),
              if (_selected.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _selected.clear()),
                  child: const Text('Clear selection'),
                ),
            ],
          ),
          if (_selected.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _assigning ? null : _assignSelected,
                icon: _assigning
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.directions_bus_rounded),
                label: Text('Assign ${_selected.length} to a bus'),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (_students!.isEmpty) const _EmptyRow(text: 'No students have signed in yet.'),
          for (final s in _students!)
            Card(
              child: ListTile(
                leading: Checkbox(
                  value: _selected.contains(s.subject),
                  onChanged: (_) => _toggleSelected(s.subject),
                ),
                onTap: () => _toggleSelected(s.subject),
                title: Text(s.name ?? s.email ?? 'Student'),
                subtitle: Text(
                  '${s.email ?? ''}  ·  last seen ${_timeAgo(s.lastSeenAt)}  ·  '
                  '${s.linkedRouteNumber != null ? 'Bus ${s.linkedRouteNumber}' : 'No bus assigned'}'
                  '${s.linkedStopName != null ? '  ·  ${s.linkedStopName}' : ''}',
                ),
                trailing: TextButton(onPressed: () => _remove(s), child: const Text('Remove')),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Notify
// ---------------------------------------------------------------------------

class _NotifyTab extends StatefulWidget {
  const _NotifyTab();

  @override
  State<_NotifyTab> createState() => _NotifyTabState();
}

class _NotifyTabState extends State<_NotifyTab> {
  final _messageCtrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final message = _messageCtrl.text.trim();
    if (message.isEmpty) return;
    setState(() => _sending = true);
    try {
      await context.read<AppState>().adminApi.notifyAll(message);
      _messageCtrl.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sent to every student.')),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Broadcast to every student', style: sfText(size: 16, weight: FontWeight.w600, color: Colors.grey.shade800)),
          const SizedBox(height: 4),
          Text(
            'Appears in every student\'s alerts feed, regardless of which bus they follow.',
            style: sfText(size: 13, weight: FontWeight.w400, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _messageCtrl,
            maxLines: 4,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: 'e.g. Classes are suspended tomorrow; buses will not run.',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _sending ? null : _send,
            child: _sending
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.4))
                : const Text('Send to all students'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  final String title;
  final VoidCallback onAdd;
  const _SectionHeader({required this.title, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(title, style: sfText(size: 17, weight: FontWeight.w700, color: Colors.grey.shade800))),
          TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add_rounded), label: const Text('Add')),
        ],
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  final String text;
  const _EmptyRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(text, style: sfText(size: 14, weight: FontWeight.w400, color: Colors.grey)),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
