import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';
import '../widgets/liquid_segmented_control.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    return Container(
      color: c.bgGroup,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(bottom: 40),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 10, 0),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: state.backFromSettings,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.chevron_left_rounded, size: 24, color: c.acc),
                      const SizedBox(width: 1),
                      Text(state.settingsBackLabel, style: sfText(size: 17, weight: FontWeight.w400, letterSpacing: -0.17, color: c.acc)),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
              child: Text('Settings', style: sfText(size: 34, weight: FontWeight.w700, letterSpacing: -0.95, color: c.label)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionLabel('Appearance', c),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(color: c.bgEl, borderRadius: BorderRadius.circular(16), boxShadow: c.shadow),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LiquidSegmentedControl(
                          options: const ['System', 'Light', 'Dark'],
                          selectedIndex: ThemeSetting.values.indexOf(state.themeSetting),
                          onChanged: (i) => state.setTheme(ThemeSetting.values[i]),
                        ),
                        const SizedBox(height: 10),
                        Text(state.appearanceNote, style: sfText(size: 12.5, weight: FontWeight.w400, color: c.lab2, height: 1.4)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),
                  _SectionLabel('Notifications', c),
                  Container(
                    decoration: BoxDecoration(color: c.bgEl, borderRadius: BorderRadius.circular(16), boxShadow: c.shadow),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Notify me before arrival', style: sfText(size: 16, weight: FontWeight.w400, letterSpacing: -0.19, color: c.label)),
                              const SizedBox(height: 12),
                              LiquidSegmentedControl(
                                options: const ['2 min', '5 min', '10 min'],
                                selectedIndex: const ['2 min', '5 min', '10 min'].indexOf(state.lead),
                                onChanged: (i) => state.setLead(const ['2 min', '5 min', '10 min'][i]),
                              ),
                            ],
                          ),
                        ),
                        Padding(padding: const EdgeInsets.only(left: 16), child: Container(height: 1, color: c.sep)),
                        _SettingsRow(
                          title: 'Notification history',
                          trailingText: '${state.badge} new',
                          onTap: state.openNotif,
                          c: c,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),
                  _SectionLabel('My bus', c),
                  Container(
                    decoration: BoxDecoration(color: c.bgEl, borderRadius: BorderRadius.circular(16), boxShadow: c.shadow),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        _IconRow(
                          icon: Icons.directions_bus_filled_rounded,
                          iconBg: c.accSoft,
                          iconColor: c.acc,
                          title: 'Linked bus',
                          trailingText: 'Route 12',
                          onTap: state.goBus,
                          c: c,
                        ),
                        Padding(padding: const EdgeInsets.only(left: 63), child: Container(height: 1, color: c.sep)),
                        _IconRow(
                          icon: Icons.location_on_rounded,
                          iconBg: c.fill,
                          iconColor: c.label,
                          title: 'Location sharing',
                          trailingText: state.sharing ? 'On' : 'Off',
                          onTap: state.openCollab,
                          c: c,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 26),
                  Container(
                    decoration: BoxDecoration(color: c.bgEl, borderRadius: BorderRadius.circular(16), boxShadow: c.shadow),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: state.goAuth,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        child: Center(
                          child: Text('Sign out', style: sfText(size: 16, weight: FontWeight.w400, color: c.red)),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(6, 18, 6, 0),
                    child: Text(
                      'Campus Bus Tracker 1.0 (24)\nCollege of Engineering Kidangoor',
                      textAlign: TextAlign.center,
                      style: sfText(size: 12, weight: FontWeight.w400, color: c.lab3, height: 1.4),
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

class _SectionLabel extends StatelessWidget {
  final String text;
  final AppColors c;
  const _SectionLabel(this.text, this.c);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
      child: Text(text.toUpperCase(), style: sfText(size: 12.5, weight: FontWeight.w500, letterSpacing: 0.5, color: c.lab2)),
    );
  }
}

class _SettingsRow extends StatelessWidget {
  final String title;
  final String trailingText;
  final VoidCallback onTap;
  final AppColors c;
  const _SettingsRow({required this.title, required this.trailingText, required this.onTap, required this.c});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Row(
          children: [
            Expanded(child: Text(title, style: sfText(size: 16, weight: FontWeight.w400, letterSpacing: -0.19, color: c.label))),
            Text(trailingText, style: sfText(size: 15, weight: FontWeight.w400, color: c.lab2)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.lab3),
          ],
        ),
      ),
    );
  }
}

class _IconRow extends StatelessWidget {
  final IconData icon;
  final Color iconBg;
  final Color iconColor;
  final String title;
  final String trailingText;
  final VoidCallback onTap;
  final AppColors c;
  const _IconRow({
    required this.icon,
    required this.iconBg,
    required this.iconColor,
    required this.title,
    required this.trailingText,
    required this.onTap,
    required this.c,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: iconBg, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 18, color: iconColor),
            ),
            const SizedBox(width: 13),
            Expanded(child: Text(title, style: sfText(size: 16, weight: FontWeight.w400, letterSpacing: -0.19, color: c.label))),
            Text(trailingText, style: sfText(size: 15, weight: FontWeight.w400, color: c.lab2)),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 16, color: c.lab3),
          ],
        ),
      ),
    );
  }
}
