// Name pools per split. Train, val and test draw from disjoint lists, so no
// person, place, organisation or project name crosses splits (the "entity
// universe" split in the design). All names are invented or common given
// names; none refer to a real person, and none appear in eval/memory/scenarios.

export const SPLITS = ['train', 'val', 'test'];

const POOLS = {
  train: {
    first: ['Amara', 'Bruno', 'Celia', 'Dmitri', 'Esme', 'Farid', 'Greta', 'Hiro', 'Ines', 'Jonah', 'Kalani', 'Lucian', 'Mireille', 'Nikhil', 'Odile', 'Pavel', 'Quinn', 'Rosalind', 'Soren', 'Tamsin', 'Umar', 'Vesna', 'Wendell', 'Xiomara', 'Yusuf', 'Zelda', 'Anouk', 'Bastian', 'Coralie', 'Dario'],
    last: ['Abernathy', 'Bellweather', 'Castellano', 'Drummond', 'Eastwick', 'Fairbairn', 'Galloway', 'Holloway', 'Ibarra', 'Jankowski', 'Kerrigan', 'Lindqvist', 'Mbeki', 'Nakashima', 'Oyelaran', 'Pemberton', 'Quiroga', 'Rasmussen', 'Sorensen', 'Thackeray', 'Underhill', 'Varga', 'Whitlock', 'Yamada', 'Zielinski', 'Ashcombe', 'Brannigan', 'Cortazar', 'Delacroix', 'Engstrom'],
    town: ['Marrowby', 'Thistlewick', 'Coldharbour', 'Penhallow', 'Brightwater', 'Oakhurst', 'Saltmarsh', 'Fernleigh', 'Kestrel Bay', 'Granmoor', 'Hollins Cross', 'Redfern', 'Stonebridge', 'Wycombe Vale', 'Larchmont'],
    similarTowns: [['Ashworth', 'Ashwick'], ['Bramley', 'Bramford'], ['Corwin', 'Corbin'], ['Dunmore', 'Dunmere']],
    org: ['Halcyon', 'Ironbark', 'Juniper', 'Kingfisher', 'Lodestar', 'Meridian', 'Nightjar', 'Orchard', 'Pinnacle', 'Quarry', 'Riverstone', 'Sable'],
    orgSuffix: ['Labs', 'Logistics', 'Clinic', 'Studio', 'Bakery', 'Press'],
    project: ['greenhouse rebuild', 'family cookbook', 'canoe restoration', 'podcast pilot', 'quilt for the twins', 'garage gym', 'grant application', 'model railway'],
    event: ['harvest fair', 'book launch', 'charity 10k', 'retirement party', 'housewarming', 'jazz night'],
  },
  val: {
    first: ['Adaeze', 'Bertrand', 'Calla', 'Desmond', 'Elowen', 'Florin', 'Ginevra', 'Henrik', 'Isolde', 'Jasper', 'Keziah', 'Leopold', 'Marisol', 'Nolan', 'Ottoline', 'Percival', 'Rania', 'Stellan', 'Thea', 'Ulrich', 'Viveka', 'Wilhelmina', 'Yara', 'Zoltan', 'Aurelio', 'Briony', 'Cosimo', 'Dagny', 'Emrys', 'Fenella'],
    last: ['Ainsworth', 'Blackwood', 'Carrow', 'Dunleavy', 'Ellery', 'Fitzwilliam', 'Gilchrist', 'Hartigan', 'Irving', 'Jessop', 'Kowalczyk', 'Lachance', 'Moreau-Hill', 'Nygaard', 'Okonkwo', 'Prescott', 'Quintero', 'Ravenscroft', 'Sutherland', 'Tremaine', 'Urquhart', 'Valdivia', 'Winterbourne', 'Yeats', 'Zamora', 'Albright', 'Beaumont', 'Calloway', 'Dorsey', 'Everly'],
    town: ['Hazelmere', 'Brackenridge', 'Copperfield', 'Duskwater', 'Elmstead', 'Foxglove Hill', 'Gorse End', 'Heronsgate', 'Ivybridge', 'Juniper Falls', 'Kirkby Moor', 'Lindenhurst', 'Mossley', 'Northcote', 'Pebblebrook'],
    similarTowns: [['Elmore', 'Elmira'], ['Fairhaven', 'Fairhurst'], ['Glenbrook', 'Glenrock'], ['Halton', 'Hallam']],
    org: ['Amberline', 'Bluebell', 'Cobalt', 'Driftwood', 'Emberly', 'Foxtail', 'Granite', 'Harbourlight', 'Indigo', 'Jetstream', 'Keystone', 'Lantern'],
    orgSuffix: ['Systems', 'Partners', 'Pharmacy', 'Gallery', 'Brewery', 'Academy'],
    project: ['treehouse build', 'sourdough business plan', 'vintage bike repair', 'choir arrangement', 'community garden plot', 'novel draft', 'loft conversion', 'birdwatching log'],
    event: ['wine tasting', 'school reunion', 'craft market', 'anniversary dinner', 'chess tournament', 'open studio day'],
  },
  test: {
    first: ['Aisling', 'Benedikt', 'Cressida', 'Dashiell', 'Eulalie', 'Fintan', 'Gwendolyn', 'Hamish', 'Ilse', 'Jovan', 'Kiran', 'Lysander', 'Margaux', 'Niamh', 'Orson', 'Philippa', 'Rafferty', 'Saoirse', 'Tobiah', 'Ursula', 'Valentin', 'Winifred', 'Xavi', 'Ysolde', 'Zephyr', 'Annika', 'Barnaby', 'Clementine', 'Dorian', 'Evander'],
    last: ['Achterberg', 'Blythe', 'Cavendish', 'Darrow', 'Ellingham', 'Fenwick', 'Gaskell', 'Hargreaves', 'Inglis', 'Jardine', 'Kilbride', 'Lockhart', 'Marchetti', 'Northam', 'Osei', 'Penrose', 'Quayle', 'Rutherford', 'Strand', 'Tolliver', 'Uematsu', 'Vandermeer', 'Wexley', 'Yardley', 'Zabini', 'Arkwright', 'Bexley', 'Crowther', 'Dunstan', 'Elphick'],
    town: ['Wrenfield', 'Saltcote', 'Rookhaven', 'Quillmoor', 'Pellingham', 'Otterburn', 'Nethercott', 'Mistlebrook', 'Lowther Green', 'Kittering', 'Juniper Cove', 'Ironwick', 'Highcliff', 'Gullsworth', 'Fennimore'],
    similarTowns: [['Westmoor', 'Westmere'], ['Ravensby', 'Ravensdale'], ['Thornbury', 'Thornby'], ['Calder', 'Caldwell']],
    org: ['Alderglen', 'Bramblewood', 'Cinderfield', 'Dovetail', 'Everbright', 'Fieldstone', 'Glasswing', 'Hollowell', 'Ivorygate', 'Juniperline', 'Kestrelworks', 'Larkspur'],
    orgSuffix: ['Robotics', 'Insurance', 'Veterinary', 'Theatre', 'Roastery', 'Architects'],
    project: ['boat refit', 'recipe zine', 'allotment shed', 'violin restoration', 'family history archive', 'campervan conversion', 'mural commission', 'beekeeping setup'],
    event: ['film premiere', 'sailing regatta', 'poetry slam', 'engagement party', 'farmers market stall', 'marathon relay'],
  },
};

/** Flat name parts per kind for one split (what the disjointness checks compare). */
export function namePool(split) {
  const p = POOLS[split];
  if (!p) throw new Error(`unknown split ${split}`);
  return {
    first: [...p.first],
    last: [...p.last],
    town: [...p.town, ...p.similarTowns.flat()],
    org: [...p.org],
    orgSuffix: [...p.orgSuffix],
    project: [...p.project],
    event: [...p.event],
  };
}

export const rawPool = (split) => POOLS[split];
