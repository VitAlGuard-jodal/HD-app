import 'dart:async';

const meshMemberLimit = 4;
const meshCapacityReason = '음성 통화는 먼저 입장한 4명까지 참여할 수 있습니다.';
const meshRecoveryTimeout = Duration(seconds: 8);
const meshOfferTimeout = Duration(seconds: 8);
const _maxPeerRetries = 3;

enum MeshPeerState { connecting, connected, failed, closed }

typedef MeshSignalSender =
    Future<void> Function(String to, String kind, Map<String, Object?> payload);
typedef MeshPeerFactory =
    Future<MeshPeer> Function(
      String handle,
      void Function(Map<String, Object?> candidate) onCandidate,
      void Function(MeshPeerState state) onState,
    );

// No Flutter or WebRTC dependency: the coordinator owns ordering and glare;
// the adapter owns SDP application and the platform connection.
abstract interface class MeshPeer {
  Future<Map<String, Object?>> createOffer({bool iceRestart = false});
  Future<Map<String, Object?>> answerOffer(Map<String, Object?> offer);
  Future<void> acceptAnswer(Map<String, Object?> answer);
  Future<void> addCandidate(Map<String, Object?> candidate);
  Future<void> close();
}

class MeshCoordinator {
  MeshCoordinator({
    required this.selfHandle,
    required this.createPeer,
    required this.sendSignal,
    required this.sessionId,
    this.onPeerState,
    this.onError,
  });

  final String selfHandle;
  final String sessionId;
  final MeshPeerFactory createPeer;
  final MeshSignalSender sendSignal;
  final void Function(String handle, MeshPeerState state)? onPeerState;
  final void Function(Object error)? onError;
  final Map<String, _PeerSlot> _peers = {};
  final Map<String, List<Map<String, Object?>>> _pendingIce = {};
  final Set<String> _ignored = {};
  List<String> _members = [];
  Future<void> _tail = Future<void>.value();
  Future<void>? _closeFuture;
  bool _closed = false;
  bool _joined = false;
  int _offerNumber = 0;

  Set<String> get peers => Set.unmodifiable(_peers.keys);
  Map<String, MeshPeerState> get peerStates => Map.unmodifiable({
    for (final entry in _peers.entries) entry.key: entry.value.state,
  });
  Future<void> get idle => _tail;

  // The server orders hello.members by joinedAt, then handle for ties.
  static List<String> admitted(Iterable<String> members) =>
      members.toSet().take(meshMemberLimit).toList();
  static bool canJoin(String self, Iterable<String> members) =>
      admitted(members).contains(self);

  Future<void> join(Iterable<String> members) {
    if (_joined || _closed) throw StateError('이미 사용한 메시 세션입니다.');
    _members = members.toSet().toList();
    if (!canJoin(selfHandle, _members)) throw StateError(meshCapacityReason);
    _joined = true;
    return _enqueue(() async {
      // Only the newcomer offers to the hello snapshot. member-joined merely
      // updates admission; incumbents wait for the newcomer's offer.
      for (final handle in admitted(_members)) {
        if (_closed) return;
        if (handle != selfHandle) {
          await _forPeer(handle, () => _offer(handle));
        }
      }
    });
  }

  Future<void> updateMembers(Iterable<String> members) {
    _members = members.toSet().toList();
    return _enqueue(() async {
      for (final handle in _peers.keys.toList()) {
        if (!_allows(handle)) await _drop(handle);
      }
      _pendingIce.removeWhere(
        (key, _) => !_members.contains(key.split('/').first),
      );
    });
  }

  // On SSE return, either side may have missed the newcomer's first offer.
  // Keep live peers and negotiations; the usual glare rule resolves new offers.
  Future<void> reconcile(Iterable<String> members) async {
    await updateMembers(members);
    await _enqueue(() async {
      for (final handle in admitted(_members)) {
        if (!_allows(handle)) continue;
        final slot = _peers[handle];
        if (slot != null &&
            (slot.state == MeshPeerState.connected ||
                slot.offerPending ||
                slot.recovering ||
                slot.offerTimer != null)) {
          continue;
        }
        await _forPeer(handle, () async {
          await _drop(handle, replacing: true);
          await _offer(handle);
        });
      }
    });
  }

