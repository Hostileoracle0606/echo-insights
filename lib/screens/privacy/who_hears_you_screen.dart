import 'package:flutter/material.dart';

import '../../privacy/privacy_claims.dart' as claims;
import '../../theme/lumen_colors.dart';
import '../../theme/lumen_text.dart';

/// Opens [WhoHearsYouScreen] over the current screen. Resolves to true when
/// the user chose to go on, false when they closed it.
Future<bool> showWhoHearsYou(
  BuildContext context, {
  bool firstTime = false,
}) async {
  final go = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => WhoHearsYouScreen(firstTime: firstTime),
    ),
  );
  return go ?? false;
}

/// "Who hears you" (LM-53): each party that sees any of your journal, and
/// what it sees. All wording lives in privacy_claims.dart; this screen only
/// lays it out. [firstTime] adds the button that starts the conversation.
class WhoHearsYouScreen extends StatelessWidget {
  const WhoHearsYouScreen({
    super.key,
    this.firstTime = false,
    this.paidTierVerified = claims.paidTierVerified,
    this.supabaseEncryptionVerified = claims.supabaseEncryptionVerified,
    this.shipped = claims.shipped,
  });

  final bool firstTime;
  final bool paidTierVerified;
  final bool supabaseEncryptionVerified;
  final Set<claims.PrivacyFeature> shipped;

  @override
  Widget build(BuildContext context) {
    final colors = context.lumenColors;
    final body = TextStyle(
      fontFamily: LumenText.sansFontFamily,
      fontSize: 15,
      height: 1.45,
      color: colors.ink,
    );
    final gated = [
      for (final feature in claims.PrivacyFeature.values)
        if (shipped.contains(feature)) claims.gatedClaims[feature]!,
    ];
    return Scaffold(
      backgroundColor: colors.paper,
      appBar: AppBar(
        backgroundColor: colors.paper,
        elevation: 0,
        title: const Text('Who hears you'),
        leading: IconButton(
          key: const Key('privacyClose'),
          tooltip: 'Close',
          icon: Icon(Icons.close, color: colors.ink),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      bottomNavigationBar: firstTime
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton(
                key: const Key('privacyContinue'),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Got it, start'),
              ),
            )
          : null,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
          children: [
            Text(
              'Your journal is yours. Here are the services that handle it, '
              'and what each one sees.',
              style: body,
            ),
            const SizedBox(height: 8),
            Text(claims.reachClaim, style: body),
            const SizedBox(height: 20),
            _Party(
              keyName: 'google',
              name: 'Google',
              lines: [
                claims.googleClaim(verified: paidTierVerified),
                claims.googleDetail,
              ],
              style: body,
            ),
            _Party(
              keyName: 'aws',
              name: 'Amazon Web Services',
              lines: const [claims.awsClaim],
              style: body,
            ),
            _Party(
              keyName: 'supabase',
              name: 'Supabase',
              lines: [
                claims.supabaseClaim,
                if (supabaseEncryptionVerified) claims.supabaseEncryptedClaim,
              ],
              style: body,
            ),
            _Party(
              keyName: 'us',
              name: 'Us',
              lines: const [claims.usClaim],
              style: body,
            ),
            _Party(
              keyName: 'phone',
              name: 'Anyone holding your phone',
              lines: const [claims.phoneClaim],
              style: body,
            ),
            _Party(
              keyName: 'controls',
              name: 'What you can do',
              lines: [claims.exportClaim, claims.sharedLogClaim, ...gated],
              style: body,
            ),
          ],
        ),
      ),
    );
  }
}

class _Party extends StatelessWidget {
  const _Party({
    required this.keyName,
    required this.name,
    required this.lines,
    required this.style,
  });

  final String keyName;
  final String name;
  final List<String> lines;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('party_$keyName'),
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            name,
            style: style.copyWith(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(line, style: style),
            ),
        ],
      ),
    );
  }
}
