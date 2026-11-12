// ignore_for_file: experimental_member_use
import 'package:lumen/services/account_auth_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A stand-in for Supabase Auth that records what the service asked of it.
class FakeAuthGateway implements AuthGateway {
  FakeAuthGateway({this.nonce = 'raw-nonce-123'});

  final String nonce;
  final calls = <String>[];
  final rpcCalls = <(String, Map<String, dynamic>?)>[];

  String? signedInToken;
  String? signedInNonce;
  String? linkedToken;
  String? linkedNonce;
  Map<String, dynamic>? savedName;

  /// What the next sign-in returns.
  AuthResponse response = AuthResponse(user: fakeUser());
  Object? signInError;
  Object? linkError;
  Object? nameError;
  AuthResponse? passkeyResponse;
  bool passkeyRegisters = true;
  List<UserIdentity> identityList = const [];
  List<Passkey> passkeyList = const [];
  Object? rpcResult;

  @override
  String generateRawNonce() => nonce;

  @override
  Future<AuthResponse> signInWithAppleToken(String idToken, String n) async {
    calls.add('signInWithApple');
    signedInToken = idToken;
    signedInNonce = n;
    if (signInError != null) throw signInError!;
    return response;
  }

  @override
  Future<AuthResponse> linkAppleToken(String idToken, String n) async {
    calls.add('linkApple');
    linkedToken = idToken;
    linkedNonce = n;
    if (linkError != null) throw linkError!;
    return response;
  }

  @override
  Future<void> setUserName(Map<String, dynamic> data) async {
    calls.add('setUserName');
    if (nameError != null) throw nameError!;
    savedName = data;
  }

  @override
  Future<List<UserIdentity>> identities() async => identityList;

  @override
  Future<AuthResponse?> signInWithPasskey() async {
    calls.add('signInWithPasskey');
    if (signInError != null) throw signInError!;
    return passkeyResponse;
  }

  @override
  Future<bool> registerPasskey() async {
    calls.add('registerPasskey');
    return passkeyRegisters;
  }

  @override
  Future<List<Passkey>> listPasskeys() async => passkeyList;

  @override
  Future<void> deletePasskey(String id) async => calls.add('deletePasskey:$id');

  @override
  Future<Object?> rpc(String function, [Map<String, dynamic>? params]) async {
    rpcCalls.add((function, params));
    final r = rpcResult;
    if (r is Error || r is Exception) throw r as Object;
    return r;
  }
}

User fakeUser({
  DateTime? created,
  DateTime? lastSignIn,
  String? email = 'a@b.com',
}) {
  final c = created ?? DateTime.utc(2026, 1, 1);
  return User(
    id: 'user-1',
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: c.toIso8601String(),
    lastSignInAt: (lastSignIn ?? DateTime.utc(2026, 11, 12)).toIso8601String(),
    email: email,
  );
}
