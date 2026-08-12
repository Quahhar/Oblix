import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/native/oblix_core.dart';
import '../../data/repositories/attachment_repository.dart';
import '../../data/repositories/note_repository.dart';
import '../../data/repositories/text_layer_repository.dart';
import '../../domain/services/scanner/document_scanner.dart';
import '../theme/oblix_theme.dart';
import '../widgets/paper.dart';
import 'note_editor_screen.dart';

/// Photograph a page, read it, and keep the result as a note.
///
/// The screen owns capture and presentation only. Everything between "here are
/// some recognized boxes" and "here is a note" — reading order, paragraph
/// reflow, hyphen healing, title extraction — happens in the Rust core via
/// [shapeScannedText], so the same page produces the same note on every
/// platform and the behaviour is testable without a camera.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.notebookId});

  /// Set when the scan was started from inside a notebook.
  final String? notebookId;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _notes = NoteRepository();
  final _attachments = AttachmentRepository();
  final _textLayers = TextLayerRepository();
  final _title = TextEditingController();
  final _body = TextEditingController();

  ScanCapture? _capture;
  ScannedNoteDraftValue? _draft;
  bool _busy = false;
  bool _preserveLineBreaks = false;
  bool _detectColumns = true;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    // The recognizer holds a loaded model; let it go with the screen.
    disposeRecognizer();
    super.dispose();
  }

  Future<void> _scan(ScanSource source) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final capture = await captureAndRecognize(source);
      if (capture == null || !mounted) return;
      _capture = capture;
      _reshape();
    } on ScanUnsupportedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on ScanFailedException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Scanning failed. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Re-run the core over the captured lines. Cheap and synchronous, so the
  /// layout toggles can just rebuild the draft rather than re-scanning.
  ///
  /// The whole capture goes in at once. Each page is still straightened and
  /// column-split on its own — geometry from one page says nothing about the
  /// next — but only the core seeing every page together can drop the running
  /// head a book repeats and rejoin a paragraph cut in half by a page break.
  void _reshape() {
    final capture = _capture;
    if (capture == null) return;
    final draft = shapeScannedPages(
      pages: capture.corePages,
      preserveLineBreaks: _preserveLineBreaks,
      detectColumns: _detectColumns,
    );
    setState(() {
      _draft = draft;
      _title.text = draft.title.isEmpty ? 'Scanned note' : draft.title;
      _body.text = draft.body;
    });
  }

  /// What the core made of the page, so a wrong reading is explainable rather
  /// than mysterious — and the toggle to fix it sits right below.
  String _readingSummary(ScannedNoteDraftValue draft) {
    final script = _capture?.script;
    final parts = <String>[
      '${draft.keptLines} ${draft.keptLines == 1 ? 'line' : 'lines'} read',
      // Only worth saying when it is not the assumed case; naming Latin on
      // every English page would be noise.
      if (script != null &&
          script != ScriptValue.latin &&
          script != ScriptValue.unknown)
        _scriptLabel(script),
      if (draft.pages > 1) '${draft.pages} pages',
      if (draft.columns > 1) '${draft.columns} columns',
      if (draft.tables > 0)
        '${draft.tables} ${draft.tables == 1 ? 'table' : 'tables'}',
      if (draft.headings > 0) '${draft.headings} headings',
      if (draft.correctedSkewDegrees.abs() >= 1)
        'straightened ${draft.correctedSkewDegrees.abs().toStringAsFixed(0)}°',
      if (draft.strippedRunningHeads > 0)
        '${draft.strippedRunningHeads} running heads removed',
      if (draft.droppedLines > 0) '${draft.droppedLines} skipped',
    ];
    return parts.join(' · ');
  }

  Future<void> _save() async {
    final body = _body.text;
    if (noteDraftIsEmpty(title: _title.text, content: body)) {
      setState(() => _error = 'There is nothing to save yet.');
      return;
    }
    setState(() => _busy = true);
    try {
      final note = await _notes.createNote(
        title: normalizeNoteTitle(_title.text),
        content: body,
        // A page that turned out to have headings, lists or tables is saved as
        // Markdown; plain prose stays plain. The core decides which, because
        // it is the thing that knows what it found.
        contentType: _draft?.contentType ?? 'plain',
        notebookId: widget.notebookId,
      );
      await _keepTheSourcePages(note.id);
      if (!mounted) return;
      // Replace the scan screen with the note, so Back goes home rather than
      // returning to a spent capture.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => NoteEditorScreen(noteId: note.id)),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not save the note.';
        });
      }
    }
  }

  static String _scriptLabel(ScriptValue script) => switch (script) {
    ScriptValue.chinese => 'read as Chinese',
    ScriptValue.japanese => 'read as Japanese',
    ScriptValue.korean => 'read as Korean',
    ScriptValue.devanagari => 'read as Devanagari',
    _ => 'read as ${script.name}',
  };

  /// Attach the photographs and keep what the recognizer saw.
  ///
  /// The text layer is what makes the scan findable later by a word printed on
  /// the paper, highlightable on the image, and re-readable with different
  /// options without photographing anything again. It is derived data, so a
  /// failure here costs those extras and must not cost the note the user has
  /// already been told was saved.
  Future<void> _keepTheSourcePages(String noteId) async {
    final capture = _capture;
    if (capture == null) return;
    try {
      final attachments = <String?>[];
      for (var index = 0; index < capture.pageImagePaths.length; index++) {
        final file = File(capture.pageImagePaths[index]);
        if (!await file.exists()) {
          attachments.add(null);
          continue;
        }
        final attachment = await _attachments.attach(
          noteId: noteId,
          bytes: await file.readAsBytes(),
          originalName: capture.pageCount > 1
              ? 'scan-page-${index + 1}.jpg'
              : 'scan.jpg',
          mimeType: 'image/jpeg',
        );
        attachments.add(attachment.id);
      }
      // One layer per page, each tied to the image it was read from, so a
      // highlight knows which photograph to draw itself on.
      final pages = capture.corePages;
      for (var index = 0; index < pages.length; index++) {
        await _textLayers.save(
          noteId: noteId,
          attachmentId: index < attachments.length ? attachments[index] : null,
          layer: buildTextLayer(
            pages: [pages[index]],
            source: capture.guided ? 'document' : 'camera',
          ),
        );
      }
    } catch (_) {
      // The note is already saved; the extras simply did not survive.
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = OblixColors.of(context);
    final draft = _draft;
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            ListView(
              padding: const EdgeInsets.only(bottom: 36),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: Row(
                    children: [
                      CircleIconButton(
                        Icons.arrow_back_ios_new,
                        size: 32,
                        onTap: () => Navigator.pop(context),
                      ),
                      const Spacer(),
                      if (draft != null)
                        AccentPill(
                          label: 'Save note',
                          icon: Icons.check,
                          filled: true,
                          onTap: _busy ? null : _save,
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('SCAN', style: OblixType.eyebrow(c)),
                      const SizedBox(height: 8),
                      Text('Read a page', style: OblixType.pageTitle(c)),
                      const SizedBox(height: 6),
                      Text(
                        draft == null
                            ? 'Photograph a document and Oblix turns the text '
                                  'into a note you can edit.'
                            : _readingSummary(draft),
                        style: OblixType.ui(c, size: 12.5, color: c.inkMuted),
                      ),
                    ],
                  ),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 16, 22, 0),
                    child: Text(
                      _error!,
                      style: OblixType.ui(c, size: 13.5, color: c.danger),
                    ),
                  ),
                if (guidedScanSupported)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                    child: GlassPill(
                      onTap: _busy ? null : () => _scan(ScanSource.document),
                      color: c.accent,
                      borderColor: Colors.transparent,
                      glassAlpha: 0.66,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.document_scanner_outlined,
                            size: 18,
                            color: c.onAccent,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            draft == null ? 'Scan a document' : 'Scan again',
                            style: OblixType.ui(
                              c,
                              size: 15,
                              weight: FontWeight.w600,
                              color: c.onAccent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    22,
                    guidedScanSupported ? 10 : 18,
                    22,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GlassPill(
                          onTap: _busy ? null : () => _scan(ScanSource.camera),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          child: _pillLabel(
                            c,
                            Icons.photo_camera_outlined,
                            'Photo',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: GlassPill(
                          onTap: _busy ? null : () => _scan(ScanSource.gallery),
                          padding: const EdgeInsets.symmetric(vertical: 13),
                          child: _pillLabel(
                            c,
                            Icons.image_outlined,
                            'From photos',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (guidedScanSupported && draft == null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(26, 10, 26, 0),
                    child: Text(
                      'Scanning finds the page edges and straightens it, and '
                      'takes up to $maxScanPages pages at once — it reads far '
                      'better than a photo taken at an angle.',
                      style: OblixType.ui(c, size: 12, color: c.inkMuted),
                    ),
                  ),
                if (draft != null) ...[
                  const SectionEyebrow(
                    'Layout',
                    padding: EdgeInsets.fromLTRB(26, 20, 26, 0),
                  ),
                  PaperCard(
                    margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                    child: Column(
                      children: [
                        SettingsRow(
                          icon: Icons.format_align_left,
                          label: 'Keep original line breaks',
                          value: _preserveLineBreaks ? 'On' : 'Off',
                          showChevron: false,
                          onTap: () {
                            _preserveLineBreaks = !_preserveLineBreaks;
                            _reshape();
                          },
                          trailing: _switch(c, _preserveLineBreaks),
                        ),
                        Divider(height: 1, color: c.hairline),
                        SettingsRow(
                          icon: Icons.view_column_outlined,
                          label: 'Read columns separately',
                          value: draft.columns > 1
                              ? '${draft.columns} found'
                              : (_detectColumns ? 'On' : 'Off'),
                          showChevron: false,
                          onTap: () {
                            _detectColumns = !_detectColumns;
                            _reshape();
                          },
                          trailing: _switch(c, _detectColumns),
                        ),
                      ],
                    ),
                  ),
                  const SectionEyebrow(
                    'Note',
                    padding: EdgeInsets.fromLTRB(26, 18, 26, 0),
                  ),
                  PaperCard(
                    margin: const EdgeInsets.fromLTRB(22, 10, 22, 0),
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
                    child: Column(
                      children: [
                        TextField(
                          controller: _title,
                          style: OblixType.cardTitle(c),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Title',
                            hintStyle: OblixType.ui(
                              c,
                              size: 15,
                              color: c.inkMuted,
                            ),
                          ),
                        ),
                        Divider(height: 1, color: c.hairline),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _body,
                          maxLines: null,
                          minLines: 8,
                          style: OblixType.ui(c, size: 14.5),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: 'Recognized text appears here',
                            hintStyle: OblixType.ui(
                              c,
                              size: 14.5,
                              color: c.inkMuted,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_capture case final capture?)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 18, 22, 0),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.file(
                          File(capture.imagePath),
                          height: 200,
                          width: double.infinity,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                ],
              ],
            ),
            if (_busy)
              Positioned.fill(
                child: ColoredBox(
                  color: c.scrim.withValues(alpha: 0.2),
                  child: const Center(child: CircularProgressIndicator()),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The row itself owns the tap, so the switch is decoration.
  Widget _switch(OblixColors c, bool value) => IgnorePointer(
    child: Switch.adaptive(
      value: value,
      activeTrackColor: c.accent,
      activeThumbColor: c.onAccent,
      onChanged: (_) {},
    ),
  );

  Widget _pillLabel(OblixColors c, IconData icon, String label) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(icon, size: 17, color: c.avatarInk),
      const SizedBox(width: 8),
      Text(label, style: OblixType.ui(c, size: 14, weight: FontWeight.w600)),
    ],
  );
}
