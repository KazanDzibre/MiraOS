// Exercises Discover's genre and people queries against the real Seerr -
// read-only, and it never requests a title.
//
//   .toolchain/flutter/bin/dart run tool/probe_people.dart [query]
//
// Credentials come from ~/.config/mira/dev-server.json and are never printed.
import 'dart:convert';
import 'dart:io';

import 'package:mira_shell/overseerr/overseerr_client.dart';

Future<void> main(List<String> args) async {
  final Map<String, Object?> cfg = (jsonDecode(
              File('${Platform.environment['HOME']}/.config/mira/dev-server.json')
                  .readAsStringSync()) as Map<Object?, Object?>)
      .cast<String, Object?>();
  final OverseerrClient client = OverseerrClient(
    baseUrl: Uri.parse(cfg['overseerrUrl']! as String),
    apiKey: cfg['overseerrApiKey']! as String,
  );

  final List<DiscoverGenre> genres = await client.genres();
  stdout.writeln('genres: ${genres.length}');
  stdout.writeln('  ${genres.take(6).map((DiscoverGenre g) => '${g.name}(${g.id})').join(', ')}');

  if (genres.isNotEmpty) {
    final DiscoverPage page = await client.discoverGenre(genres.first.id);
    stdout.writeln('${genres.first.name}: ${page.results.length} on page 1 of ${page.totalPages}');
    stdout.writeln('  ${page.results.take(3).map((DiscoverTitle t) => t.title).join(' | ')}');
  }

  final String query = args.isEmpty ? 'nolan' : args.first;
  final ({DiscoverPage titles, List<DiscoverPerson> people}) found =
      await client.searchAll(query);
  stdout.writeln('search "$query": ${found.titles.results.length} titles, '
      '${found.people.length} people');
  for (final DiscoverPerson p in found.people.take(3)) {
    stdout.writeln('  ${p.name} - ${p.knownForLabel}');
  }

  if (found.people.isNotEmpty) {
    final DiscoverPerson person = found.people.first;
    final List<PersonCredit> credits = await client.personCredits(person.id);
    stdout.writeln('${person.name}: ${credits.length} credits');
    for (final PersonCredit c in credits.take(6)) {
      stdout.writeln('  ${c.title.year ?? '----'}  ${c.role.padRight(22)} ${c.title.title}');
    }
  }
  exit(0);
}
