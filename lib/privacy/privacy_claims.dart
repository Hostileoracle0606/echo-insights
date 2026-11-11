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

/// Controls whose lines render only when the feature is in this set. A line
/// joins it only once the control is in the app.
enum PrivacyFeature { forgetPerson, offTheRecord, autoForget }

const Set<PrivacyFeature> shipped = <PrivacyFeature>{
  PrivacyFeature.forgetPerson,
  PrivacyFeature.offTheRecord,
  PrivacyFeature.autoForget,
};

/// The Google line for the screen and the page.
String googleClaim({bool verified = paidTierVerified}) => verified
    ? "Your voice and text are processed by Google's paid Gemini API, which "
        'under Google\'s terms does not use them to train its models. Google '
        'may keep them for a limited period for abuse detection and legal '
        'reasons.'
    : "Lumen sends your voice and text to Google's Gemini service to talk "
        'with you.';

// LM-56: extraction, cards and briefs get stand-in names (ruling R24); the
// live voice path and the spoken opening line do not.
const googleDetail =
    'While you talk, your voice goes to Google live. What Lumen tells '
    'Google during a conversation can also carry things you said in '
    'earlier conversations and your opening brief, with names as you said '
    "them. In the iPhone app, Lumen's text model gets made-up names "
    'instead: the text of each turn, sent as you go to pick out people '
    'and places, and the text sent when a conversation ends to write your '
    'cards and brief. Your phone swaps the names of people, private '
    'places and organizations it recognizes before sending and swaps them '
    "back when the answer returns. A name it doesn't recognize, such as a "
    "nickname it hasn't learned, can still go through as you said it. The "
    "one line Lumen opens your next conversation with goes to Google's "
    'voice with real names, so it is read aloud right.';

const awsClaim =
    'Amazon Web Services runs the processing behind Lumen. It handles the '
    'text of your conversations while that work happens, and keeps the '
    'people, places and notes it pulls out of each turn in a cache for '
    'about a week.';

const reachClaim =
    'The companies running these services can in principle reach data on '
    'their own systems, and backups can outlive a delete for a limited '
    'time.';

const supabaseClaim =
    'Supabase stores your journal: your conversations, cards and the map of '
    "people and places. It isn't encrypted with a key only you hold, so the "
    'people with admin access to the database could technically read it. A '
    'written rule limits that access.';

const supabaseEncryptedClaim =
    "Your journal is encrypted on Supabase's servers.";

// docs/security/admin-access.md (LM-45): dashboard SQL is not reliably logged
// by the platform, so the promise is the written log, and only that.
const usClaim =
    "Our rule is that we don't read journals, except for a security incident "
    'or a request from you about your own data. Each exception goes in a '
    'written log. Nothing technically stops us.';

const phoneClaim =
    'Anyone who can unlock your phone and open Lumen can read your journal. '
    'App lock asks for Face ID or your passcode first. You can turn it on '
    'under Privacy.';

const exportClaim =
    'Your journal is yours to take: Privacy has "Export my journal", a zip '
    'of your conversations, cards and map as data and as notes.';

// LM-57. The live voice conversation is not in the log, so the line says so.
const sharedLogClaim =
    'In the iPhone app you can see exactly what Lumen sent for each session, '
    'kept on your phone for 7 days. The live voice conversation is not '
    'part of it. Forgetting a person clears it.';

/// Lines for controls that may not have shipped; shown only when listed in
/// the `shipped` set passed to the screen.
const Map<PrivacyFeature, String> gatedClaims = {
  PrivacyFeature.forgetPerson:
      'You can forget a person from their page. They leave your map and the '
      'questions Lumen would ask, and their name is replaced in your cards '
      "and in what Lumen remembers about others. Mentioning that name later "
      "doesn't bring them back. Lumen matches the name they were saved under, "
      'so a nickname or a first name alone can slip through. Your saved '
      'transcripts keep what you said, and Lumen can still read your past '
      'conversations, so it may bring the name up.',
  PrivacyFeature.offTheRecord:
      "Off the record: Lumen doesn't save what you say while it is on, and "
      'writes no card from it. Your voice still goes to Google so Lumen can '
      'answer.',
  PrivacyFeature.autoForget:
      'You can have old transcripts deleted automatically after 7, 30 or 90 '
      'days. Cards and what Lumen remembers stay.',
};
