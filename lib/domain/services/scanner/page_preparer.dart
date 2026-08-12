import 'dart:typed_data';

import '../../../core/native/oblix_core.dart';

export 'page_preparer_stub.dart'
    if (dart.library.io) 'page_preparer_flutter.dart';

/// A prepared page written out for a second recognition pass.
class PreparedPage {
  const PreparedPage({required this.path, required this.plan});

  /// The rewritten image on disk, in the system temporary directory.
  final String path;

  /// The plan it was built from. Kept because mapping the retry's boxes back
  /// into source coordinates needs the same transform that produced them.
  final PagePrepareValue plan;
}

/// A page's luma histogram, or an empty sample when it could not be read.
///
/// An empty histogram is the honest answer rather than a flat one: the core
/// treats it as "no sample" and declines to plan a contrast stretch, where a
/// fabricated distribution would have it stretch against invented levels.
typedef LumaSampler = Future<PageLumaSampleValue> Function(String path);

PageLumaSampleValue get emptyLumaSample => (histogram: Uint32List(0));
