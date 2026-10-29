// The app's real route table. Leaving a notebook goes to its closing card;
// if the card were a child of /notebook/:id, the JournalScreen would stay
// mounted beneath it, rebuild with the card's URL (autoStart flips to false),
// re-enter the notebook it just left and, for a new notebook, start a live
// session behind the card.
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lumen/app.dart';

void main() {
  List<String> matchedPaths(String location) {
    final router = GoRouter(routes: appRoutes);
    addTearDown(router.dispose);
    return [
      for (final match
          in router.configuration.findMatch(Uri.parse(location)).matches)
        (match.route as GoRoute).path,
    ];
  }

  test('the closing card is not stacked on the notebook it closes', () {
    expect(matchedPaths('/notebook/nb-1/card'), ['/notebook/:id/card']);
  });

  test('a notebook still opens on its own route', () {
    expect(matchedPaths('/notebook/nb-1?start=true'), ['/notebook/:id']);
    expect(matchedPaths('/notebook/nb-1'), ['/notebook/:id']);
  });
}
