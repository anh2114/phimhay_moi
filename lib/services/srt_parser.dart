import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'api_client.dart';

class SubtitleEntry {
  final int index;
  final Duration start;
  final Duration end;
  final String text;

  const SubtitleEntry({
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });
}

class SrtParser {
  /// Parse SRT content from string
  List<SubtitleEntry> parse(String content) {
    final entries = <SubtitleEntry>[];
    final blocks = content.trim().split(RegExp(r'\n\s*\n'));

    for (final block in blocks) {
      final lines = block.trim().split('\n');
      if (lines.length < 2) continue;

      // First line: index number
      int? index;
      try {
        index = int.parse(lines[0].trim());
      } catch (_) {
        continue;
      }

      // Second line: timestamps "00:01:23,456 --> 00:01:25,789"
      final timeMatch = RegExp(
        r'(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->\s*(\d{2}):(\d{2}):(\d{2})[,.](\d{3})',
      ).firstMatch(lines[1].trim());

      if (timeMatch == null) continue;

      final start = Duration(
        hours: int.parse(timeMatch.group(1)!),
        minutes: int.parse(timeMatch.group(2)!),
        seconds: int.parse(timeMatch.group(3)!),
        milliseconds: int.parse(timeMatch.group(4)!),
      );

      final end = Duration(
        hours: int.parse(timeMatch.group(5)!),
        minutes: int.parse(timeMatch.group(6)!),
        seconds: int.parse(timeMatch.group(7)!),
        milliseconds: int.parse(timeMatch.group(8)!),
      );

      // Remaining lines: subtitle text (may span multiple lines)
      final text = lines.skip(2).join('\n').trim();
      if (text.isEmpty) continue;

      entries.add(SubtitleEntry(
        index: index,
        start: start,
        end: end,
        text: text,
      ));
    }

    // Sort by start time
    entries.sort((a, b) => a.start.compareTo(b.start));
    return entries;
  }

  /// Fetch and parse SRT from URL
  Future<List<SubtitleEntry>> fetchAndParse(String url) async {
    try {
      final response = await ApiClient.dio.get(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      return parse(response.data.toString());
    } catch (e) {
      return [];
    }
  }
}
