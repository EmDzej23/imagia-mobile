import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'screens/account/account_screen.dart';
import 'screens/auth/sign_in_screen.dart';
import 'screens/auth/sign_up_screen.dart';
import 'screens/create/export_screen.dart';
import 'screens/create/source_picker_screen.dart';
import 'screens/create/studio_screen.dart';
import 'screens/create/tile_library_screen.dart';
import 'api/downloads_api.dart';
import 'screens/downloads/downloads_screen.dart';
import 'screens/gallery/gallery_screen.dart';
import 'screens/preview/mosaic_preview_screen.dart';
import 'screens/video/video_export_screen.dart';
import 'screens/splash_screen.dart';
import 'state/auth_controller.dart';

/// Bridges a Riverpod provider to a [Listenable] so GoRouter re-evaluates its
/// redirect whenever auth state changes.
class _AuthRefresh extends ChangeNotifier {
  _AuthRefresh(Ref ref) {
    ref.listen(authControllerProvider, (_, _) => notifyListeners());
  }
}

/// Root navigator key — lets non-widget code (e.g. a tapped notification)
/// drive navigation.
final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = _AuthRefresh(ref);

  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) {
      final status = ref.read(authControllerProvider).status;
      final loc = state.matchedLocation;
      final onAuthRoute = loc == '/sign-in' || loc == '/sign-up';

      switch (status) {
        case AuthStatus.unknown:
          return loc == '/splash' ? null : '/splash';
        case AuthStatus.signedOut:
          return onAuthRoute ? null : '/sign-in';
        case AuthStatus.signedIn:
          return (onAuthRoute || loc == '/splash') ? '/' : null;
      }
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
      GoRoute(path: '/sign-in', builder: (_, _) => const SignInScreen()),
      GoRoute(path: '/sign-up', builder: (_, _) => const SignUpScreen()),
      GoRoute(path: '/', builder: (_, _) => const GalleryScreen()),
      GoRoute(
          path: '/create/source',
          builder: (_, _) => const SourcePickerScreen()),
      GoRoute(
          path: '/create/tiles',
          builder: (_, _) => const TileLibraryScreen()),
      GoRoute(
          path: '/create/studio', builder: (_, _) => const StudioScreen()),
      GoRoute(
          path: '/create/export', builder: (_, _) => const ExportScreen()),
      GoRoute(
          path: '/create/video',
          builder: (_, _) => const VideoExportScreen()),
      GoRoute(path: '/downloads', builder: (_, _) => const DownloadsScreen()),
      GoRoute(path: '/account', builder: (_, _) => const AccountScreen()),
      GoRoute(
        path: '/preview',
        builder: (_, state) =>
            MosaicPreviewScreen(record: state.extra as DownloadRecord?),
      ),
    ],
  );
});