  Future<void> onSignal(String from, String kind, Object? payload) => _enqueue(
    () => _forPeer(from, () async {
      if (!_allows(from) || payload is! Map) return;
      final data = Map<String, Object?>.from(payload);
      final id = data['negotiationId'];
      if (id is! String || id.isEmpty || id.length > 200) return;
      final key = '$from/$id';
      if (_ignored.contains(key)) return;
      switch (kind) {
        case 'offer':
          if (data['type'] != 'offer' || data['sdp'] is! String) return;
          var slot = _peers[from];
          final recoveryAttempts = slot?.retryAttempts ?? 0;
          final offerAttempts = slot?.offerAttempts ?? 0;
          final recovering = slot?.recovering ?? false;
          if (slot?.id == id && slot!.remoteDescription) return;
          if (slot?.state == MeshPeerState.failed) {
            // A terminal local offer may still be installed in native SDP.
            // A new remote negotiation needs a fresh peer, not that stale SDP.
            await _drop(from, replacing: true);
            slot = null;
          }
          if (slot != null && slot.offerPending) {
            if (selfHandle.compareTo(from) < 0) {
              // Lexicographically smaller handle keeps its local offer.
              _ignore(key);
              // The first offer may have arrived before this member pressed
              // Join call (or before its SSE connected). Replay it and ICE.
              final offer = slot.localOffer;
              if (offer != null) {
                await sendSignal(from, 'offer', {
                  ...offer,
                  'negotiationId': slot.id,
                });
                for (final ice in slot.localIce) {
                  await sendSignal(from, 'ice', {
                    ...ice,
                    'negotiationId': slot.id,
                  });
                }
              }
              return;
            }
            // Recreate instead of relying on native SDP rollback support.
            await _drop(from, replacing: true);
            slot = null;
          }
          if (slot?.peer == null) slot = await _newPeer(from);
          if (slot == null || !_current(from, slot)) return;
          slot.offerTimer?.cancel();
          slot.offerTimer = null;
          slot.offerAttempts = offerAttempts;
          // Glare can replace the native peer, but cannot reset its retry
          // budget or leave a silent recovery without a response deadline.
          if (recovering) {
            slot.retryAttempts = recoveryAttempts;
            slot.recovering = true;
            _schedulePeerRetry(from, slot);
          }
          if (slot.id != null && slot.id != id) _ignore('$from/${slot.id}');
          slot.id = id;
          slot.remoteDescription = false;
          slot.offerPending = false;
          slot.localOffer = null;
          slot.localIce.clear();
          final answer = await slot.peer!.answerOffer(data);
          if (!_current(from, slot)) return;
          slot.remoteDescription = true;
          await _flushIce(from, slot);
          await sendSignal(from, 'answer', {...answer, 'negotiationId': id});
        case 'answer':
          final slot = _peers[from];
          if (slot == null ||
              !slot.offerPending ||
              slot.id != id ||
              data['type'] != 'answer' ||
              data['sdp'] is! String)
            return;
          await slot.peer!.acceptAnswer(data);
          if (!_current(from, slot)) return;
          slot.offerPending = false;
          slot.remoteDescription = true;
          slot.offerTimer?.cancel();
          slot.offerTimer = null;
          await _flushIce(from, slot);
        case 'ice':
          if (data['candidate'] is! String) return;
          final slot = _peers[from];
          if (slot != null && slot.id == id && slot.remoteDescription) {
            await slot.peer!.addCandidate(data);
          } else {
            if (_pendingIce.length >= 32 && !_pendingIce.containsKey(key)) {
              _pendingIce.remove(_pendingIce.keys.first);
            }
            final pending = _pendingIce.putIfAbsent(key, () => []);
            if (pending.length < 128) pending.add(data);
          }
        case 'custom':
          if (data['type'] == 'mesh-left' && _peers[from]?.id == id) {
            await _drop(from);
          }
      }
    }),
  );

  // After credentials change, only one side initiates each ICE restart.
  Future<void> restartIce() => _enqueue(() async {
    for (final handle in _peers.keys.toList()) {
      if (_closed) return;
      final slot = _peers[handle]!;
      if (slot.recovering ||
          slot.state == MeshPeerState.failed ||
          slot.peer == null && slot.offerTimer != null)
        continue;
      await _forPeer(handle, () async {
        if (_peers[handle]!.offerPending) {
          // An unanswered offer may contain an allocation using old TURN
          // credentials. Rebuild it so a late join never replays expired ICE.
          final attempts = slot.offerAttempts;
          await _drop(handle, replacing: true);
          if (!_allows(handle)) return;
          _peers[handle] = _PeerSlot()..offerAttempts = attempts;
          await _offer(handle);
        } else if (selfHandle.compareTo(handle) < 0) {
          await _offer(handle, iceRestart: true);
        }
      });
    }
  });

