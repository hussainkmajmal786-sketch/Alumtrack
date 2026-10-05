import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_service.dart';
import '../../data/api_client.dart';
import '../../state/app_state.dart';

/// Editor for one route's stop sequence — the physical path an admin lays
/// out from the start point to the end destination.
///
/// "Reverse direction" builds the return trip from the same stops rather
/// than making an admin re-enter coordinates by hand: a campus shuttle's
/// morning and evening runs are the same road in the opposite order, so the
/// only thing that actually changes is which end is `seq: 0`.
class RouteStopsScreen extends StatefulWidget {
  final AdminBus bus;
  const RouteStopsScreen({super.key, required this.bus});

  @override
  State<RouteStopsScreen> createState() => _RouteStopsScreenState();
}

class _RouteStopsScreenState extends State<RouteStopsScreen> {
  late List<_StopDraft> _stops;
  bool _saving = false;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _stops = widget.bus.stops
        .map((s) => _StopDraft(
              name: s.name,
              lat: s.lat,
              lng: s.lng,
              scheduledAt: s.scheduledAt,
            ))
        .toList();
  }

  @override
  void dispose() {
    for (final s in _stops) {
      s.dispose();
    }
    super.dispose();
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _addStop() {
    setState(() {
      _stops.add(_StopDraft(name: '', lat: null, lng: null, scheduledAt: null));
      _dirty = true;
    });
  }

  void _removeStop(int index) {
    setState(() {
      _stops.removeAt(index).dispose();
      _dirty = true;
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      // onReorderItem's newIndex already accounts for the item's removal at
      // oldIndex (unlike the deprecated onReorder), so no manual -1 shift.
      final item = _stops.removeAt(oldIndex);
      _stops.insert(newIndex, item);
      _dirty = true;
    });
  }

  /// Flips the stop order end-to-start: the last stop (the current
  /// destination) becomes the first, and so on. Names, coordinates, and
  /// schedules travel with their stop — only the sequence changes.
  void _reverseDirection() {
    setState(() {
      _stops = _stops.reversed.toList();
      _dirty = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Order reversed — review and save to apply.')),
    );
  }

  Future<void> _save() async {
    final cleaned = <AdminStop>[];
    for (final s in _stops) {
      final name = s.nameCtrl.text.trim();
      final lat = double.tryParse(s.latCtrl.text.trim());
      final lng = double.tryParse(s.lngCtrl.text.trim());
      if (name.isEmpty || lat == null || lng == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Every stop needs a name and valid lat/lng.')),
        );
        return;
      }
      cleaned.add(AdminStop(
        id: '',
        seq: 0,
        name: name,
        lat: lat,
        lng: lng,
        scheduledAt: s.scheduledAtCtrl.text.trim().isEmpty
            ? null
            : s.scheduledAtCtrl.text.trim(),
      ));
    }

    setState(() => _saving = true);
    try {
      await context.read<AppState>().adminApi.setRouteStops(widget.bus.id, cleaned);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.bus.number} — ${widget.bus.name}'),
        actions: [
          IconButton(
            tooltip: 'Reverse direction (start<->end)',
            icon: const Icon(Icons.swap_vert_rounded),
            onPressed: _stops.length < 2 ? null : _reverseDirection,
          ),
        ],
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: Colors.grey),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Stops run start to end, top to bottom. Drag to reorder, or use '
                    'Reverse direction to flip the whole route for the return trip.',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _stops.isEmpty
                ? const Center(child: Text('No stops yet. Add the first one below.'))
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    itemCount: _stops.length,
                    onReorderItem: _reorder,
                    itemBuilder: (context, i) => _StopCard(
                      key: ValueKey(_stops[i]),
                      index: i,
                      isStart: i == 0,
                      isEnd: i == _stops.length - 1,
                      draft: _stops[i],
                      onChanged: _markDirty,
                      onRemove: () => _removeStop(i),
                    ),
                  ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _addStop,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add stop'),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: _saving || !_dirty ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Save'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mutable, controller-backed form state for one stop being edited. Kept
/// separate from [AdminStop] (an immutable snapshot from the server) so text
/// fields have somewhere stable to read from across rebuilds.
class _StopDraft {
  final TextEditingController nameCtrl;
  final TextEditingController latCtrl;
  final TextEditingController lngCtrl;
  final TextEditingController scheduledAtCtrl;

  _StopDraft({
    required String name,
    required double? lat,
    required double? lng,
    required String? scheduledAt,
  })  : nameCtrl = TextEditingController(text: name),
        latCtrl = TextEditingController(text: lat?.toString() ?? ''),
        lngCtrl = TextEditingController(text: lng?.toString() ?? ''),
        scheduledAtCtrl = TextEditingController(text: scheduledAt ?? '');

  void dispose() {
    nameCtrl.dispose();
    latCtrl.dispose();
    lngCtrl.dispose();
    scheduledAtCtrl.dispose();
  }
}

class _StopCard extends StatelessWidget {
  final int index;
  final bool isStart;
  final bool isEnd;
  final _StopDraft draft;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _StopCard({
    required super.key,
    required this.index,
    required this.isStart,
    required this.isEnd,
    required this.draft,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final badge = isStart
        ? 'START'
        : isEnd
            ? 'END'
            : '${index + 1}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 52,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: isStart || isEnd
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: Text(
                badge,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                children: [
                  TextField(
                    controller: draft.nameCtrl,
                    decoration: const InputDecoration(labelText: 'Stop name', isDense: true),
                    onChanged: (_) => onChanged(),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: draft.latCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(labelText: 'Latitude', isDense: true),
                          onChanged: (_) => onChanged(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: draft.lngCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                            signed: true,
                          ),
                          decoration: const InputDecoration(labelText: 'Longitude', isDense: true),
                          onChanged: (_) => onChanged(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: draft.scheduledAtCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Scheduled time (HH:mm, optional)',
                      isDense: true,
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                ],
              ),
            ),
            Column(
              children: [
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                  onPressed: onRemove,
                  tooltip: 'Remove stop',
                ),
                const Icon(Icons.drag_handle_rounded, color: Colors.grey),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
