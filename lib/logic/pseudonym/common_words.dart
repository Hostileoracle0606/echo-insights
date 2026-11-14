// Word lists for the name swap (LM-55). Bundled and small on purpose: the
// swap runs on the device and cannot lean on a system dictionary.

/// Ordinary English words a spelling-tolerant match must never turn into a
/// name, and a made-up name must never be. Lowercase. Not a dictionary: the
/// words most likely to sit one edit away from a name, to start a sentence,
/// or to be mistaken for a fake name.
final Set<String> commonWords = _words('''
a about above across act add after again against age ago agree air all allow almost alone along already also always am
among an and angry animal another answer any anyone anything appear are area arm around arrive art as ask at away baby
back bad bag ball bank bar base bath be bear beat beautiful because become bed been before began begin behind being
believe bell below best better between big bill bird bit black blue board boat body bone book born both bottom box boy
bread break bring brother brought brown build burn business but buy by call came can car care carry case catch cause
center certain chair chance change check child children choose church city class clean clear close cloud coat cold
college color come common company complete cook cool copy corner cost could count country course cover create cross cry
cut dad dance dark day dead deal dear decide deep did die different dinner do doctor does dog done door down draw dream
dress drink drive drop dry during each ear early earth east easy eat edge egg else end enjoy enough even evening ever
every everyone everything exactly eye face fact fall family far farm fast father fear feel feet fell few field fight
fill final find fine finger finish fire first fish fit five fix floor flower fly follow food foot for forget form found
four free friend from front full fun funny future game garden gave get girl give glad glass go god gold gone good got
great green ground group grow guess guy had hair half hall hand happen happy hard has hat have he head hear heard heart
heat heavy held hello help her here hers high hill him his hit hold hole holiday home hope horse hospital hot hotel hour
house how however hundred hurt i ice idea if important in inside instead into is it its job join just keep kept kid
kill kind king kitchen knew know lady land large last late laugh lay lead learn least leave left leg less let letter
lie life light like line lip list listen little live long look lose lost lot loud love low luck lunch made mail make man
many map market matter may maybe me mean meet men middle might mile milk mind mine minute miss mom money month moon more
morning most mother mountain mouth move movie much music must my name near need never new news next nice night nine no
noise none nor north nose not note nothing notice now number of off office often oh oil old on once one only open or
order other our out outside over own page paid pain pair paper parent park part party pass past pay peace people perfect
person phone pick picture piece place plan plant play please point pool poor power present pretty price problem pull
push put quick quiet quite rain ran reach read ready real really red remember rest rich ride right ring river road rock
room round run sad safe said same sat save saw say school sea season seat second see seem sell send sense sent serve
set seven several shall shape she ship shirt shoe shop short should shoulder show shut sick side sign silver simple
since sing sister sit six size skin sleep slow small smell smile snow so soft sold some someone something sometimes son
song soon sorry sound south speak special spell spend spoke spring square stand star start station stay step still stone
stop store story straight street strong student study such sudden sugar summer sun sure surprise sweet table take talk
tall teach team tell ten test than thank that the their them then there these they thick thin thing think third this
those though thought three through throw time tiny tired to today together told tomorrow tonight too took top touch
toward town train travel tree trip trouble true try turn twelve twenty two under understand until up upon us use usual
very visit voice wait walk wall want warm was wash watch water wave way we wear weather week weight well went were west
wet what wheel when where whether which while white who whole whom whose why wide wife wild win wind window winter wish
with without woman wonder wood word work world worry would write wrong yard year yes yesterday yet you young your
mark march rose june april august grace faith joy dawn amber ruby pearl daisy lily violet iris holly ivy olive willow
sky rain pat sue rob jack jay lane frank rich dean drew ray rick gene max miles sandy sunny penny dusty rocky chase
hunter grant mason cooper carter hector victor patient nurse manager boss friend neighbor teacher mayor
''');

/// Given names that are also ordinary words (lowercase). The graph's entity
/// of that name is only swapped where the use looks like a name.
final Set<String> nameWords = _words('''
will june rose may mark april august grace faith hope joy dawn amber ruby pearl daisy lily violet iris holly ivy olive
willow summer autumn winter sky rain pat sue rob jack jay lane frank rich dean drew ray rick gene max miles sandy sunny
penny dusty rocky chase hunter grant mason cooper carter bill art king earl bob don gary hank herb pearl randy skip
''');

Set<String> _words(String block) =>
    block.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toSet();

/// True for a name that is also an ordinary word (Will, June, Rose, May, Mark).
bool isWordName(String name) {
  final lower = name.trim().toLowerCase();
  return nameWords.contains(lower) || commonWords.contains(lower);
}
