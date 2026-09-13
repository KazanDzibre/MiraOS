import 'package:flutter_test/flutter_test.dart';
import 'package:mira_shell/player/webvtt.dart';

void main() {
  // The shape Jellyfin actually serves: a BOM, a Region header, CRLF endings.
  const String jellyfin = '﻿WEBVTT\r\n\r\n'
      'Region: id:subtitle width:80% lines:3 regionanchor:50%,100% viewportanchor:50%,90%\r\n\r\n'
      '00:02:02.730 --> 00:02:05.100 region:subtitle\r\n'
      '<i>The world is changed.</i>\r\n\r\n'
      '00:02:05.200 --> 00:02:08.000\r\n'
      '{\\an8}I feel it in the water.\r\n';

  test('reads Jellyfin output: BOM, Region header, CRLF, tags', () {
    final Subtitles s = Subtitles.parseWebVtt(jellyfin);
    expect(s.cues, hasLength(2));
    expect(s.cues.first.text, 'The world is changed.');
    expect(s.cues.last.text, 'I feel it in the water.');
    expect(s.cues.first.start, const Duration(minutes: 2, seconds: 2, milliseconds: 730));
  });

  test('accepts timestamps without hours', () {
    final Subtitles s = Subtitles.parseWebVtt('WEBVTT\n\n01:02.500 --> 01:04.000\nHello\n');
    expect(s.cues.single.start, const Duration(minutes: 1, seconds: 2, milliseconds: 500));
  });

  test('start is inclusive, end exclusive, gaps are empty', () {
    final Subtitles s = Subtitles.parseWebVtt(jellyfin);
    expect(s.textAt(const Duration(minutes: 2, seconds: 2, milliseconds: 730)), 'The world is changed.');
    expect(s.textAt(const Duration(minutes: 2, seconds: 5, milliseconds: 100)), isNull);
    expect(s.textAt(Duration.zero), isNull);
    expect(s.textAt(const Duration(hours: 3)), isNull);
  });

  test('overlapping cues are joined in order', () {
    final Subtitles s = Subtitles.parseWebVtt(
      'WEBVTT\n\n00:00:01.000 --> 00:00:05.000\nFirst\n\n00:00:02.000 --> 00:00:03.000\nSecond\n',
    );
    expect(s.textAt(const Duration(milliseconds: 2500)), 'First\nSecond');
  });

  test('skips NOTE blocks and empty cues', () {
    final Subtitles s = Subtitles.parseWebVtt(
      'WEBVTT\n\nNOTE made by hand\n\n00:00:01.000 --> 00:00:02.000\n\n\n00:00:03.000 --> 00:00:04.000\nKept\n',
    );
    expect(s.cues.single.text, 'Kept');
  });
}