  Future<void> _offer(String handle, {bool iceRestart = false}) async {
    if (!_allows(handle)) return;
    final existing = _peers[handle];
    final slot = existing?.peer != null ? existing : await _newPeer(handle);
    if (slot == null || !_current(handle, slot)) return;
    if (slot.id != null) _ignore('$handle/${slot.id}');
    final id = '$selfHandle:$sessionId:${++_offerNumber}';
    slot.id = id;
    slot.offerPending = true;
    slot.remoteDescription = false;
    slot.localIce.clear();
    final offer = await slot.peer!.createOffer(iceRestart: iceRestart);
    if (_current(handle, slot)) {
      slot.localOffer = offer;
      await sendSignal(handle, 'offer', {...offer, 'negotiationId': id});
      _scheduleOfferTimeout(handle, slot, id);
    }
  }

  void _scheduleOfferTimeout(String handle, _PeerSlot slot, String id) {
    // ICE recovery already has its own bounded 2/4/8-second deadlines.
    if (!_current(handle, slot) || !slot.offerPending || slot.recovering)
      return;
    slot.offerTimer?.cancel();
    late final Timer deadline;
    deadline = Timer(meshOfferTimeout, () {
      unawaited(
        _enqueue(() async {
          if (!_current(handle, slot) ||
              !slot.offerPending ||
              slot.id != id ||
              !identical(slot.offerTimer, deadline))
            return;
          slot.offerTimer = null;
          if (slot.offerAttempts >= _maxPeerRetries) {
            slot.retryAttempts = _maxPeerRetries;
            _failPeer(handle, slot);
            return;
          }
          final attempts = slot.offerAttempts + 1;
          await _drop(handle, replacing: true);
          if (!_allows(handle)) return;
          final next = _PeerSlot()..offerAttempts = attempts;
          _peers[handle] = next;
          _publishPeer(handle, next, MeshPeerState.connecting);
          // Each unanswered peer closes at 8s. Additional backoff makes offer
          // send intervals 8/16/24s; the final offer also gets exactly 8s to answer.
          if (attempts == 1) {
            await _forPeer(handle, () => _offer(handle));
          } else {
            late final Timer backoff;
            backoff = Timer(meshOfferTimeout * (attempts - 1), () {
              unawaited(
                _enqueue(() async {
                  if (_current(handle, next) &&
                      identical(next.offerTimer, backoff)) {
                    next.offerTimer = null;
                    await _forPeer(handle, () => _offer(handle));
                  }
                }).catchError((Object _) {}),
              );
            });
            next.offerTimer = backoff;
          }
        }).catchError((Object _) {}),
      );
    });
    slot.offerTimer = deadline;
  }

  Future<_PeerSlot?> _newPeer(String handle) async {
    final slot = _peers[handle] ?? _PeerSlot();
    _peers[handle] = slot;
    _publishPeer(handle, slot, MeshPeerState.connecting);
    try {
      slot.peer = await createPeer(
        handle,
        (candidate) {
          final id = slot.id;
          if (id == null || !_current(handle, slot)) return;
          if (slot.localIce.length < 128) slot.localIce.add(candidate);
          unawaited(
            _enqueue(
              () => _forPeer(handle, () async {
                if (_current(handle, slot) && slot.id == id) {
                  await sendSignal(handle, 'ice', {
                    ...candidate,
                    'negotiationId': id,
                  });
                }
              }),
            ).catchError((Object _) {}),
          );
        },
        (state) {
          if (!_current(handle, slot)) return;
          if (state == MeshPeerState.connected) {
            slot.offerTimer?.cancel();
            slot.offerTimer = null;
            slot.offerAttempts = 0;
            slot.retryTimer?.cancel();
            slot.retryTimer = null;
            slot.retryAttempts = 0;
            slot.recovering = false;
            _publishPeer(handle, slot, state);
          } else if (state == MeshPeerState.failed ||
              state == MeshPeerState.closed) {
            _failPeer(handle, slot);
          } else if (slot.recovering || slot.retryAttempts < _maxPeerRetries) {
            _publishPeer(handle, slot, state);
          }
        },
      );
      if (!_current(handle, slot)) {
        if (identical(_peers[handle], slot)) _peers.remove(handle);
        await slot.peer!.close();
        onPeerState?.call(handle, MeshPeerState.closed);
        return null;
      }
      return slot;
    } catch (_) {
      if (_current(handle, slot)) _failPeer(handle, slot);
      return null;
    }
  }

  void _publishPeer(String handle, _PeerSlot slot, MeshPeerState state) {
    slot.state = state;
    onPeerState?.call(handle, state);
  }

