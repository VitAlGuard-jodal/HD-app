import 'package:flutter/foundation.dart';
import 'meeting_plan.dart';

typedef JsonMap = Map<String, dynamic>;

class Avatar {
  const Avatar({this.kind, this.version = 0});
  factory Avatar.fromJson(Object? json) {
    if (json is! JsonMap) return const Avatar();
    final kind = json['kind'];
    final version = json['version'];
    return Avatar(
      kind: kind is String && (kind == 'photo' || mascotKinds.contains(kind))
          ? kind
          : null,
      version: version is int && version >= 0 ? version : 0,
    );
  }
  static const mascotKinds = [
    'mascot-01',
    'mascot-02',
    'mascot-03',
    'mascot-04',
    'mascot-05',
  ];
  final String? kind;
  final int version;
  bool get isMascot => mascotKinds.contains(kind);
  double get scale => kind == 'mascot-02' || kind == 'mascot-05' ? .82 : 1;
  JsonMap toJson() => {'kind': kind, 'version': version};
  @override
  bool operator ==(Object other) =>
      other is Avatar && kind == other.kind && version == other.version;
  @override
  int get hashCode => Object.hash(kind, version);
}

class User {
  const User(
    this.handle,
    this.displayName, {
    this.avatar = const Avatar(),
    this.order,
  });
  factory User.fromJson(JsonMap json) => User(
    json['handle'] as String,
    json['displayName'] as String,
    avatar: Avatar.fromJson(json['avatar']),
    order: json['order'] as int?,
  );
  final String handle;
  final String displayName;
  final Avatar avatar;
  final int? order;
}

class AuthResult {
  const AuthResult(this.user, this.token);
  final User user;
  final String token;
}

class MeResult {
  const MeResult(this.user, this.room, {this.consent});
  factory MeResult.fromJson(JsonMap json) {
    final room = json['room'] as JsonMap?;
    final consent = json['consent'] as JsonMap?;
    return MeResult(
      User.fromJson(json['user'] as JsonMap),
      room == null ? null : Room.fromJson(room),
      consent: consent == null ? null : ConsentRecord.fromJson(consent),
    );
  }
  final User user;
  final Room? room;
  final ConsentRecord? consent;
}

class ConsentRecord {
  const ConsentRecord({this.privacy, this.location});
  factory ConsentRecord.fromJson(JsonMap json) {
    ({String version, String at})? entry(Object? value) {
      if (value == null) return null;
      final data = value as JsonMap;
      return (version: data['version'] as String, at: data['at'] as String);
    }

    return ConsentRecord(
      privacy: entry(json['privacy']),
      location: entry(json['location']),
    );
  }
  final ({String version, String at})? privacy;
  final ({String version, String at})? location;
}

class Room {
  const Room(this.code, this.name, {this.leader});
  factory Room.fromJson(JsonMap json) {
    final name = json['name'] as String?;
    return Room(
      json['code'] as String,
      name == null || name.trim().isEmpty ? null : name,
      leader: json['leader'] as String?,
    );
  }
  final String code;
  final String? name;
  final String? leader;
}

class Member {
  const Member(
    this.handle,
    this.displayName,
    this.joinedAt, {
    this.avatar = const Avatar(),
    this.order,
    this.ready = false,
    this.readyRevision = 0,
  });
  factory Member.fromJson(JsonMap json) => Member(
    json['handle'] as String,
    json['displayName'] as String,
    json['joinedAt'] as String? ?? '',
    avatar: Avatar.fromJson(json['avatar']),
    ready: json['ready'] == true,
    readyRevision: (json['readyRevision'] as num?)?.toInt() ?? 0,
    order: json['order'] is int && (json['order'] as int) >= 0
        ? json['order'] as int
        : null,
  );
  final String handle;
  final String displayName;
  final String joinedAt;
  final Avatar avatar;
  final int? order;
  final bool ready;
  final int readyRevision;
  Member withAvatar(Avatar value) => Member(
    handle,
    displayName,
    joinedAt,
    avatar: value,
    order: order,
    ready: ready,
    readyRevision: readyRevision,
  );
  Member withReady(bool value, int revision) => Member(
    handle,
    displayName,
    joinedAt,
    avatar: avatar,
    order: order,
    ready: value,
    readyRevision: revision,
  );
}

