import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/timing_marks.dart';

/// The app's timing recorder (silent unless built with LUMEN_TIMING=1).
/// Tests override it with a recording one.
final timingMarksProvider = Provider<TimingMarks>((_) => TimingMarks.instance);
