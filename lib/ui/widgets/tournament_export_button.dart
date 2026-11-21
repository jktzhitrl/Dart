import 'package:file_selector/file_selector.dart' as files;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/models.dart';
import '../../data/tournament_export.dart';

enum _ExportFormat { pdf, csv }

class TournamentExportButton extends StatelessWidget {
  final TournamentRecord tournament;
  const TournamentExportButton({super.key, required this.tournament});

  @override
  Widget build(BuildContext context) => PopupMenuButton<_ExportFormat>(
    tooltip: 'Turnier exportieren',
    icon: const Icon(Icons.ios_share),
    onSelected: (format) => _share(context, format),
    itemBuilder: (_) => const [
      PopupMenuItem(
        value: _ExportFormat.pdf,
        child: Text('PDF teilen oder speichern'),
      ),
      PopupMenuItem(
        value: _ExportFormat.csv,
        child: Text('CSV teilen oder speichern'),
      ),
    ],
  );

  Future<void> _share(BuildContext context, _ExportFormat format) async {
    try {
      final export = TournamentExport(tournament);
      final isPdf = format == _ExportFormat.pdf;
      final data = isPdf
          ? await export.pdf(
              await rootBundle.load('assets/fonts/NotoSans-Regular.ttf'),
            )
          : export.csv();
      if (!context.mounted) return;
      final filename = '${export.filename}.${format.name}';
      final mimeType = isPdf ? 'application/pdf' : 'text/csv';
      final desktop =
          !kIsWeb &&
          {
            TargetPlatform.linux,
            TargetPlatform.macOS,
            TargetPlatform.windows,
          }.contains(defaultTargetPlatform);
      if (desktop) {
        final location = await files.getSaveLocation(suggestedName: filename);
        if (location != null) {
          await files.XFile.fromData(
            data,
            mimeType: mimeType,
          ).saveTo(location.path);
        }
        return;
      }
      final box = context.findRenderObject()! as RenderBox;
      await Share.shareXFiles(
        [XFile.fromData(data, mimeType: mimeType)],
        fileNameOverrides: [filename],
        sharePositionOrigin: box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Export fehlgeschlagen: $e')));
      }
    }
  }
}