class RoomDetails {
  const RoomDetails(this.room, this.members);
  final Room room;
  final List<Member> members;
}

class LocationFix {
  const LocationFix({
    required this.handle,
    this.stream = '',
    required this.lat,
    required this.lng,
    this.acc,
    this.src,
    this.speed,
    this.heading,
    required this.at,
    required this.seq,
    this.receivedAt = 0,
  });
  factory LocationFix.fromJson(JsonMap json) {
    num number(String key, {num? min, num? max, bool integer = false}) {
      final value = json[key];
      if (value is! num ||
          !value.isFinite ||
          (min != null && value < min) ||
          (max != null && value > max) ||
          (integer && value != value.truncateToDouble())) {
        throw const FormatException('위치 표본 숫자 범위 오류');
      }
      return value;
    }

    double? optional(String key, {num? max}) =>
        json[key] == null ? null : number(key, min: 0, max: max).toDouble();
    final handle = json['handle'];
    final stream = json['stream'];
    final src = json['src'];
    if (json.containsKey('src') && src != 'vehicle') {
      throw const FormatException('위치 표본 출처 오류');
    }
    if (handle is! String ||
        handle.isEmpty ||
        stream is! String ||
        !RegExp(r'^[0-9a-f]{16}$').hasMatch(stream)) {
      throw const FormatException('위치 표본 식별자 오류');
    }
    return LocationFix(
      handle: handle,
      stream: stream,
      lat: number('lat', min: -90, max: 90).toDouble(),
      lng: number('lng', min: -180, max: 180).toDouble(),
      acc: json.containsKey('acc') ? number('acc', min: 0).toDouble() : null,
      src: src as String?,
      speed: optional('speed'),
      heading: optional('heading', max: 360),
      at: number('at', min: 0),
      seq: number('seq', min: 0, max: 9007199254740991, integer: true).toInt(),
      receivedAt: number('receivedAt', min: 0),
    );
  }
  final String handle;
  final String stream;
  final double lat, lng;
  final double? acc, speed, heading;
  // Optional client-reported source; it grants no identity or permissions.
  final String? src;
  final num at;
  final int seq;
  // 송신 쪽은 서버 수신 시각을 아직 모르므로 0으로 둔다.
  final num receivedAt;

  JsonMap toJson() => {
    'stream': stream,
    'lat': lat,
    'lng': lng,
    if (acc != null) 'acc': acc,
    if (src != null) 'src': src,
    if (speed != null) 'speed': speed,
    if (heading != null) 'heading': heading,
    'at': at,
    'seq': seq,
  };

  Object get _values =>
      (handle, stream, lat, lng, acc, src, speed, heading, at, seq, receivedAt);
  @override
  bool operator ==(Object other) =>
      other is LocationFix && _values == other._values;
  @override
  int get hashCode => _values.hashCode;
}

bool _invalidLocationLogged = false;
void logInvalidLocation() {
  if (_invalidLocationLogged) return;
  _invalidLocationLogged = true;
  debugPrint('잘못된 위치 표본을 건너뛰었습니다');
}

LocationFix? tryLocationFix(Object? value) {
  try {
    if (value is! JsonMap) throw const FormatException();
    return LocationFix.fromJson(value);
  } on FormatException {
    logInvalidLocation();
    return null;
  }
}

List<LocationFix> locationPointsFromJson(Object? value) => value is List
    ? [
        for (final point in value)
          if (tryLocationFix(point) case final fix?) fix,
      ]
    : const [];

Map<String, List<LocationFix>> locationTrailsFromJson(JsonMap json) =>
    (json['trails'] as JsonMap? ?? {}).map(
      (handle, points) => MapEntry(handle, locationPointsFromJson(points)),
    );

class FollowRouteFeature {
  const FollowRouteFeature({required this.enabled});
  factory FollowRouteFeature.fromJson(Object? value) => FollowRouteFeature(
    enabled:
        value is JsonMap &&
        value['enabled'] == true &&
        value['provider'] == 'naver' &&
        value['routeOption'] == 'traoptimal',
  );
  final bool enabled;
}

