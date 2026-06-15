import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../api/print_api.dart';
import '../../print/print_order_draft.dart';
import '../../state/auth_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_spacing.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/primary_button.dart';
import 'order_review_screen.dart';

/// Supported shipping destinations (US / EU / UK at launch).
const List<({String code, String name})> _countries = [
  (code: 'US', name: 'United States'),
  (code: 'GB', name: 'United Kingdom'),
  (code: 'IE', name: 'Ireland'),
  (code: 'DE', name: 'Germany'),
  (code: 'FR', name: 'France'),
  (code: 'IT', name: 'Italy'),
  (code: 'ES', name: 'Spain'),
  (code: 'NL', name: 'Netherlands'),
  (code: 'BE', name: 'Belgium'),
  (code: 'AT', name: 'Austria'),
  (code: 'PT', name: 'Portugal'),
  (code: 'SE', name: 'Sweden'),
  (code: 'DK', name: 'Denmark'),
  (code: 'FI', name: 'Finland'),
  (code: 'PL', name: 'Poland'),
  (code: 'RS', name: 'Serbia'), // testing
];

class ShippingAddressScreen extends ConsumerStatefulWidget {
  const ShippingAddressScreen({super.key, required this.draft});
  final PrintOrderDraft draft;

  @override
  ConsumerState<ShippingAddressScreen> createState() =>
      _ShippingAddressScreenState();
}

class _ShippingAddressScreenState extends ConsumerState<ShippingAddressScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _address1 = TextEditingController();
  final _address2 = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _zip = TextEditingController();
  String _country = 'US';
  String? _error;

  @override
  void initState() {
    super.initState();
    // Prefill name + email from the signed-in account (both stay editable).
    final user = ref.read(authControllerProvider).user;
    if (user != null) {
      _email.text = user.email;
      if (user.name.isNotEmpty) _name.text = user.name;
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _email,
      _phone,
      _address1,
      _address2,
      _city,
      _state,
      _zip
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _continue() {
    final name = _name.text.trim();
    final email = _email.text.trim();
    final address1 = _address1.text.trim();
    final city = _city.text.trim();
    final zip = _zip.text.trim();

    if (name.isEmpty ||
        email.isEmpty ||
        address1.isEmpty ||
        city.isEmpty ||
        zip.isEmpty) {
      setState(() => _error = 'Please fill in all required fields.');
      return;
    }
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Please enter a valid email.');
      return;
    }

    final recipient = PrintRecipient(
      name: name,
      email: email,
      phone: _phone.text.trim(),
      address1: address1,
      address2: _address2.text.trim(),
      city: city,
      stateCode: _state.text.trim(),
      countryCode: _country,
      zip: zip,
    );
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) =>
          OrderReviewScreen(draft: widget.draft, recipient: recipient),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shipping address')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.screen),
          children: [
            _field('Full name', _name,
                cap: TextCapitalization.words,
                hints: const [AutofillHints.name]),
            _field('Email', _email,
                keyboard: TextInputType.emailAddress,
                hints: const [AutofillHints.email]),
            _field('Phone (optional)', _phone,
                keyboard: TextInputType.phone,
                hints: const [AutofillHints.telephoneNumber]),
            _field('Address line 1', _address1,
                hints: const [AutofillHints.streetAddressLine1]),
            _field('Address line 2 (optional)', _address2,
                hints: const [AutofillHints.streetAddressLine2]),
            _field('City', _city,
                cap: TextCapitalization.words,
                hints: const [AutofillHints.addressCity]),
            _field('State / county (optional)', _state,
                cap: TextCapitalization.words),
            _field('Postal / ZIP code', _zip,
                hints: const [AutofillHints.postalCode]),
            const SizedBox(height: AppSpacing.x3),
            Text('Country', style: AppTypography.caption),
            const SizedBox(height: AppSpacing.x1),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.x4),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(AppRadius.control),
                border: Border.all(color: AppColors.border),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _country,
                  isExpanded: true,
                  dropdownColor: AppColors.surfaceRaised,
                  style: AppTypography.body,
                  items: [
                    for (final c in _countries)
                      DropdownMenuItem(value: c.code, child: Text(c.name)),
                  ],
                  onChanged: (v) => setState(() => _country = v ?? 'US'),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.x3),
              Text(_error!,
                  style: AppTypography.caption
                      .copyWith(color: AppColors.error)),
            ],
            const SizedBox(height: AppSpacing.x6),
            PrimaryButton(label: 'Continue to review', onPressed: _continue),
          ],
        ),
      ),
    );
  }

  Widget _field(String label, TextEditingController c,
      {TextInputType? keyboard,
      TextCapitalization cap = TextCapitalization.none,
      List<String>? hints}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.x3),
      child: AppTextField(
        label: label,
        controller: c,
        keyboardType: keyboard,
        textCapitalization: cap,
        autofillHints: hints,
      ),
    );
  }
}
