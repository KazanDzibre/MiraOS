import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/core/track_choice.dart';
import 'package:mira_shell/jellyfin/models.dart';

void main() {
  const MediaTrack englishAt3 = MediaTrack(index: 3, kind: TrackKind.subtitle, language: 'eng', codec: 'subrip');
  const MediaTrack serbianAt4 = MediaTrack(index: 4, kind: TrackKind.subtitle, language: 'srp', codec: 'subrip');

  test('a choice finds the same track on the same file', () {
    const MediaItem episode = MediaItem(id: 'e1', name: 'One', tracks: <MediaTrack>[englishAt3, serbianAt4]);
    final TrackChoice back = TrackChoice.fromPrefs(const TrackChoice(subtitle: serbianAt4).toPrefs(), episode);
    expect(back.subtitle?.index, 4);
  });

  test("a show's choice carries to an episode that numbers its tracks differently", () {
    const MediaItem next = MediaItem(id: 'e2', name: 'Two', tracks: <MediaTrack>[
      MediaTrack(index: 2, kind: TrackKind.subtitle, language: 'eng', codec: 'subrip'),
      MediaTrack(index: 5, kind: TrackKind.subtitle, language: 'srp', codec: 'subrip'),
    ]);
    final TrackChoice back = TrackChoice.fromPrefs(const TrackChoice(subtitle: serbianAt4).toPrefs(), next);
    expect(back.subtitle?.index, 5, reason: 'the Serbian subtitle was not found at its new index');
  });

  test('a language the episode does not have falls back to off, not to another language', () {
    const MediaItem next = MediaItem(id: 'e3', name: 'Three', tracks: <MediaTrack>[englishAt3]);
    final TrackChoice back = TrackChoice.fromPrefs(const TrackChoice(subtitle: serbianAt4).toPrefs(), next);
    expect(back.subtitle, isNull);
  });
}
