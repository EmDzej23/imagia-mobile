import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'router.dart';
import 'services/notifications.dart';
import 'services/push_service.dart';
import 'theme/app_theme.dart';
import 'widgets/render_indicator.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await NotificationService.instance.init();
  await PushService.instance.init();
  runApp(const ProviderScope(child: ImagiaApp()));
}

class ImagiaApp extends ConsumerWidget {
  const ImagiaApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Imagia',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: router,
      builder: (context, child) =>
          RenderIndicatorOverlay(child: child ?? const SizedBox.shrink()),
    );
  }
}
