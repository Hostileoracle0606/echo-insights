import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// A socket that records what the client sends and lets the test play the
/// server.
class FakeLiveSocket extends StreamChannelMixin<dynamic>
    implements WebSocketChannel {
  FakeLiveSocket(this.uri);

  final Uri uri;
  final _incoming = StreamController<dynamic>();
  final sent = <Map<String, dynamic>>[];
  late final FakeLiveSink sinkImpl = FakeLiveSink(this);

  void serverSends(Map<String, dynamic> message) =>
      _incoming.add(jsonEncode(message));

  void serverCloses() => _incoming.close();

  Map<String, dynamic> get setup => sent.first['setup'] as Map<String, dynamic>;

  /// The kind of each message sent after setup, in order.
  List<String> get kindsAfterSetup =>
      [for (final message in sent.skip(1)) message.keys.single];

  List<int> get sentAudioBytes => [
        for (final message in audioFrames)
          ...base64.decode(
            ((message['realtime_input'] as Map)['audio'] as Map)['data']
                as String,
          ),
      ];

  List<Map<String, dynamic>> get audioFrames => [
        for (final message in sent)
          if ((message['realtime_input'] as Map?)?['audio'] != null) message,
      ];

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => sinkImpl;

  @override
  Future<void> get ready => Future.value();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => 1000;

  @override
  String? get closeReason => 'test';
}

class FakeLiveSink implements WebSocketSink {
  FakeLiveSink(this._socket);
  final FakeLiveSocket _socket;
  bool closed = false;

  @override
  void add(dynamic data) =>
      _socket.sent.add(jsonDecode(data as String) as Map<String, dynamic>);

  @override
  Future<void> close([int? closeCode, String? closeReason]) async =>
      closed = true;

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<dynamic> stream) async {}

  @override
  Future<void> get done => Future.value();
}

