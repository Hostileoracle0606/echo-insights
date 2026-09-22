import 'package:permission_handler/permission_handler.dart';

enum MicPermission {
  granted,

  /// Not granted, but the system prompt can still be shown.
  denied,

  /// Only Settings can grant it. iOS shows the prompt exactly once; after
  /// "Don't Allow" (or a restriction) every request returns this.
  permanentlyDenied,
}

class MicPermissionService {
  const MicPermissionService();

  Future<MicPermission> status() async =>
      _map(await Permission.microphone.status);

  /// Prompts only when the system still allows it.
  Future<MicPermission> request() async {
    final current = _map(await Permission.microphone.status);
    if (current != MicPermission.denied) return current;
    return _map(await Permission.microphone.request());
  }

  Future<bool> openSettings() => openAppSettings();

  static MicPermission _map(PermissionStatus status) {
    if (status.isGranted || status.isLimited) return MicPermission.granted;
    if (status.isPermanentlyDenied || status.isRestricted) {
      return MicPermission.permanentlyDenied;
    }
    return MicPermission.denied;
  }
}
