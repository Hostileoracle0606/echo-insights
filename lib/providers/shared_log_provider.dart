import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/shared_log.dart';

/// The on-device "What Lumen shared" log (LM-57).
final sharedLogProvider = Provider<SharedLog>((ref) => SharedLog.instance);
