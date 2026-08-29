import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/notification_item.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import 'spring_drawer.dart';

const double _kPanelWidth = 338;
const double _kPanelExtent = 380;

class NotificationPanel extends StatelessWidget {
  const NotificationPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;
    final feed = state.alerts;
    final groups = feed?.groups ?? const <NotificationGroup>[];
    final isEmpty = groups.isEmpty;

    return IgnorePointer(
      ignoring: !state.notifOpen,
      child: SpringDrawer(
        open: state.notifOpen,
        axis: DrawerAxis.horizontal,
        extent: _kPanelExtent,
        openBounce: 0,
        openResponse: 0.4,
        closeBounce: 0,
        closeResponse: 0.36,
        builder: (context, offset, scrimOpacity) {
          return Stack(
            children: [
              if (scrimOpacity > 0)
                Positioned.fill(
                  child: GestureDetector(
                    onTap: state.closeNotif,
                    child: Container(
                      color: Colors.black.withValues(
                        alpha: 0.24 * scrimOpacity,
                      ),
                    ),
                  ),
                ),
              Positioned(
                top: 0,
                bottom: 0,
                right: -offset,
                width: _kPanelWidth,
                child: _PanelBody(
                  state: state,
                  c: c,
                  isEmpty: isEmpty,
                  groups: groups,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PanelBody extends StatelessWidget {
  final AppState state;
  final AppColors c;
  final bool isEmpty;
  final List<NotificationGroup> groups;
  const _PanelBody({
    required this.state,
    required this.c,
    required this.isEmpty,
    required this.groups,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: c.glass,
        borderRadius: const BorderRadius.horizontal(left: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: c.isDark ? 0.4 : 0.22),
            blurRadius: 44,
            offset: const Offset(-16, 0),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: SafeArea(
          left: false,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Alerts',
                        style: sfText(
                          size: 24,
                          weight: FontWeight.w700,
                          letterSpacing: -0.62,
                          color: c.label,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: state.closeNotif,
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: c.fill,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: c.lab2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: isEmpty
                    ? _EmptyState(c: c)
                    : ListView(
                        padding: const EdgeInsets.fromLTRB(14, 0, 14, 40),
                        children: [
                          for (final group in groups)
                            _NotifGroup(group: group, c: c),
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

class _EmptyState extends StatelessWidget {
  final AppColors c;
  const _EmptyState({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(34, 0, 34, 60),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.notifications_off_outlined, size: 56, color: c.lab3),
          const SizedBox(height: 20),
          Text(
            "You're all caught up.",
            style: sfText(
              size: 19,
              weight: FontWeight.w600,
              letterSpacing: -0.19,
              color: c.label,
            ),
          ),
          const SizedBox(height: 7),
          Text(
            'New alerts about your bus show up here.',
            textAlign: TextAlign.center,
            style: sfText(
              size: 14,
              weight: FontWeight.w400,
              color: c.lab2,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _NotifGroup extends StatelessWidget {
  final NotificationGroup group;
  final AppColors c;
  const _NotifGroup({required this.group, required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
            child: Text(
              group.day.toUpperCase(),
              style: sfText(
                size: 12.5,
                weight: FontWeight.w600,
                letterSpacing: 0.5,
                color: c.lab2,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              color: c.bgEl,
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < group.items.length; i++)
                  _NotifRow(
                    item: group.items[i],
                    showSeparator: i != group.items.length - 1,
                    c: c,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NotifRow extends StatelessWidget {
  final NotificationItem item;
  final bool showSeparator;
  final AppColors c;
  const _NotifRow({
    required this.item,
    required this.showSeparator,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    final Color iconBg;
    final Color iconFg;
    final IconData icon;
    switch (item.icon) {
      case NotifIcon.bell:
        iconBg = c.accSoft;
        iconFg = c.acc;
        icon = Icons.notifications_rounded;
        break;
      case NotifIcon.clock:
        iconBg = c.orangeBg;
        iconFg = c.orange;
        icon = Icons.schedule_rounded;
        break;
      case NotifIcon.signal:
        iconBg = c.grayBg;
        iconFg = c.gray;
        icon = Icons.wifi_rounded;
        break;
      case NotifIcon.check:
        iconBg = c.accSoft;
        iconFg = c.acc;
        icon = Icons.check_rounded;
        break;
    }

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: iconBg,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 15, color: iconFg),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.msg,
                      style: sfText(
                        size: 13.5,
                        weight: FontWeight.w600,
                        color: c.label,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      item.route == null
                          ? item.time
                          : '${item.route} · ${item.time}',
                      style: sfText(
                        size: 12,
                        weight: FontWeight.w400,
                        color: c.lab2,
                      ),
                    ),
                  ],
                ),
              ),
              if (item.unread)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 6),
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: c.acc,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (showSeparator)
          Positioned(
            left: 54,
            right: 0,
            bottom: 0,
            child: Container(height: 1, color: c.sep),
          ),
      ],
    );
  }
}
