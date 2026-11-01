import 'dart:io';

import 'package:path/path.dart' as p;

import '../../utils/app_logger.dart';
import '../library_index/library_index.dart';
import '../trackers/trakt/trakt_client.dart';
import 'ai_agent.dart';
import 'claude_client.dart';

/// Runs the eval prompt list through the helper on each model and writes a
/// markdown report: picks, whether each is on the servers, tool calls, time,
/// tokens and cost. Developer tool (Settings ▸ AI, debug builds).
abstract final class AiEval {
  static const String promptsFile = r'C:\shieldExperience\notes\ai-eval-prompts.txt';

  static Future<String> run({
    required LibraryIndex index,
    TraktClient? trakt,
    List<ClaudeModel> models = ClaudeModel.values,
    void Function(String progress)? onProgress,
  }) async {
    final prompts = [
      for (final raw in await File(promptsFile).readAsLines())
        if (raw.trim().isNotEmpty && !raw.trim().startsWith('#')) raw.trim(),
    ];
    final stamp = DateTime.now().toIso8601String().substring(0, 16).replaceAll(':', '');
    final out = StringBuffer('# AI helper eval — $stamp\n\n');
    final summary = StringBuffer(
      '| # | Prompt | Model | Picks | All on servers | Tool calls | Time | Tokens in/out (cached) | Cost |\n'
      '|---|---|---|---:|---|---:|---:|---|---:|\n',
    );
    final totals = <ClaudeModel, double>{};
    for (final model in models) {
      final agent = AiAgent(index: index, trakt: trakt, model: model);
      for (final (i, raw) in prompts.indexed) {
        final karims = raw.startsWith('karim:');
        final prompt = karims ? raw.substring(6).trim() : raw;
        onProgress?.call('${model.name} ${i + 1}/${prompts.length}');
        final a = await agent.ask(prompt);
        totals[model] = (totals[model] ?? 0) + a.cost;
        final label = '${karims ? '(Karim) ' : ''}$prompt';
        summary.writeln(
          '| ${i + 1} | ${label.replaceAll('|', '/')} | ${model.name} | ${a.picks.length} | '
          '${a.error != null ? 'error' : (a.unknownPickIds.isEmpty ? 'yes' : 'NO (${a.unknownPickIds.length} unknown)')} | '
          '${a.toolCalls.length} | ${(a.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s | '
          '${a.inputTokens}/${a.outputTokens} (${a.cachedTokens}) | \$${a.cost.toStringAsFixed(4)} |',
        );
        out
          ..writeln('## ${i + 1}. $label — ${model.name}\n')
          ..writeln(
            '${(a.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} s · \$${a.cost.toStringAsFixed(4)} · '
            '${a.toolCalls.length} tool calls\n',
          );
        if (a.error != null) out.writeln('**Error:** ${a.error}\n');
        if (a.intro != null) out.writeln('> ${a.intro}\n');
        for (final pick in a.picks) {
          final t = pick.title;
          out.writeln(
            '- **${t.title}** (${t.year ?? '?'}, ${t.type}, ${t.libraryTitle}'
            '${t.audienceRating == null ? '' : ', ★${t.audienceRating!.toStringAsFixed(1)}'}) — ${pick.reason}',
          );
        }
        if (a.unknownPickIds.isNotEmpty) out.writeln('- ⚠️ Unknown ids: ${a.unknownPickIds.join(', ')}');
        if (a.text.isNotEmpty) out.writeln('\nText: ${a.text.replaceAll('\n', ' ')}');
        out.writeln('\nTool calls:');
        for (final c in a.toolCalls) {
          out.writeln('- `${c.name}` ${c.input} → ${c.resultChars} chars');
        }
        out.writeln();
      }
      agent.close();
    }
    final report = StringBuffer()
      ..writeln('# AI helper eval — $stamp\n')
      ..writeln('Totals: ${totals.entries.map((e) => '${e.key.name} \$${e.value.toStringAsFixed(3)}').join(' · ')}\n')
      ..write(summary)
      ..writeln()
      ..write(out.toString().replaceFirst('# AI helper eval — $stamp\n\n', ''));
    final file = File(p.join(p.dirname(promptsFile), 'ai-eval-$stamp.md'));
    await file.writeAsString(report.toString());
    appLogger.i('AI eval written to ${file.path}');
    return file.path;
  }
}
