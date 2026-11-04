/// The retention choice is offered once, after the third finished session.
const retentionOfferAfterSessions = 3;

/// SharedPreferences key: set once the choice has been shown.
const retentionOfferedKey = 'transcript_retention_offered';

bool shouldOfferRetention({
  required int completedSessions,
  required bool alreadyOffered,
}) =>
    !alreadyOffered && completedSessions >= retentionOfferAfterSessions;
