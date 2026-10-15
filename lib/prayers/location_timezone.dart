import 'dart:math' as math;

import 'package:badi/prayers/city.dart';

/// Resolves a selected coordinate to the GeoNames timezone of its nearest
/// indexed city. City-picker selections use their exact GeoNames timezone;
/// GPS selections use the same offline data without consulting the device.
abstract final class LocationTimezone {
  /// One-pass resolve: timezone for prayer math plus nearest city (within
  /// [labelMaxKm]) for the display label. Prefer this over calling [resolve]
  /// + [nearestCity] separately (which scans the directory twice).
  static ({String? timezone, City? nearestCity}) resolveBoth({
    required double latitude,
    required double longitude,
    required Iterable<City> cities,
    City? selectedCity,
    double labelMaxKm = 50,
  }) {
    if (!_isValidCoordinate(latitude, longitude)) {
      return (timezone: null, nearestCity: null);
    }
    final selectedTimezone = selectedCity?.timeZone;
    final direct = selectedTimezone != null && selectedTimezone.isNotEmpty
        ? selectedTimezone
        : null;

    City? nearestTz;
    var nearestTzDist = double.infinity;
    City? nearestLabel;
    var nearestLabelDist = double.infinity;
    final maxDeg = labelMaxKm / 111.32;
    final maxSquared = maxDeg * maxDeg;
    for (final city in cities) {
      final distance = _squaredDistance(latitude, longitude, city);
      final timezone = city.timeZone;
      if (timezone != null && timezone.isNotEmpty && distance < nearestTzDist) {
        nearestTz = city;
        nearestTzDist = distance;
      }
      if (distance <= maxSquared && distance < nearestLabelDist) {
        nearestLabel = city;
        nearestLabelDist = distance;
      }
    }
    return (
      timezone: direct ?? nearestTz?.timeZone,
      nearestCity: nearestLabel,
    );
  }

  static String? resolve({
    required double latitude,
    required double longitude,
    required Iterable<City> cities,
    City? selectedCity,
  }) {
    if (!_isValidCoordinate(latitude, longitude)) return null;

    final selectedTimezone = selectedCity?.timeZone;
    if (selectedTimezone != null && selectedTimezone.isNotEmpty) {
      return selectedTimezone;
    }

    City? nearest;
    var nearestDistance = double.infinity;
    for (final city in cities) {
      final timezone = city.timeZone;
      if (timezone == null || timezone.isEmpty) continue;
      final distance = _squaredDistance(latitude, longitude, city);
      if (distance < nearestDistance) {
        nearest = city;
        nearestDistance = distance;
      }
    }
    return nearest?.timeZone;
  }

  static bool _isValidCoordinate(double latitude, double longitude) =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude >= -90 &&
      latitude <= 90 &&
      longitude >= -180 &&
      longitude <= 180;

  /// Equirectangular distance with longitude wrapped at the date line.
  static double _squaredDistance(double latitude, double longitude, City city) {
    final meanLatitude = (latitude + city.latitude) * math.pi / 360;
    final latitudeDelta = latitude - city.latitude;
    var longitudeDelta = (longitude - city.longitude).abs();
    if (longitudeDelta > 180) longitudeDelta = 360 - longitudeDelta;
    final eastWest = longitudeDelta * math.cos(meanLatitude);
    return latitudeDelta * latitudeDelta + eastWest * eastWest;
  }

  /// Nearest indexed city to the coordinate, or null when none lies within
  /// [maxKm]. Used to label GPS-derived locations. Timezone resolution keeps
  /// its own uncapped scan in [resolve] — do not couple the two cutoffs.
  static City? nearestCity({
    required double latitude,
    required double longitude,
    required Iterable<City> cities,
    double maxKm = 50,
  }) {
    if (!_isValidCoordinate(latitude, longitude)) return null;
    // _squaredDistance works in approximate degrees²; 1° ≈ 111.32 km.
    final maxDeg = maxKm / 111.32;
    final maxSquared = maxDeg * maxDeg;
    City? nearest;
    var nearestDistance = double.infinity;
    for (final city in cities) {
      final distance = _squaredDistance(latitude, longitude, city);
      if (distance < nearestDistance) {
        nearest = city;
        nearestDistance = distance;
      }
    }
    return nearestDistance <= maxSquared ? nearest : null;
  }
}
