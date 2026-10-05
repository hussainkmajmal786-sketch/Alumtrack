import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_text.dart';

/// Student sign-up / sign-in with email + password — an alternative to
/// Google Sign-In on the same [AppState] session, reached from AuthScreen.
class StudentEmailAuthScreen extends StatefulWidget {
  const StudentEmailAuthScreen({super.key});

  @override
  State<StudentEmailAuthScreen> createState() => _StudentEmailAuthScreenState();
}

class _StudentEmailAuthScreenState extends State<StudentEmailAuthScreen> {
  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _submit(AppState state) {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text;
    if (email.isEmpty || password.isEmpty) return;

    if (state.studentEmailSignUpMode) {
      final name = _nameCtrl.text.trim();
      state.studentSignUp(name: name, email: email, password: password);
    } else {
      state.studentSignIn(email: email, password: password);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = state.isDark ? AppColors.dark : AppColors.light;
    final signUp = state.studentEmailSignUpMode;

    return Container(
      color: c.bg,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(28, 0, 28, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: state.studentEmailSigningIn ? null : state.studentEmailBackToAuth,
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
                child: Icon(
                  signUp ? Icons.person_add_alt_1_rounded : Icons.login_rounded,
                  color: Colors.white,
                  size: 32,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                signUp ? 'Create Account' : 'Welcome Back',
                style: sfText(size: 28, weight: FontWeight.w700, letterSpacing: -0.6, color: c.label),
              ),
              const SizedBox(height: 8),
              Text(
                signUp
                    ? 'Sign up with your email to track your bus.'
                    : 'Sign in with your email and password.',
                style: sfText(size: 14.5, weight: FontWeight.w400, color: c.lab2, height: 1.4),
              ),
              const SizedBox(height: 34),
              if (signUp) ...[
                _Field(
                  controller: _nameCtrl,
                  label: 'Name (optional)',
                  colors: c,
                  keyboardType: TextInputType.name,
                ),
                const SizedBox(height: 14),
              ],
              _Field(
                controller: _emailCtrl,
                label: 'Email',
                colors: c,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 14),
              _Field(
                controller: _passwordCtrl,
                label: signUp ? 'Password (min 6 characters)' : 'Password',
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
              if (state.studentEmailAuthError != null) ...[
                const SizedBox(height: 16),
                Text(
                  state.studentEmailAuthError!,
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
                    onTap: state.studentEmailSigningIn ? null : () => _submit(state),
                    child: Center(
                      child: state.studentEmailSigningIn
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white),
                            )
                          : Text(
                              signUp ? 'Sign Up' : 'Sign In',
                              style: sfText(size: 16.5, weight: FontWeight.w600, color: Colors.white),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Center(
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: state.studentEmailSigningIn ? null : state.toggleStudentEmailMode,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: RichText(
                      text: TextSpan(
                        style: sfText(size: 13.5, weight: FontWeight.w400, color: c.lab2),
                        children: [
                          TextSpan(
                            text: signUp ? 'Already have an account? ' : "Don't have an account? ",
                          ),
                          TextSpan(
                            text: signUp ? 'Sign In' : 'Sign Up',
                            style: sfText(size: 13.5, weight: FontWeight.w600, color: c.acc),
                          ),
                      ],
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
