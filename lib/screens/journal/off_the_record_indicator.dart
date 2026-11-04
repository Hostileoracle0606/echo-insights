import 'package:flutter/material.dart';

import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

/// The words under the "Off the record" label. After saved turns it says
/// plainly that they stay; before any, there is nothing to keep.
String offTheRecordNote({required bool earlierSaved}) => earlierSaved
    ? 'Nothing from here on is saved. What you said earlier stays.'
    : 'Nothing in this conversation is saved.';

/// What the switch says when it goes back on the record.
const onTheRecordNote =
    'Saving resumes. What you said off the record stays unsaved.';

/// Always visible on the session screen, in the transcript and the graph,
/// while the conversation is off the record (LM-50).
class OffTheRecordIndicator extends StatelessWidget {
  const OffTheRecordIndicator({super.key, required this.earlierSaved});

  final bool earlierSaved;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    return Semantics(
      container: true,
      label: 'Off the record. ${offTheRecordNote(earlierSaved: earlierSaved)}',
      excludeSemantics: true,
      child: Container(
        key: const Key('offTheRecordIndicator'),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: colors.highlight,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: colors.amberSoft),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                Icons.visibility_off_outlined,
                size: 15,
                color: colors.youLabel,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Off the record',
                    style: TextStyle(
                      fontFamily: LumenText.sansFontFamily,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: colors.youLabel,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    offTheRecordNote(earlierSaved: earlierSaved),
                    style: TextStyle(
                      fontFamily: LumenText.sansFontFamily,
                      fontSize: 12,
                      height: 1.3,
                      color: colors.ink,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