class LocationSnapshot {
  const LocationSnapshot(
    this.positions,
    this.trails, {
    this.serverNowMs,
    this.followRoute,
    this.plans = const [],
    this.acceptedPlanFollowers = const [],
    this.meetingCapabilities = const MeetingCapabilities(),
  });
  factory LocationSnapshot.fromJson(JsonMap json) => LocationSnapshot(
    locationPointsFromJson(json['positions']),
    locationTrailsFromJson(json),
    serverNowMs: json['serverNowMs'] as num?,
    followRoute: FollowRouteFeature.fromJson(json['followRoute']),
    plans: List.unmodifiable(
      (json['followPlans'] as List? ?? []).map(MeetingPlanSnapshot.fromJson),
    ),
    acceptedPlanFollowers: List.unmodifiable(
      (json['acceptedPlanFollowers'] as List? ?? []).map(
        PlanParticipant.fromJson,
      ),
    ),
    meetingCapabilities: MeetingCapabilities.fromJson(json),
  );
  final List<LocationFix> positions;
  final Map<String, List<LocationFix>> trails;
  final num? serverNowMs;
  final FollowRouteFeature? followRoute;
  final List<MeetingPlanSnapshot> plans;
  final List<PlanParticipant> acceptedPlanFollowers;
  final MeetingCapabilities meetingCapabilities;
}

class FollowResult {
  const FollowResult(this.requestId, this.revision, this.accepted);
  factory FollowResult.fromJson(JsonMap json) => FollowResult(
    json['requestId'] as String,
    (json['revision'] as num).toInt(),
    json['accepted'] as bool,
  );
  final String requestId;
  final int revision;
  final bool accepted;
}

class IceServerCredentials {
  const IceServerCredentials(this.iceServers, this.ttlSeconds);
  factory IceServerCredentials.fromJson(JsonMap json) {
    final ttl = json['ttlSeconds'];
    final servers = json['iceServers'];
    if (ttl is! int || ttl <= 0 || servers is! List) {
      throw const FormatException('ICE 서버 응답이 올바르지 않습니다.');
    }
    return IceServerCredentials(
      servers.map((value) => Map<String, dynamic>.from(value as Map)).toList(),
      ttl,
    );
  }
  final List<JsonMap> iceServers;
  final int ttlSeconds;
}

class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
  @override
  String toString() => message;
}

sealed class RoomEvent {
  const RoomEvent();
}

final class Hello extends RoomEvent {
  const Hello(
    this.self, [
    this.members = const [],
    this.leader,
    this.positions = const [],
    this.trails = const {},
    this.followTarget,
    this.followRequests = const [],
    this.revision = 0,
    this.pendingFollow,
    this.followRequestId,
    this.serverNowMs,
    this.followRoute,
    this.plans = const [],
    this.acceptedPlanFollowers = const [],
    this.meetingCapabilities = const MeetingCapabilities(),
  ]);
  factory Hello.fromJson(JsonMap json) {
    final self = json['self'];
    final snapshot = LocationSnapshot.fromJson(json);
    return Hello(
      self is JsonMap ? self['handle'] as String? ?? '' : self as String? ?? '',
      (json['members'] as List<dynamic>? ?? [])
          .map((value) => Member.fromJson(value as JsonMap))
          .toList(),
      json['leader'] as String?,
      snapshot.positions,
      snapshot.trails,
      json['followTarget'] as String?,
      (json['followRequests'] as List<dynamic>? ?? [])
          .map((value) => FollowRequest.fromJson(value as JsonMap))
          .toList(),
      (json['revision'] as num?)?.toInt() ?? 0,
      json['pendingFollow'] as String?,
      json['followRequestId'] as String?,
      snapshot.serverNowMs,
      snapshot.followRoute,
      snapshot.plans,
      snapshot.acceptedPlanFollowers,
      snapshot.meetingCapabilities,
    );
  }
  final String self;
  final List<Member> members;
  final String? leader;
  final List<LocationFix> positions;
  final Map<String, List<LocationFix>> trails;
  final String? followTarget;
  final List<FollowRequest> followRequests;
  final int revision;
  final String? pendingFollow, followRequestId;
  final num? serverNowMs;
  final FollowRouteFeature? followRoute;
  final List<MeetingPlanSnapshot> plans;
  final List<PlanParticipant> acceptedPlanFollowers;
  final MeetingCapabilities meetingCapabilities;
}

