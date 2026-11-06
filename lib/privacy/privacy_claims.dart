/// Every privacy claim the app makes about where a journal goes (LM-53).
///
/// The source is docs/security/ai-processing.md (LM-43), sections 1 and 6.
/// Nothing here claims zero retention or that Lumen is unable to read a
/// journal: neither is true today. A claim gets stronger only by flipping a
/// flag below, and only after the fact behind it is verified.
library;

/// Flip to true only once billing is on for the paid Gemini API and the
/// checks in LM-43 section 4 are done (including the web key, Groq and
/// ElevenLabs paths, since the claim is about the iOS app's surface).
const bool paidTierVerified = false;

/// Flip to true only once "Your journal is encrypted on Supabase's servers"
/// has been checked against Supabase's own documentation for this project.
const bool supabaseEncryptionVerified = false;

/// Controls that live on other branches. Their lines render only when the
/// feature is in this set; whoever merges a feature adds its id here.
enum PrivacyFeature { forgetPerson, offTheRecord, autoForget }

const Set<PrivacyFeature> shipped = <PrivacyFeature>{};

/// The Google line for the screen and the page.
String googleClaim({bool verified = paidTierVerified}) => verified
    ? "Your voice and text are processed by Google's paid Gemini API, which "
        'under Google\'s terms does not use them to train its models. Google '
        'may keep them for a limited period for abuse detection and legal '
        'reasons.'
    : "Lumen sends your voice and text to Google's Gemini service to talk "
        'with you.';

const googleDetail =
    'Your voice goes live while you talk. Afterwards the text of what was '
    'said goes too, to pick out people and places, to write your cards and '
    'briefs, and to speak the line Lumen opens with.';

const awsClaim =
    'Amazon Web Services runs the processing behind Lumen. It handles the '
    'text of your conversations briefly while that work happens.';

const supabaseClaim =
    'Supabase stores your journal: your conversations, cards and the map of '
YY

const supabaseEncryptedClaim =
    "Your journal is encrypted on Supabase's servers.";

// docs/security/admin-access.md (LM-45): dashboard SQL is not reliably logged
// by the platform, so the promise is the written log, and only that.
const usClaim =
    "Our rule is that we don't read journals, except for a security incident "
    'or a request from you about your own data. Each exception goes in a '
    'written log. Nothing technically stops us yet.';

const phoneClaim =
    'Anyone who can unlock your phone and open Lumen can read your journal. '
    'App lock asks for Face ID or your passcode first. You can turn it on '
    'under Privacy.';

const exportClaim =
    'Your journal is yours to take: Privacy has "Export my journal", a zip '
    'of your conversations, cards and map as data and as notes.';

/// Lines for controls that may not have shipped; shown only when listed in
/// the `shipped` set passed to the screen.
const Map<PrivacyFeature, String> gatedClaims = {
  PrivacyFeature.forgetPerson:
      'You can ask Lumen to forget a person, and they leave your journal.',
  PrivacyFeature.offTheRecord:
      'Off the record: you can talk without it being kept.',
  PrivacyFeature.autoForget:
      'You can have old conversations forgotten automatically.',
};
