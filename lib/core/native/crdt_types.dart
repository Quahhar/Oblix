import 'dart:typed_data';

typedef CrdtClockValue = ({int timestampMicrosUtc, String deviceId});

typedef SyncBatchEntryValue = ({int seq, String entityType, String entityId});

typedef SyncSettlementValue = ({
  List<int> ackedSeqs,
  List<int> retrySeqs,
  int pulledCount,
  bool anythingChanged,
  bool continueDraining,
});

typedef NotebookNodeValue = ({String id, String name, String? parentId});

typedef NotebookPathValue = ({String id, List<String> path, String pathKey});

typedef MarkdownImportValue = ({
  String title,
  String content,
  String contentType,
});

typedef ExportNoteValue = ({
  String id,
  String title,
  String content,
  List<String> tagNames,
});

typedef ExportTextFileValue = ({String filename, String content});

typedef PendingOutboxRowValue = ({int seq, String action, String dataJson});

/// A note reduced to the localized civil date the list view groups it by.
/// Dart owns the timezone conversion; the core owns the grouping.
typedef NoteDayValue = ({
  String id,
  int localYear,
  int localMonth,
  int localDay,
});

/// One rendered day heading and the note ids beneath it, in order.
typedef NoteDayGroupValue = ({String label, List<String> noteIds});

/// One word inside a recognized line, where the recognizer reports that
/// detail. Sources that do not are represented by an empty list, never by
/// invented boxes.
typedef OcrWordValue = ({
  String text,
  double left,
  double top,
  double right,
  double bottom,
  double? confidence,
});

/// One line the OCR engine recognized, with its box in image pixels.
typedef OcrLineValue = ({
  String text,
  double left,
  double top,
  double right,
  double bottom,
  int blockIndex,
  double? confidence,
  List<OcrWordValue> words,
});

typedef PendingOutboxSummaryValue = ({
  Set<String> fields,
  Map<String, Set<int>> updateSeqsByField,
});

typedef OutboxRetirementValue = ({
  bool changed,
  bool deleteRow,
  String dataJson,
});

enum CoreMutationAction { noop, create, update, delete }

typedef MutationSelectionValue = ({
  CoreMutationAction action,
  List<String> changedFields,
  List<String> patchFields,
});

typedef NoteMutationStateValue = ({
  String title,
  String content,
  String contentType,
  String? notebookId,
  bool isPinned,
  bool isArchived,
  bool isDeleted,
  List<String> tagNames,
});

typedef NoteMutationPlanValue = ({
  NoteMutationStateValue value,
  MutationSelectionValue selection,
});

typedef NotebookMutationStateValue = ({
  String name,
  String? parentId,
  int sortOrder,
  bool isDeleted,
});

typedef NotebookMutationPlanValue = ({
  NotebookMutationStateValue value,
  MutationSelectionValue selection,
});

typedef TaskMutationStateValue = ({
  String title,
  String description,
  String? noteId,
  String? notebookId,
  String? parentId,
  int? dueDateMicrosUtc,
  bool dueHasTime,
  int priority,
  List<String> labels,
  String? recurrence,
  int? reminderAtMicrosUtc,
  int? reminderLeadMinutes,
  int sortOrder,
  bool isCompleted,
  int? completedAtMicrosUtc,
  bool isDeleted,
});

/// A nullable integer update, with the same provided/value pair the string and
/// timestamp mutations use.
typedef NullableIntValue = ({bool provided, int? value});

typedef TaskMutationPlanValue = ({
  TaskMutationStateValue value,
  MutationSelectionValue selection,
});

typedef CoreImportedAttachmentValue = ({
  String originalName,
  String? mimeType,
  List<int> bytes,
});

typedef CoreImportedNoteValue = ({
  String title,
  String content,
  String contentType,
  List<String> tagNames,
  bool isPinned,
  bool isArchived,
  int createdAtMicrosUtc,
  int updatedAtMicrosUtc,
  String? notebookName,
  List<String>? notebookPath,
  List<CoreImportedAttachmentValue> attachments,
  int skippedAttachments,
});

typedef CoreImportBundleValue = ({
  List<CoreImportedNoteValue> notes,
  List<String> notebookNames,
  List<List<String>> notebookPaths,
});

typedef CoreEpubNoteValue = ({String title, String content});

