import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

/// A short, plain sentence for an error shown to the user. The raw error goes to the
/// debug log only — `DioException [connection timeout]…` means nothing to anyone
/// making a mosaic.
String friendlyError(Object e, {String fallback = 'Something went wrong. Please try again.'}) {
  debugPrint('[error] $e');
  if (e is GalException) {
    return e.type == GalExceptionType.accessDenied
        ? 'Allow access to Photos in Settings to save your mosaic.'
        : e.type == GalExceptionType.notEnoughSpace
            ? 'Not enough space on your phone to save it.'
            : "Couldn't save to Photos. Please try again.";
  }
  if (e is DioException) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'The connection is slow — please try again.';
      case DioExceptionType.connectionError:
        return 'No connection. Check your internet and try again.';
      case DioExceptionType.cancel:
        return 'Cancelled.';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode ?? 0;
        if (code == 401 || code == 403) return 'Please sign in again.';
        if (code == 413) return 'That file is too large.';
        if (code >= 500) return 'Our server had a problem. Please try again in a moment.';
        return fallback;
      default:
        return fallback;
    }
  }
  if (e is SocketException) return 'No connection. Check your internet and try again.';
  if (e is TimeoutException) return 'That took too long — please try again.';
  if (e is PlatformException) {
    final m = (e.message ?? e.code).toLowerCase();
    if (m.contains('permission') || m.contains('denied')) {
      return 'Permission needed — allow access in Settings and try again.';
    }
  }
  if (e is FormatException) return "That file couldn't be read. Try another photo.";
  return fallback;
}