  // Negotiation and ICE failures belong to this peer, never to the entire call.
  Future<void> _forPeer(String handle, Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      final slot = _peers[handle];
      if (slot != null && _current(handle, slot)) _failPeer(handle, slot);
    }
  }

  void _failPeer(String handle, _PeerSlot slot) {
    if (!_current(handle, slot)) return;
    slot.offerTimer?.cancel();
    slot.offerTimer = null;
    if (slot.retryAttempts >= _maxPeerRetries) {
      slot.retryTimer?.cancel();
      slot.retryTimer = null;
      slot.recovering = false;
      slot.offerPending = false;
      _publishPeer(handle, slot, MeshPeerState.failed);
      return;
    }
    slot.recovering = true;
    _publishPeer(handle, slot, MeshPeerState.connecting);
    _schedulePeerRetry(handle, slot);
  }

  void _schedulePeerRetry(String handle, _PeerSlot slot) {
    if (!_current(handle, slot) || !slot.recovering || slot.retryTimer != null)
      return;
    final exhausted = slot.retryAttempts >= _maxPeerRetries;
    final delay = exhausted
        ? meshRecoveryTimeout
        : Duration(seconds: 2 << slot.retryAttempts);
    slot.retryTimer = Timer(delay, () {
      slot.retryTimer = null;
      if (!_current(handle, slot) || !slot.recovering) return;
      if (exhausted) {
        _failPeer(handle, slot);
        return;
      }
      unawaited(
        _enqueue(() async {
          // Recheck after queued SDP work: recovery/leave may have won the race.
          if (!_current(handle, slot) || !slot.recovering) return;
          slot.retryAttempts++;
          await _forPeer(handle, () => _offer(handle, iceRestart: true));
          // A silent peer may never emit another failed event. Keep a bounded
          // response deadline, including after the third and final restart.
          _schedulePeerRetry(handle, slot);
        }).catchError((Object _) {}),
      );
    });
  }

  Future<void> _flushIce(String handle, _PeerSlot slot) async {
    for (final candidate
        in _pendingIce.remove('$handle/${slot.id}') ??
            <Map<String, Object?>>[]) {
      if (!_current(handle, slot)) return;
      await slot.peer!.addCandidate(candidate);
    }
  }

  bool _allows(String handle) =>
      !_closed &&
      _joined &&
      handle != selfHandle &&
      canJoin(selfHandle, _members) &&
      admitted(_members).contains(handle);
  bool _current(String handle, _PeerSlot slot) =>
      _allows(handle) && identical(_peers[handle], slot);

  void _ignore(String key) {
    _pendingIce.remove(key);
    _ignored.add(key);
    if (_ignored.length > 128) _ignored.remove(_ignored.first);
  }

  Future<void> _drop(String handle, {bool replacing = false}) async {
    final slot = _peers.remove(handle);
    if (slot == null) return;
    slot.retryTimer?.cancel();
    slot.offerTimer?.cancel();
    slot.recovering = false;
    if (slot.id != null) _ignore('$handle/${slot.id}');
    if (replacing) {
      // Keep a connecting placeholder while native close is awaited. Otherwise
      // the remaining failed peers could briefly look like a terminal mesh, or
      // a concurrent member removal could miss this slot and leave stale state.
      final replacement = _PeerSlot();
      _peers[handle] = replacement;
      _publishPeer(handle, replacement, MeshPeerState.connecting);
    }
    try {
      await slot.peer?.close();
    } finally {
      if (!replacing) onPeerState?.call(handle, MeshPeerState.closed);
    }
  }

  Future<void> close() {
    final closing = _closeFuture;
    if (closing != null) return closing;
    _closed = true; // Invalidate in-flight factory/SDP work immediately.
    for (final slot in _peers.values) {
      slot.retryTimer?.cancel();
      slot.offerTimer?.cancel();
      slot.recovering = false;
    }
    return _closeFuture = _enqueue(() async {
      Object? firstError;
      StackTrace? firstStack;
      for (final handle in _peers.keys.toList()) {
        final id = _peers[handle]?.id;
        if (id != null) {
          // A disconnected signaling server must not delay local teardown.
          unawaited(
            sendSignal(handle, 'custom', {
              'type': 'mesh-left',
              'negotiationId': id,
            }).catchError((Object _) {}),
          );
        }
        try {
          await _drop(handle);
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
      _pendingIce.clear();
      _ignored.clear();
      if (firstError != null)
        Error.throwWithStackTrace(firstError, firstStack!);
    });
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.catchError((Object error) {
      if (!_closed) onError?.call(error);
    });
    return result;
  }
}

class _PeerSlot {
  MeshPeer? peer;
  MeshPeerState state = MeshPeerState.connecting;
  Timer? retryTimer;
  Timer? offerTimer;
  int offerAttempts = 0;
  int retryAttempts = 0;
  bool recovering = false;
  String? id;
  bool offerPending = false;
  bool remoteDescription = false;
  Map<String, Object?>? localOffer;
  final List<Map<String, Object?>> localIce = [];
}
