enum MicMode { car, phone }

class MicDevice {
  const MicDevice(this.id, this.type, this.name);
  factory MicDevice.fromMap(Map<Object?, Object?> map) =>
      MicDevice(map['id'] as int, map['type'] as int, map['name'] as String);
  final int id;
  final int type;
  final String name;
}

class MicRanker {
  static const _headsets = {7, 22, 3};
  static const _excluded = {28, 16, 25, 18, 21};

  static List<MicDevice> rank(MicMode mode, List<MicDevice> devices) {
    int priority(MicDevice device) {
      if (mode == MicMode.car)
        return device.type == 15
            ? 0
            : (_headsets.contains(device.type) ? 1 : 2);
      return _headsets.contains(device.type) ? 0 : (device.type == 15 ? 1 : 2);
    }

    // Dart sort는 안정 정렬이 아니므로 같은 순위는 원래 인덱스로 정렬한다.
    final indexed = devices.indexed
        .where((e) => !_excluded.contains(e.$2.type))
        .toList();
    indexed.sort((a, b) {
      final byPriority = priority(a.$2).compareTo(priority(b.$2));
      return byPriority != 0 ? byPriority : a.$1.compareTo(b.$1);
    });
    return indexed.map((e) => e.$2).toList();
  }
}