typedef CoreOblixNoteValue = ({
  String id,
  String? notebookId,
  String title,
  String content,
  String contentType,
  List<String> tagNames,
  bool isPinned,
  bool isArchived,
  String createdAtIsoUtc,
  String updatedAtIsoUtc,
});

typedef CoreOblixNotebookValue = ({
  String id,
  String name,
  String? parentId,
  int sortOrder,
});

typedef CoreOblixAttachmentValue = ({
  String id,
  String originalName,
  String mimeType,
  List<int> bytes,
});

typedef CoreOblixAttachmentGroupValue = ({
  String noteId,
  List<CoreOblixAttachmentValue> attachments,
});

// --- Scanning, text layers and entities -----------------------------------
//
// These mirror the shapes in `rust/src/api/{ocr,textlayer,entities,pdf}.rs`.
// The app talks in these records so it never imports generated bridge code,
// and so the fallback can declare the same signatures the native path does.

/// How a scanned page should be read. [ScanPresetValue.auto] lets the core
/// classify it from the page's own geometry.
enum ScanPresetValue {
  auto,
  prose,
  bookPage,
  receipt,
  form,
  whiteboard,
  code,
  table,
}

/// How much the recognizer struggled, which stands in for how good the
/// photograph was. [unknown] means the recognizer reported no confidences at
/// all, which is not the same as "good".
enum QualityVerdictValue { unknown, good, fair, poor }

/// One page's worth of recognized lines, with the source pixel size.
typedef OcrPageValue = ({
  List<OcrLineValue> lines,
  double width,
  double height,
});

typedef CaptureQualityValue = ({
  QualityVerdictValue verdict,
  double meanConfidence,
  double lowConfidenceShare,
  int scoredLines,
  String advice,
});

/// A note reconstructed from a scan, plus what the core made of the pages.
typedef ScannedNoteDraftValue = ({
  String title,
  String body,

  /// `plain` or `markdown`, matching the note content types.
  String contentType,
  int keptLines,
  int droppedLines,
  int columns,
  double correctedSkewDegrees,
  int pages,
  int tables,
  int headings,
  int strippedRunningHeads,

  /// Tokens whose misread characters were put back from the capture's own
  /// vocabulary or a common word.
  int repairedWords,

  /// The preset actually used, never `auto`.
  String preset,
  CaptureQualityValue quality,
});

/// One word box inside a stored line, so a highlight can sit on the words
/// rather than on an interpolation along the line.
typedef TextLayerWordValue = ({
  String text,
  double left,
  double top,
  double right,
  double bottom,
});

/// One recognized line as the recognizer reported it, kept so a scan can be
/// searched, highlighted and re-read without the original image.
typedef TextLayerLineValue = ({
  String text,
  double left,
  double top,
  double right,
  double bottom,
  double? confidence,
  List<TextLayerWordValue> words,
});

typedef TextLayerPageValue = ({
  double width,
  double height,
  List<TextLayerLineValue> lines,
});

typedef TextLayerValue = ({String source, List<TextLayerPageValue> pages});

/// Where a query matched, narrowed to the matched words within the line.
typedef TextLayerHitValue = ({
  int page,
  int line,
  String text,
  double left,
  double top,
  double right,
  double bottom,
});

/// Kinds of thing the core can pick out of scanned text.
enum EntityKindValue {
  date,
  time,
  money,
  percent,
  phone,
  email,
  url,
  card,
  iban,
  postCode,
}

typedef EntityValue = ({
  EntityKindValue kind,
  String text,

  /// UTF-16 offsets, so they index the same string Dart holds.
  int start,
  int end,
  String normalized,
  String currency,
});

typedef RedactionSpanValue = ({
  EntityKindValue kind,
  int page,
  double left,
  double top,
  double right,
  double bottom,
  String label,
});

enum ActionKindValue { task, event, contact }

/// A proposed action in civil components — Dart resolves them against the
/// device timezone, because the core never guesses one.
typedef SuggestedActionValue = ({
  ActionKindValue kind,
  String title,
  String detail,
  int? year,
  int? month,
  int? day,
  int? hour,
  int? minute,

  /// Money in minor units, so nothing is lost to rounding.
  int? amountMinor,
  String currency,
});

