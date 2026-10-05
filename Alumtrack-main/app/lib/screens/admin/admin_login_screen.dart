import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text.dart';

/// Staff sign-in: email + password, separate from the student Google flow.
class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _submit(AppState state) {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (email.isEmpty || password.isEmpty) return;
    state.adminSignIn(email, password);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;

    return Container(
      color: c.bg,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: state.adminSigningIn ? null : state.adminBackToAuth,
                  icon: Icon(Icons.arrow_back_ios_new_rounded, color: c.label, size: 18),
                ),
              ),
              const SizedBox(height: 8),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: c.acc,
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: c.shadow,
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.admin_panel_settings_rounded, color: Colors.white, size: 32),
              ),
              const SizedBox(height: 22),
              Text(
                'Staff Sign In',
                style: sfText(size: 28, weight: FontWeight.w700, letterSpacing: -0.6, color: c.label),
              ),
              const SizedBox(height: 8),
              Text(
                'For route admins and the superadmin only.',
                style: sfText(size: 14.5, weight: FontWeight.w400, color: c.lab2, height: 1.4),
              ),
              const SizedBox(height: 34),
              _Field(
                controller: _emailCtrl,
                label: 'Email',
                colors: c,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 14),
              _Field(
                controller: _passwordCtrl,
                label: 'Password',
                colors: c,
                obscure: _obscure,
                onSubmitted: (_) => _submit(state),
                suffix: IconButton(
                  onPressed: () => setState(() => _obscure = !_obscure),
                  icon: Icon(
                    _obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                    color: c.lab3,
                    size: 20,
                  ),
                ),
              ),
              if (state.adminAuthError != null) ...[
                const SizedBox(height: 16),
                Text(
                  state.adminAuthError!,
                  textAlign: TextAlign.center,
                  style: sfText(size: 13.5, weight: FontWeight.w500, color: const Color(0xFFE5484D)),
                ),
              ],
              const SizedBox(height: 24),
              SizedBox(
                height: 54,
                child: Material(
                  color: c.acc,
                  borderRadius: BorderRadius.circular(15),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(15),
                    onTap: state.adminSigningIn ? null : () => _submit(state),
                    child: Center(
                      child: state.adminSigningIn
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                            )
                          : Text(
                              'Sign In',
                              style: sfText(size: 16.5, weight: FontWeight.w600, color: Colors.white),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final dynamic colors;
  final bool obscure;
  final TextInputType? keyboardType;
  final Widget? suffix;
  final ValueChanged<String>? onSubmitted;

  const _Field({
    required this.controller,
    required this.label,
    required this.colors,
    this.obscure = false,
    this.keyboardType,
    this.suffix,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: colors.bgEl,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.sep),
      ),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        keyboardType: keyboardType,
        onSubmitted: onSubmitted,
        style: sfText(size: 16, weight: FontWeight.w500, color: colors.label),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: sfText(size: 14.5, weight: FontWeight.w400, color: colors.lab3),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          suffixIcon: suffix,
        ),
      ),
    );
  }
}
