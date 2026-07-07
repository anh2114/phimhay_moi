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

class AssParser {
  /// Parse ASS/SSA content from string
  List<SubtitleEntry> parse(String content) {
    final entries = <SubtitleEntry>[];
    final lines = content.split('\n');
    bool inEvents = false;
    String format = '';

    for (final rawLine in lines) {
      final line = rawLine.trim();

      // Detect [Events] section
      if (line.toLowerCase() == '[events]') {
        inEvents = true;
        continue;
      }

      // Detect other sections → stop parsing events
      if (line.startsWith('[') && line.endsWith(']')) {
        inEvents = false;
        continue;
      }

      if (!inEvents) continue;

      // Parse Format line to get field order
      if (line.toLowerCase().startsWith('format:')) {
        format = line.substring(7).trim();
        continue;
      }

      // Parse Dialogue lines
      if (line.toLowerCase().startsWith('dialogue:') && format.isNotEmpty) {
        final entry = _parseDialogueLine(line, format, entries.length);
        if (entry != null) entries.add(entry);
      }
    }

    entries.sort((a, b) => a.start.compareTo(b.start));
    return entries;
  }

  SubtitleEntry? _parseDialogueLine(String line, String format, int index) {
    // Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,Text here
    final content = line.substring(9).trim(); // Remove "Dialogue:"
    final fields = _splitDialogueFields(content, format);
    if (fields == null) return null;

    final startField = fields['Start'] ?? '';
    final endField = fields['End'] ?? '';
    final textField = fields['Text'] ?? '';

    final start = _parseAssTime(startField);
    final end = _parseAssTime(endField);
    if (start == null || end == null) return null;

    // Clean ASS tags from text: {\b1}, {\pos(x,y)}, \N → newline, etc.
    String text = textField
        .replaceAll(RegExp(r'\{[^}]*\}'), '') // Remove override tags like {\b1}
        .replaceAll(r'\N', '\n')              // ASS newline
        .replaceAll(r'\n', '\n')              // SSA newline
        .replaceAll(r'\h', ' ')               // Hard space
        .trim();

    if (text.isEmpty) return null;

    return SubtitleEntry(
      index: index,
      start: start,
      end: end,
      text: text,
    );
  }

  /// Split ASS dialogue line into fields based on Format declaration
  /// Dialogue fields: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text
  /// Text field is always last and can contain commas, so we need special handling
  Map<String, String>? _splitDialogueFields(String content, String format) {
    final formatFields = format.split(',').map((f) => f.trim()).toList();
    if (formatFields.isEmpty) return null;

    final fields = <String, String>{};
    final values = content.split(',');
    final textIdx = formatFields.indexOf('Text');

    if (textIdx < 0 || textIdx >= values.length) return null;

    for (int i = 0; i < formatFields.length; i++) {
      if (i == textIdx) {
        // Text field: join remaining values (text can contain commas)
        fields[formatFields[i]] = values.sublist(i).join(',');
      } else if (i < values.length) {
        fields[formatFields[i]] = values[i].trim();
      }
    }

    return fields;
  }

  /// Parse ASS time format: H:MM:SS.CC (centiseconds)
  /// e.g. "0:00:01.50" → Duration(seconds: 1, milliseconds: 500)
  Duration? _parseAssTime(String time) {
    final match = RegExp(r'(\d+):(\d{2}):(\d{2})\.(\d{2})').firstMatch(time);
    if (match == null) return null;

    final hours = int.parse(match.group(1)!);
    final minutes = int.parse(match.group(2)!);
    final seconds = int.parse(match.group(3)!);
    final centiseconds = int.parse(match.group(4)!);

    return Duration(
      hours: hours,
      minutes: minutes,
      seconds: seconds,
      milliseconds: centiseconds * 10, // Centiseconds → milliseconds
    );
  }

  /// Fetch and parse ASS/SSA from URL
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

class VttParser {
  /// Parse WebVTT content from string
  List<SubtitleEntry> parse(String content) {
    final entries = <SubtitleEntry>[];
    final lines = content
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n');

    int i = 0;

    // Skip WEBVTT header and any metadata
    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.startsWith('WEBVTT') || line.isEmpty || line.startsWith('NOTE')) {
        // Skip NOTE blocks
        if (line.startsWith('NOTE')) {
          while (i < lines.length && lines[i].trim() != '') {
            i++;
          }
        }
        i++;
        continue;
      }
      break;
    }

    // Parse cue blocks
    while (i < lines.length) {
      // Skip empty lines
      if (lines[i].trim().isEmpty) {
        i++;
        continue;
      }

      // Collect cue lines (up to next empty line)
      final cueLines = <String>[];
      while (i < lines.length && lines[i].trim().isNotEmpty) {
        cueLines.add(lines[i]);
        i++;
      }

      if (cueLines.length < 2) continue;

      // Find timing line (contains -->)
      int timingIdx = -1;
      for (int j = 0; j < cueLines.length; j++) {
        if (cueLines[j].contains('-->')) {
          timingIdx = j;
          break;
        }
      }
      if (timingIdx < 0) continue;

      final times = cueLines[timingIdx].split('-->');
      if (times.length < 2) continue;

      final start = _parseVttTime(times[0].trim());
      final end = _parseVttTime(times[1].trim());
      if (start == null || end == null) continue;

      // Text: lines after timing line
      final text = cueLines
          .sublist(timingIdx + 1)
          .join('\n')
          .replaceAll(RegExp(r'<[^>]+>'), '') // Strip HTML tags
          .trim();

      if (text.isEmpty) continue;

      entries.add(SubtitleEntry(
        index: entries.length,
        start: start,
        end: end,
        text: text,
      ));
    }

    entries.sort((a, b) => a.start.compareTo(b.start));
    return entries;
  }

  /// Parse VTT time: HH:MM:SS.mmm or MM:SS.mmm
  Duration? _parseVttTime(String time) {
    // HH:MM:SS.mmm
    var match = RegExp(r'(\d+):(\d+):(\d+)\.(\d+)').firstMatch(time);
    if (match != null) {
      return Duration(
        hours: int.parse(match.group(1)!),
        minutes: int.parse(match.group(2)!),
        seconds: int.parse(match.group(3)!),
        milliseconds: int.parse(match.group(4)!.padRight(3, '0').substring(0, 3)),
      );
    }
    // MM:SS.mmm
    match = RegExp(r'(\d+):(\d+)\.(\d+)').firstMatch(time);
    if (match != null) {
      return Duration(
        minutes: int.parse(match.group(1)!),
        seconds: int.parse(match.group(2)!),
        milliseconds: int.parse(match.group(3)!.padRight(3, '0').substring(0, 3)),
      );
    }
    return null;
  }

  /// Fetch and parse WebVTT from URL
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
