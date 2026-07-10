import '../models/note.dart';
import '../models/notebook.dart';
import '../models/tag.dart';

/// Pure mapping helpers between local models and the sync wire format.
/// The sync *flow* (cursor, transactions, outbox) lives in `SyncEngine`.
class SyncRepository {
  /// Parse server `changes` entries of type `note` into Note models.
  static List<Note> parseNoteChanges(List<Map<String, dynamic>> changes) =>
      _parse(changes, 'note', Note.fromJson);

  /// Parse server `changes` entries of type `notebook` into Notebook models.
  static List<Notebook> parseNotebookChanges(
    List<Map<String, dynamic>> changes,
  ) =>
      _parse(changes, 'notebook', Notebook.fromJson);

  /// Parse server `changes` entries of type `tag` into Tag models.
  static List<Tag> parseTagChanges(List<Map<String, dynamic>> changes) =>
      _parse(changes, 'tag', Tag.fromJson);

  static List<T> _parse<T>(
    List<Map<String, dynamic>> changes,
    String entityType,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    final out = <T>[];
    for (final change in changes) {
      if (change['entity_type'] == entityType && change['data'] != null) {
        try {
          out.add(fromJson(change['data'] as Map<String, dynamic>));
        } catch (_) {
          // Skip malformed entries rather than failing the whole sync.
        }
      }
    }
    return out;
  }
}