/// One positioned piece of text from a PDF content stream. [y] is the *bottom*
/// edge in PDF user space, where y grows upward.
typedef PdfTextRunValue = ({
  String text,
  double x,
  double y,
  double width,
  double height,
});

typedef PdfPageValue = ({
  List<PdfTextRunValue> runs,
  double width,
  double height,
  bool hasImage,
});

/// Whether a PDF page can be read as it stands or has to be recognized.
enum PdfPagePlanValue { useText, needsOcr }

typedef PdfPageAssessmentValue = ({
  PdfPagePlanValue plan,
  String reason,
  double coverage,
  int characters,
  int runs,
});

/// A writing system, as far as picking a recognizer is concerned.
///
/// [cyrillic] through [thai] are detectable but have no on-device model, so
/// the app can say *why* a page cannot be read instead of returning the Latin
/// model's guesses as though they were words.
enum ScriptValue {
  unknown,
  latin,
  chinese,
  japanese,
  korean,
  devanagari,
  cyrillic,
  greek,
  arabic,
  hebrew,
  thai,
}

typedef ScriptReportValue = ({
  ScriptValue script,
  double confidence,
  int letters,

  /// Whether an on-device recognizer exists for this script.
  bool recognizable,
});

/// One recognizer's attempt at a page, ready to be scored against the others.
typedef ScriptReadingValue = ({ScriptValue script, OcrPageValue page});

typedef ReadingScoreValue = ({
  ScriptValue script,
  double score,
  int characters,
  double meanConfidence,
  double coverage,
  double junkShare,

  /// The script the text turned out to be in, which is not always the one the
  /// model was looking for.
  ScriptValue dominantScript,
});

/// Which reading won. [chosen] indexes the readings offered, or is -1 when
/// none of them found any text.
typedef ScriptChoiceValue = ({
  int chosen,
  ScriptValue script,
  List<ReadingScoreValue> scores,
  String reason,
});

/// What a first reading revealed about a page's geometry, in source pixels.
typedef PageMeasureValue = ({
  /// Tilt in degrees, negative leaning left.
  double skewDegrees,
  double medianLineHeight,
  int usableLines,

  /// Share of the lines whose box is wider than tall — near 1 on a page the
  /// right way up, near 0 on one photographed on its side.
  double uprightShare,
});

/// A page's brightness distribution: 256 buckets of pixel counts, index 0
/// black. Sampled from a downscaled decode — the shape of a page's tonal range
/// survives shrinking.
///
/// [tiles] holds the mean luma of each cell of a grid over the same thumbnail,
/// row-major from the top left. The histogram says how much of the tonal range
/// a page used; only the tiles say *where*, which is what separates a page that
/// is uniformly dim from one lit from a single side.
typedef PageLumaSampleValue = ({
  Uint32List histogram,
  Uint32List tiles,
  int tileColumns,
  int tileRows,
});

/// Everything the platform needs to build a better bitmap for a second reading,
/// and nothing it has to decide. When [worthwhile] is false every other field is
/// meaningless and the first reading stands.
typedef PagePrepareValue = ({
  bool worthwhile,
  int outWidth,
  int outHeight,

  /// Source-to-prepared affine as `[a, b, c, d, tx, ty]`, the order a 2D
  /// graphics matrix loads in.
  Float32List transform,

  /// 4x5 row-major colour matrix over unpremultiplied RGBA in 0..255, the
  /// layout `ColorFilter.matrix` takes. Converts to grey only when
  /// [localContrast] is set; the tones are then the pixel pass's business.
  Float32List colorMatrix,

  /// Whether the drawn bitmap should be passed through `normalizePageContrast`
  /// before the recognizer sees it.
  bool localContrast,
  double rotateDegrees,

  /// Whole 90° turns being taken out, 0..3. Zero unless the page's orientation
  /// was in doubt.
  int quarterTurns,
  double scale,
  String reason,
});

typedef PageReadingScoreValue = ({
  double score,
  int characters,
  double meanConfidence,
  double junkShare,

  /// Share of tokens that look like words rather than debris.
  double wordShare,
});

/// Which reading of the same page won. [chosen] indexes the readings offered,
/// or is -1 when none of them found any text.
typedef PageReadingChoiceValue = ({
  int chosen,
  List<PageReadingScoreValue> scores,
  String reason,
});
