// Which entities the swap replaces (LM-55): private identifiers only.
//
// The heuristic, deliberately small and decided by type first:
//   person        always replaced (a name identifies someone)
//   organization  replaced, unless it is a household-name company
//   place         replaced, unless it is a country, a US state or a large
//                 well-known city; streets, addresses and small towns stay
//                 private
//   everything else (events, activities, concepts, projects, emotions, other)
//                 is not a private identifier and is kept
// The two public lists are short. A name missing from them is replaced:
// replacing something public costs a little accuracy, leaking something
// private costs the user.

import '../../models/entity.dart';
import 'fake_names.dart';

/// What kind of stand-in an entity of [type] gets, or null when the swap
/// leaves that type alone.
PseudonymKind? pseudonymKindFor(EntityType type) => switch (type) {
      EntityType.person => PseudonymKind.person,
      EntityType.organization => PseudonymKind.org,
      EntityType.place => PseudonymKind.place,
      _ => null,
    };

/// True when [name] of [kind] is a private identifier the swap should hide.
bool isPrivateIdentifier(PseudonymKind kind, String name) {
  final key = name.trim().toLowerCase();
  return switch (kind) {
    PseudonymKind.person => true,
    PseudonymKind.org => !_publicOrgs.contains(key),
    PseudonymKind.place => !_publicPlaces.contains(key),
  };
}

final Set<String> _publicPlaces = {
  // Countries and regions
  'united states', 'usa', 'us', 'america', 'canada', 'mexico', 'brazil', 'argentina', 'chile', 'peru', 'colombia',
  'united kingdom', 'uk', 'england', 'scotland', 'wales', 'ireland', 'france', 'germany', 'spain', 'portugal',
  'italy', 'netherlands', 'belgium', 'switzerland', 'austria', 'sweden', 'norway', 'denmark', 'finland', 'poland',
  'russia', 'ukraine', 'turkey', 'greece', 'egypt', 'nigeria', 'kenya', 'south africa', 'india', 'pakistan',
  'bangladesh', 'china', 'japan', 'korea', 'south korea', 'vietnam', 'thailand', 'indonesia', 'philippines',
  'singapore', 'malaysia', 'australia', 'new zealand', 'israel', 'saudi arabia', 'iran', 'europe', 'asia', 'africa',
  'north america', 'south america', 'antarctica',
  // US states
  'alabama', 'alaska', 'arizona', 'arkansas', 'california', 'colorado', 'connecticut', 'delaware', 'florida',
  'georgia', 'hawaii', 'idaho', 'illinois', 'indiana', 'iowa', 'kansas', 'kentucky', 'louisiana', 'maine',
  'maryland', 'massachusetts', 'michigan', 'minnesota', 'mississippi', 'missouri', 'montana', 'nebraska', 'nevada',
  'new hampshire', 'new jersey', 'new mexico', 'new york', 'north carolina', 'north dakota', 'ohio', 'oklahoma',
  'oregon', 'pennsylvania', 'rhode island', 'south carolina', 'south dakota', 'tennessee', 'texas', 'utah',
  'vermont', 'virginia', 'washington', 'west virginia', 'wisconsin', 'wyoming',
  // Large, well-known cities
  'new york city', 'nyc', 'los angeles', 'chicago', 'houston', 'phoenix', 'philadelphia', 'san antonio', 'san diego',
  'dallas', 'san jose', 'austin', 'san francisco', 'seattle', 'denver', 'boston', 'miami', 'atlanta', 'las vegas',
  'portland', 'detroit', 'minneapolis', 'washington dc', 'toronto', 'vancouver', 'montreal', 'london', 'paris',
  'berlin', 'madrid', 'barcelona', 'rome', 'milan', 'amsterdam', 'vienna', 'zurich', 'stockholm', 'oslo',
  'copenhagen', 'dublin', 'edinburgh', 'moscow', 'istanbul', 'athens', 'cairo', 'lagos', 'nairobi', 'johannesburg',
  'cape town', 'dubai', 'mumbai', 'delhi', 'new delhi', 'bangalore', 'bengaluru', 'kolkata', 'chennai',
  'hyderabad', 'karachi', 'dhaka', 'beijing', 'shanghai', 'hong kong', 'tokyo', 'osaka', 'kyoto', 'seoul',
  'bangkok', 'jakarta', 'manila', 'sydney', 'melbourne', 'auckland', 'mexico city', 'sao paulo',
  'buenos aires', 'rio de janeiro', 'lima', 'bogota', 'santiago',
};

final Set<String> _publicOrgs = {
  'google', 'alphabet', 'apple', 'microsoft', 'amazon', 'meta', 'facebook', 'instagram', 'whatsapp', 'netflix',
  'tesla', 'nvidia', 'intel', 'ibm', 'oracle', 'salesforce', 'adobe', 'uber', 'lyft', 'airbnb', 'spotify', 'openai',
  'anthropic', 'twitter', 'x', 'linkedin', 'youtube', 'tiktok', 'reddit', 'github', 'walmart', 'target', 'costco',
  'starbucks', "mcdonald's", 'mcdonalds', 'nike', 'adidas', 'coca-cola', 'pepsi', 'disney', 'sony', 'samsung',
  'toyota', 'honda', 'ford', 'bmw', 'volkswagen', 'boeing', 'airbus', 'jpmorgan', 'goldman sachs', 'visa',
  'mastercard', 'paypal', 'stripe', 'harvard', 'harvard university', 'mit', 'stanford', 'stanford university',
  'yale', 'princeton', 'oxford', 'cambridge', 'columbia university', 'nasa', 'fbi', 'cia', 'un', 'united nations',
  'who', 'world health organization', 'red cross', 'unicef', 'bbc', 'cnn', 'new york times', 'wikipedia',
};