final class FollowPlanParticipants extends RoomEvent {
  const FollowPlanParticipants(this.participants);
  final List<PlanParticipant> participants;
}

final class FollowPlanUpdated extends RoomEvent {
  const FollowPlanUpdated(this.snapshot);
  final MeetingPlanSnapshot snapshot;
}

final class FollowPlanProgress extends RoomEvent {
  const FollowPlanProgress(this.runtime);
  final MeetingRuntime runtime;
}

final class FollowPlanCleared extends RoomEvent {
  const FollowPlanCleared(
    this.planId,
    this.leaderHandle,
    this.revision,
    this.reason,
  );
  final String planId, leaderHandle, reason;
  final int revision;
}

final class FollowRequest extends RoomEvent {
  const FollowRequest(
    this.requester, {
    required this.requestId,
    this.displayName,
    this.revision = 0,
  });
  factory FollowRequest.fromJson(JsonMap json) => FollowRequest(
    json['requester'] as String,
    requestId: json['requestId'] as String,
    displayName: json['displayName'] as String?,
    revision: (json['revision'] as num?)?.toInt() ?? 0,
  );
  final String requester, requestId;
  final String? displayName;
  final int revision;
}

final class FollowCancelled extends RoomEvent {
  const FollowCancelled(
    this.requester, {
    required this.requestId,
    this.revision = 0,
    this.reason,
  });
  final String requester, requestId;
  final int revision;
  final String? reason;
}

final class FollowResponse extends RoomEvent {
  const FollowResponse(
    this.target,
    this.accepted, {
    required this.requestId,
    this.requester = '',
    this.revision = 0,
    this.reason,
  });
  final String target, requestId, requester;
  final bool accepted;
  final int revision;
  final String? reason;
}

final class TrailUpdated extends RoomEvent {
  const TrailUpdated(this.handle, this.points, {this.revision = 0});
  final String handle;
  final List<LocationFix> points;
  final int revision;
}

final class LocationUpdated extends RoomEvent {
  const LocationUpdated(this.fix, {this.revision = 0, this.serverNowMs});
  final LocationFix fix;
  final num? serverNowMs;
  final int revision;
}

final class LocationStopped extends RoomEvent {
  const LocationStopped(
    this.handle, {
    this.reason = 'stopped',
    this.revision = 0,
  });
  final String handle, reason;
  final int revision;
}

final class MemberJoined extends RoomEvent {
  const MemberJoined(this.handle, {this.revision = 0});
  final String handle;
  final int revision;
}

final class MemberUpdated extends RoomEvent {
  const MemberUpdated(this.handle, this.avatar);
  final String handle;
  final Avatar avatar;
}

final class MemberLeft extends RoomEvent {
  const MemberLeft(this.handle, {this.revision = 0});
  final String handle;
  final int revision;
}

final class Signal extends RoomEvent {
  const Signal(this.from, this.kind, this.payload);
  final String from;
  final String kind;
  final Object? payload;
}

final class ReadyChanged extends RoomEvent {
  const ReadyChanged(this.handle, this.ready, this.revision);
  factory ReadyChanged.fromJson(JsonMap json) => ReadyChanged(
    json['handle'] as String,
    json['ready'] as bool,
    (json['revision'] as num).toInt(),
  );
  final String handle;
  final bool ready;
  final int revision;
}

final class DeviceReplaced extends RoomEvent {
  const DeviceReplaced();
}

final class MemberDeviceChanged extends RoomEvent {
  const MemberDeviceChanged(this.handle);
  final String handle;
}

final class Reconnected extends RoomEvent {
  const Reconnected();
}

final class Disconnected extends RoomEvent {
  const Disconnected(this.message, this.retryInMillis);
  final String message;
  final int retryInMillis;
}
