class CallState {
  const CallState({
    this.roomCode,
    this.selfHandle,
    this.isStarting = false,
    this.isActive = false,
    this.isStopping = false,
    this.error,
  });
  factory CallState.fromMap(Map<Object?, Object?> map) => CallState(
    roomCode: map['roomCode'] as String?,
    selfHandle: map['selfHandle'] as String?,
    isStarting: map['isStarting'] as bool? ?? false,
    isActive: map['isActive'] as bool? ?? false,
    isStopping: map['isStopping'] as bool? ?? false,
    error: map['error'] as String?,
  );
  final String? roomCode;
  final String? selfHandle;
  final bool isStarting;
  final bool isActive;
  final bool isStopping;
  final String? error;
}
