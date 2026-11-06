/// The retention choice is offered once, after the third finished session.
const retentionOfferAfterSessions = 3;

bool shouldOfferRetention({
  required int completedSessions,
  required bool alreadyOffered,
}) =>
    !alreadyOffered && completedSessions >= retentionOfferAfterSessions;
