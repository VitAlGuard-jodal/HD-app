import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/device_mode.dart';
import 'location_source.dart';

/// The existing consent -> requestPermission -> watch boundary owns both sources.
class VehicleLocationSource implements LocationSource {
  VehicleLocationSource({
    required this.mode,
    required this.fallback,
    this.methods = const MethodChannel('unavo/location'),
    this.events = const EventChannel('unavo/location/events'),
  });

  final DeviceMode mode;
  final LocationSource fallback;
  final MethodChannel methods;
  final EventChannel events;
  bool _fused = false;
  LocationPermissionState _fallbackPermission = LocationPermissionState.denied;

  @override
  Future<LocationPermissionState> requestPermission() async {
    _fused = false;
    // Obtain fallback permission in the existing feature-consent flow as well;
    // a later SDK error must not open a new permission sheet during a call.
    _fallbackPermission = LocationPermissionState.denied;
    try {
      _fallbackPermission = await fallback.requestPermission();
    } catch (error) {
      if (mode != DeviceMode.car) rethrow;
      debugPrint(
        'unavo-location: geolocator permission unavailable (${error.runtimeType})',
      );
    }
    if (mode == DeviceMode.car) {
      try {
        _fused = await methods.invokeMethod<bool>('prepare') ?? false;
      } on MissingPluginException {
        debugPrint('unavo-location: geolocator (channel unavailable)');
      } on PlatformException catch (error) {
        debugPrint('unavo-location: geolocator (${error.code})');
      }
    }
    debugPrint(
      'unavo-location: source=${_fused ? 'FusedLocation' : 'geolocator'}',
    );
    return _fused ? LocationPermissionState.granted : _fallbackPermission;
  }

  @override
  Stream<LocationSample> watch() {
    if (!_fused) return fallback.watch();
    final decoder = FusedLocationSamples();
    late StreamController<LocationSample> controller;
    StreamSubscription<dynamic>? subscription;
    bool cancelled = false, switching = false;

    Future<void> useFallback(Object error) async {
      if (cancelled || switching) return;
      switching = true;
      _fused = false;
      debugPrint(
        'unavo-location: source=geolocator (FusedLocation stream failed)',
      );
      try {
        await subscription?.cancel(); // native unregister before another source
      } catch (_) {
        // Cancellation failure must not strand the location stream.
      }
      if (cancelled) return;
      if (_fallbackPermission != LocationPermissionState.granted) {
        controller.addError(error);
        await controller.close();
        return;
      }
      try {
        subscription = fallback.watch().listen(
          controller.add,
          onError: controller.addError,
          onDone: controller.close,
        );
      } catch (error, stack) {
        controller.addError(error, stack);
        await controller.close();
      }
    }

    controller = StreamController<LocationSample>(
      onListen: () {
        subscription = events.receiveBroadcastStream().listen(
          (dynamic event) {
            if (cancelled || switching) return;
            final sample = decoder.decode(event);
            if (sample != null) controller.add(sample);
          },
          onError: (Object error) => unawaited(useFallback(error)),
          onDone: () => unawaited(useFallback(StateError('location ended'))),
        );
      },
      onCancel: () async {
        cancelled = true;
        await subscription?.cancel();
      },
    );
    return controller.stream;
  }
}

/// One decoder per subscription: speed never crosses a stop/restart boundary.
class FusedLocationSamples {
  LocationSample? _previous;

  LocationSample? decode(Object? event) {
    if (event is! Map) return null;
    double? number(String key) {
      final value = event[key];
      return value is num && value.isFinite ? value.toDouble() : null;
    }

    final lat = number('latitude'), lng = number('longitude');
    final timestamp = number('timestampMillis');
    if (lat == null ||
        lat.abs() > 90 ||
        lng == null ||
        lng.abs() > 180 ||
        timestamp == null ||
        timestamp < 0 ||
        timestamp > 8640000000000000 ||
        timestamp != timestamp.truncateToDouble())
      return null;
    final at = DateTime.fromMillisecondsSinceEpoch(
      timestamp.toInt(),
      isUtc: true,
    );
    final previous = _previous;
    // Replayed/out-of-order measurements must not refresh freshness or trails.
    if (previous != null && !at.isAfter(previous.at)) return null;
    final seconds = previous == null
        ? 0.0
        : at.difference(previous.at).inMilliseconds / 1000;
    final heading = number('heading');
    final sample = LocationSample(
      lat: lat,
      lng: lng,
      src: 'vehicle',
      at: at,
      altitude: number('altitude'),
      confidence: number('confidence'),
      heading: heading != null && heading >= 0 && heading <= 360
          ? heading
          : null,
      // A long gap cannot establish current speed; keep heading correction off.
      speed: previous != null && seconds > 0 && seconds <= 10
          ? _distance(previous.lat, previous.lng, lat, lng) / seconds
          : null,
    );
    _previous = sample;
    return sample;
  }
}

double _distance(double lat1, double lng1, double lat2, double lng2) {
  const radians = math.pi / 180;
  final a =
      math.pow(math.sin((lat2 - lat1) * radians / 2), 2) +
      math.cos(lat1 * radians) *
          math.cos(lat2 * radians) *
          math.pow(math.sin((lng2 - lng1) * radians / 2), 2);
  return 6371000 * 2 * math.asin(math.sqrt(a.clamp(0, 1)));
}
