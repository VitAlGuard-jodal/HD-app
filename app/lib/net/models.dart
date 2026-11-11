typedef JsonMap = Map<String, dynamic>;

class User {
  const User(this.handle, this.displayName);
  factory User.fromJson(JsonMap json) =>
      User(json['handle'] as String, json['displayName'] as String);
  final String handle;
  final String displayName;
}

class AuthResult {
  const AuthResult(this.user, this.token);
  final User user;
  final String token;
}

class MeResult {
  const MeResult(this.user, this.room);
  factory MeResult.fromJson(JsonMap json) {
    final room = json['room'] as JsonMap?;
    return MeResult(
      User.fromJson(json['user'] as JsonMap),
      room == null ? null : Room.fromJson(room),
    );
  }
  final User user;
  final Room? room;
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
  const Member(this.handle, this.displayName, this.joinedAt);
  factory Member.fromJson(JsonMap json) => Member(
    json['handle'] as String,
    json['displayName'] as String,
    json['joinedAt'] as String? ?? '',
  );
  final String handle;
  final String displayName;
  final String joinedAt;
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
    this.speed,
    this.heading,
    required this.at,
    required this.seq,
    this.receivedAt = 0,
  });
  factory LocationFix.fromJson(JsonMap json) => LocationFix(
    handle: json['handle'] as String,
    stream: json['stream'] as String? ?? '',
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
    acc: (json['acc'] as num?)?.toDouble(),
    speed: (json['speed'] as num?)?.toDouble(),
    heading: (json['heading'] as num?)?.toDouble(),
    at: json['at'] as num,
    seq: json['seq'] as int,
    receivedAt: json['receivedAt'] as num,
  );
  final String handle;
  final String stream;
  final double lat, lng;
  final double? acc, speed, heading;
  final num at;
  final int seq;
  // 송신 쪽은 서버 수신 시각을 아직 모르므로 0으로 둔다.
  final num receivedAt;

  JsonMap toJson() => {
    'stream': stream,
    'lat': lat,
    'lng': lng,
    if (acc != null) 'acc': acc,
    if (speed != null) 'speed': speed,
    if (heading != null) 'heading': heading,
    'at': at,
    'seq': seq,
  };

  Object get _values =>
      (handle, stream, lat, lng, acc, speed, heading, at, seq, receivedAt);
  @override
  bool operator ==(Object other) =>
      other is LocationFix && _values == other._values;
  @override
  int get hashCode => _values.hashCode;
}

Map<String, List<LocationFix>> locationTrailsFromJson(JsonMap json) =>
    (json['trails'] as JsonMap? ?? {}).map(
      (handle, points) => MapEntry(
        handle,
        (points as List<dynamic>)
            .map((value) => LocationFix.fromJson(value as JsonMap))
            .toList(),
      ),
    );

class LocationSnapshot {
  const LocationSnapshot(this.positions, this.trails);
  factory LocationSnapshot.fromJson(JsonMap json) => LocationSnapshot(
    (json['positions'] as List<dynamic>? ?? [])
        .map((value) => LocationFix.fromJson(value as JsonMap))
        .toList(),
    locationTrailsFromJson(json),
  );
  final List<LocationFix> positions;
  final Map<String, List<LocationFix>> trails;
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
      (json['followRequests'] as List<dynamic>? ?? []).cast<String>(),
    );
  }
  final String self;
  final List<Member> members;
  final String? leader;
  final List<LocationFix> positions;
  final Map<String, List<LocationFix>> trails;
  final String? followTarget;
  final List<String> followRequests;
}

final class FollowRequest extends RoomEvent {
  const FollowRequest(this.requester);
  final String requester;
}

final class FollowCancelled extends RoomEvent {
  const FollowCancelled(this.requester);
  final String requester;
}

final class FollowResponse extends RoomEvent {
  const FollowResponse(this.target, this.accepted, {this.reason});
  final String target;
  final bool accepted;
  final String? reason;
}

final class TrailsUpdated extends RoomEvent {
  const TrailsUpdated(this.trails);
  final Map<String, List<LocationFix>> trails;
}

final class LocationUpdated extends RoomEvent {
  const LocationUpdated(this.fix);
  final LocationFix fix;
}

final class LocationStopped extends RoomEvent {
  const LocationStopped(this.handle);
  final String handle;
}

final class MemberJoined extends RoomEvent {
  const MemberJoined(this.handle);
  final String handle;
}

final class MemberLeft extends RoomEvent {
  const MemberLeft(this.handle);
  final String handle;
}

final class Signal extends RoomEvent {
  const Signal(this.from, this.kind, this.payload);
  final String from;
  final String kind;
  final Object? payload;
}

final class Reconnected extends RoomEvent {
  const Reconnected();
}

final class Disconnected extends RoomEvent {
  const Disconnected(this.message, this.retryInMillis);
  final String message;
  final int retryInMillis;
}
