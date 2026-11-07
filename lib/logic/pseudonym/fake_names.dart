// The stand-in names (LM-55, ruling R22: consistent fake names, not tags).
//
// A fixed, bundled list of fictional names, so the same install always draws
// from the same pool and nothing here needs the network. Chosen to be
// ordinary-sounding in English, not common words, and not famous people.

import 'common_words.dart';

enum PseudonymKind { person, place, org }

enum Gender { female, male }

/// How a fake name is chosen for a real one. The map only talks to this
/// interface, so the strategy (fake names today; tags if the spike were to
/// change its mind) can be replaced without touching matching or storage.
abstract interface class SurrogateStrategy {
  /// A new surrogate for an entity of [kind]. [seed] picks where in the pool
  /// to start (stable per entity); [isTaken] says whether a candidate cannot
  /// be used (real name, already issued, common word).
  String next({
    required PseudonymKind kind,
    required int seed,
    required bool Function(String candidate) isTaken,
    Gender? gender,
  });

  /// A second name for a person whose alias adds one ("Priya Raman").
  String surname({
    required int seed,
    required bool Function(String candidate) isTaken,
  });
}

class FakeNameStrategy implements SurrogateStrategy {
  const FakeNameStrategy();

  @override
  String next({
    required PseudonymKind kind,
    required int seed,
    required bool Function(String candidate) isTaken,
    Gender? gender,
  }) {
    final candidates = switch (kind) {
      PseudonymKind.person => _personCandidates(gender, seed),
      PseudonymKind.place => _placeCandidates(seed),
      PseudonymKind.org => _orgCandidates(seed),
    };
    for (final c in candidates) {
      if (!isTaken(c)) return c;
    }
    // Pools and combinations are exhausted (thousands of names): a lettered
    // variant is still a distinct, unreal name.
    final base = candidates.first;
    for (var i = 0; i < 26 * 26; i++) {
      final c =
          '$base ${String.fromCharCode(65 + i ~/ 26)}${String.fromCharCode(65 + i % 26)}';
      if (!isTaken(c)) return c;
    }
    return '$base ${seed.abs()}';
  }

  @override
  String surname({
    required int seed,
    required bool Function(String candidate) isTaken,
  }) {
    for (var i = 0; i < fakeSurnames.length; i++) {
      final c = fakeSurnames[(seed.abs() + i) % fakeSurnames.length];
      if (!isTaken(c)) return c;
    }
    return fakeSurnames[seed.abs() % fakeSurnames.length];
  }

  Iterable<String> _personCandidates(Gender? gender, int seed) sync* {
    final pools = switch (gender) {
      Gender.female => [fakeFemaleNames, fakeNeutralNames],
      Gender.male => [fakeMaleNames, fakeNeutralNames],
      null => [fakeFemaleNames, fakeMaleNames, fakeNeutralNames],
    };
    // Rotate through the matching pools so an unknown gender mixes them.
    final first = pools.first;
    for (var i = 0; i < first.length; i++) {
      for (var p = 0; p < pools.length; p++) {
        final pool = pools[p];
        yield pool[(seed.abs() + i) % pool.length];
        if (gender != null) break; // gendered: pool 0 first, neutral as backup
      }
    }
    for (final pool in pools) {
      for (var i = 0; i < pool.length; i++) {
        yield pool[(seed.abs() + i) % pool.length];
      }
    }
    // Full names when single names run out.
    for (var i = 0; i < fakeSurnames.length; i++) {
      for (final pool in pools) {
        for (var j = 0; j < pool.length; j++) {
          yield '${pool[(seed.abs() + j) % pool.length]} '
              '${fakeSurnames[(seed.abs() + i) % fakeSurnames.length]}';
        }
      }
    }
  }

  Iterable<String> _placeCandidates(int seed) sync* {
    for (var i = 0; i < fakePlaceNames.length; i++) {
      yield fakePlaceNames[(seed.abs() + i) % fakePlaceNames.length];
    }
    for (final a in fakePlacePrefixes) {
      for (final b in fakePlaceSuffixes) {
        yield '$a$b';
      }
    }
  }

  Iterable<String> _orgCandidates(int seed) sync* {
    for (var i = 0; i < fakeOrgNames.length; i++) {
      yield fakeOrgNames[(seed.abs() + i) % fakeOrgNames.length];
    }
    for (final a in fakeOrgHeads) {
      for (final b in fakeOrgTails) {
        yield '$a $b';
      }
    }
  }
}

/// Whether [fake] is acceptable as a stand-in on its own merits: no token is
/// an ordinary word. (An organisation's last word, "Labs", may be one.)
bool isPlausibleFake(String fake, PseudonymKind kind) {
  final tokens = fake.split(' ');
  final checked = kind == PseudonymKind.org ? tokens.take(1) : tokens;
  return checked.every((t) => !commonWords.contains(t.toLowerCase()));
}

