// A best-effort gender cue for choosing a stand-in name (LM-55). Role words
// and pronouns in what the graph already says about the person come first,
// then a short list of common given names. No cue means no preference; the
// swap does not try harder than that.

import 'fake_names.dart';

const _femaleWords = {
  'sister', 'mother', 'mom', 'mum', 'mama', 'grandmother', 'grandma', 'aunt', 'wife', 'girlfriend', 'daughter',
  'niece', 'she', 'her', 'hers', 'woman', 'girl', 'ms', 'mrs', 'fiancee', 'stepmother', 'mother-in-law', 'ex-wife',
};
const _maleWords = {
  'brother', 'father', 'dad', 'papa', 'grandfather', 'grandpa', 'uncle', 'husband', 'boyfriend', 'son', 'nephew',
  'he', 'his', 'him', 'man', 'boy', 'mr', 'fiance', 'stepfather', 'father-in-law', 'ex-husband',
};
const _femaleNames = {
  'priya', 'samantha', 'sarah', 'emma', 'olivia', 'sophia', 'isabella', 'mia', 'amelia', 'anna', 'maria', 'laura',
  'julia', 'emily', 'jessica', 'jennifer', 'lisa', 'karen', 'susan', 'linda', 'maya', 'aisha', 'fatima', 'sneha',
  'anjali', 'pooja', 'kavya', 'ananya', 'misaki', 'yuki', 'hana', 'sakura', 'elena', 'natasha', 'olga', 'ingrid',
  'greta', 'rose', 'june', 'grace', 'hannah', 'rachel', 'rebecca', 'chloe', 'lucy', 'kate', 'katherine',
};
const _maleNames = {
  'john', 'james', 'michael', 'david', 'daniel', 'matthew', 'mark', 'paul', 'peter', 'robert', 'william', 'will',
  'thomas', 'joseph', 'ethan', 'noah', 'liam', 'lucas', 'oliver', 'henry', 'jack', 'ryan', 'arjun', 'rahul', 'amit',
  'vikram', 'rohan', 'ivan', 'dmitri', 'sergei', 'carlos', 'miguel', 'juan', 'teodor', 'hiroshi', 'kenji', 'takeshi',
};

Gender? inferGender({
  required String name,
  Iterable<String> aliases = const [],
  String? description,
  String? role,
  String? explicit,
}) {
  final e = explicit?.toLowerCase();
  if (e == 'f' || e == 'female' || e == 'woman') return Gender.female;
  if (e == 'm' || e == 'male' || e == 'man') return Gender.male;

  final words = RegExp(r"[a-z][a-z-]*")
      .allMatches('${role ?? ''} ${description ?? ''} ${aliases.join(' ')}'.toLowerCase())
      .map((m) => m.group(0)!);
  var f = 0, m = 0;
  for (final w in words) {
    if (_femaleWords.contains(w)) f++;
    if (_maleWords.contains(w)) m++;
  }
  if (f != m) return f > m ? Gender.female : Gender.male;

  final first = name.trim().split(RegExp(r'\s+')).first.toLowerCase();
  if (_femaleNames.contains(first)) return Gender.female;
  if (_maleNames.contains(first)) return Gender.male;
  return null;
}
