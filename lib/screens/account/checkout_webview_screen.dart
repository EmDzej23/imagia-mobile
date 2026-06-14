import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../theme/app_colors.dart';

/// Hosts the Creem hosted checkout in an in-app webview and pops `true` once it
/// reaches the server `/payment-success` page (Creem only redirects there after
/// a successful payment; the server credits tokens on that load). Pops `false`
/// if the user closes it.
class CheckoutWebviewScreen extends StatefulWidget {
  const CheckoutWebviewScreen({
    super.key,
    required this.checkoutUrl,
    this.successPath = '/payment-success',
  });

  final String checkoutUrl;

  /// URL fragment that signals a completed payment (Creem only redirects here
  /// after success). Defaults to the token-purchase page; prints use
  /// `/print-success`.
  final String successPath;

  @override
  State<CheckoutWebviewScreen> createState() => _CheckoutWebviewScreenState();
}

class _CheckoutWebviewScreenState extends State<CheckoutWebviewScreen> {
  late final WebViewController _controller;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Let the success page load fully (the server credits tokens on that
          // request), then close.
          onPageFinished: (url) {
            if (!_done && url.contains(widget.successPath)) {
              _done = true;
              if (mounted) Navigator.of(context).pop(true);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.checkoutUrl));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Checkout'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: SafeArea(child: WebViewWidget(controller: _controller)),
    );
  }
}