const List<String> fakeFemaleNames = [
  'Anika', 'Nora', 'Greta', 'Vera', 'Elowen', 'Tamsin', 'Odalys', 'Linnea', 'Marisol', 'Thessaly', //
  'Corinne', 'Ysolde', 'Bronwen', 'Saoirse', 'Liora', 'Calista', 'Delphine', 'Imogen', 'Soraya', 'Tilda',
  'Ottilie', 'Fenella', 'Maren', 'Isolde', 'Katya', 'Lucinda', 'Mirela', 'Dagny', 'Philippa', 'Rhiannon',
  'Sabine', 'Anneliese', 'Cordelia', 'Beatrix', 'Henrietta', 'Marisa', 'Zofia', 'Leonora', 'Odette', 'Petra',
  'Alvina', 'Bettina', 'Carmela', 'Dorothea', 'Elspeth', 'Finola', 'Giselle', 'Hedda', 'Ilse', 'Janika',
];

const List<String> fakeMaleNames = [
  'Dennis', 'Anselm', 'Tobias', 'Leopold', 'Casimir', 'Evander', 'Lucian', 'Rafferty', 'Barnaby', 'Caspian', //
  'Dmitri', 'Emeric', 'Florian', 'Gideon', 'Hamish', 'Ignatius', 'Konrad', 'Lorcan', 'Mathias', 'Niall',
  'Osric', 'Percival', 'Quentin', 'Rupert', 'Silas', 'Thaddeus', 'Ulrich', 'Viggo', 'Warrick', 'Yannick',
  'Alaric', 'Bertrand', 'Cornelius', 'Desmond', 'Everett', 'Fabian', 'Gustav', 'Idris', 'Jasper', 'Kasimir',
  'Lowell', 'Magnus', 'Nikolai', 'Orlando', 'Radcliffe', 'Stellan', 'Tiberius', 'Valentin', 'Wendell',
];

const List<String> fakeNeutralNames = [
  'Marlow', 'Sutton', 'Ellis', 'Harlow', 'Sasha', 'Corin', 'Devon', 'Kendall', 'Lennox', //
  'Merritt', 'Sloane', 'Teagan', 'Arden', 'Blair', 'Calder', 'Dallas',
];

const List<String> fakeSurnames = [
  'Sethi', 'Ashworth', 'Brandt', 'Calloway', 'Devereux', 'Ellery', 'Fairchild', 'Garrity', 'Halloran', 'Ingram', //
  'Jessop', 'Kincaid', 'Lockhart', 'Marchetti', 'Nakamura', 'Okafor', 'Pemberton', 'Quigley', 'Rasmussen', 'Sandoval',
  'Thackeray', 'Vasquez', 'Whitlock', 'Yardley', 'Zielinski', 'Abernathy', 'Bellweather', 'Dunmore',
];

const List<String> fakePlaceNames = [
  'Millbrook', 'Fairhaven', 'Ashford', 'Kingsmere', 'Larchmont', 'Thornbury', 'Eastwick', 'Brackenridge', 'Hollowell', 'Stonehaven', //
  'Wexcombe', 'Alderbrook', 'Cresswell', 'Elmhurst', 'Foxhall', 'Glenrock', 'Harrowgate', 'Ironbridge', 'Kelderby', 'Lakemont',
  'Marlbourne', 'Northcott', 'Oakhaven', 'Pennbrook', 'Quillcrest', 'Ravenscar', 'Tidewell', 'Valmont', 'Westerleigh', 'Yarrowdale',
  'Briarcliff', 'Copperfield', 'Dovedale', 'Evenwood', 'Fernhollow', 'Greywater', 'Hartsmere', 'Inglewood', 'Jarrowby', 'Kestlebrook',
];

const List<String> fakePlacePrefixes = [
  'Ash', 'Briar', 'Cold', 'Dun', 'Elder', 'Fen', 'Glen', 'Hawk', 'Iron', 'Juniper', 'Kirk', 'Lang', 'Moor', 'North', 'Oak', 'Pine', 'Rook', 'Stone', 'Thorn', 'West',
];

const List<String> fakePlaceSuffixes = [
  'ford', 'field', 'wick', 'ton', 'bury', 'haven', 'mere', 'dale', 'combe', 'thorpe',
];

const List<String> fakeOrgNames = [
  'Brightwater Optics', 'Larkspur Labs', 'Northfield Analytics', 'Cobalt Harbor Systems', 'Redwater Logistics', //
  'Ironwood Partners', 'Meridian Foundry', 'Kingfisher Works', 'Copperline Studios', 'Halcyon Freight',
  'Summit Ridge Group', 'Tallow Row Media', 'Quillon Robotics', 'Evergreen Mills', 'Foxglove Dynamics',
  'Granite Bay Supply', 'Harborlight Health', 'Juniper Row Press', 'Kestrel Point Energy', 'Lumberton Tools',
  'Marigold Consulting', 'Nightingale Textiles', 'Orchard Lane Software', 'Pinecrest Biotech', 'Riverbend Dental',
];

const List<String> fakeOrgHeads = [
  'Amberfield', 'Birchwood', 'Cedarline', 'Driftwood', 'Elmstone', 'Fieldstone', 'Goldcrest', 'Highmark', 'Ivybridge', 'Kestrelwood',
];

const List<String> fakeOrgTails = [
  'Partners', 'Group', 'Labs', 'Works', 'Systems', 'Studio', 'Holdings', 'Industries', 'Collective', 'Associates',
];
