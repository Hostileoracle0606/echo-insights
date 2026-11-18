// A complete, valid session for tests. Override any field.
export function validSession(overrides = {}) {
  return {
    participant: 'P1',
    date: '2026-11-20',
    device: 'simulator',
    consent: true,
    secondsToFirstTurn: 42,
    firstTurnMode: 'voice',
    tasks: { talk: 'yes', find: 'with_help', correct: 'no' },
    listeningStateWhenAsked: 'not_listening',
    comprehension: { listening: 'correct', purpose: 'partial', keeps: 'wrong' },
    confusions: [{ task: 'talk', code: 'mic_state' }],
    quotes: [{ text: 'It was clear when it heard me.', approved: true }],
    notes: '',
    ...overrides,
  };
}
