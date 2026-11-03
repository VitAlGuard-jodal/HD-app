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

class Room {
  const Room(this.code, this.name);
  factory Room.fromJson(JsonMap json) {
    final name = json['name'] as String?;
    return Room(
      json['code'] as String,
      name == null || name.trim().isEmpty ? null : name,
    );
  }
  final String code;
  final String? name;
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
  const Hello(this.self, [this.members = const []]);
  final String self;
  final List<Member> members;
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
