import 'package:flutter_test/flutter_test.dart';

import 'package:notilus/models/file_entry.dart';
import 'package:notilus/models/media_kind.dart';
import 'package:notilus/providers/media_provider.dart';

/// The view layer of the media pages: filtering, ordering and the year/month
/// buckets. The scan itself is the Rust searcher and isn't exercised here —
/// what these guard is the pure derivation that sits on top of its results.
void main() {
  FileEntry entry(String name, {required DateTime modified, int size = 100}) =>
      FileEntry(
        path: '/library/$name',
        name: name,
        isDirectory: false,
        size: size,
        modified: modified,
      );

  late MediaProvider media;

  final photos = [
    entry('beach.jpg', modified: DateTime(2026, 8, 3), size: 300),
    entry('Alps.png', modified: DateTime(2026, 3, 14), size: 100),
    entry('cat.jpeg', modified: DateTime(2025, 8, 20), size: 200),
    entry('dog.png', modified: DateTime(2025, 12, 1), size: 50),
  ];

  setUp(() {
    media = MediaProvider();
    media.seedEntries(MediaKind.images, photos);
  });

  tearDown(() => media.dispose());

  group('sorting', () {
    test('defaults to newest first', () {
      final st = media.state(MediaKind.images);
      expect(st.sortField, MediaSortField.date);
      expect(st.ascending, isFalse);
      expect(
        st.visible.map((e) => e.name),
        ['beach.jpg', 'Alps.png', 'dog.png', 'cat.jpeg'],
      );
    });

    test('name sorting is case-insensitive and starts ascending', () {
      media.setSortField(MediaKind.images, MediaSortField.name);
      final st = media.state(MediaKind.images);
      expect(st.ascending, isTrue);
      expect(
        st.visible.map((e) => e.name),
        ['Alps.png', 'beach.jpg', 'cat.jpeg', 'dog.png'],
      );
    });

    test('re-picking the active field flips direction', () {
      media.setSortField(MediaKind.images, MediaSortField.size);
      expect(
        media.state(MediaKind.images).visible.map((e) => e.size),
        [300, 200, 100, 50],
      );

      media.setSortField(MediaKind.images, MediaSortField.size);
      expect(
        media.state(MediaKind.images).visible.map((e) => e.size),
        [50, 100, 200, 300],
      );
    });
  });

  group('search filter', () {
    test('matches names case-insensitively without touching the scan', () {
      media.setQuery(MediaKind.images, 'PNG');
      final st = media.state(MediaKind.images);

      expect(st.isFiltered, isTrue);
      expect(st.visibleCount, 2);
      // The underlying library is untouched — the count line can report both.
      expect(st.totalCount, 4);
      expect(st.visible.map((e) => e.name), ['Alps.png', 'dog.png']);
    });

    test('clearing restores the full listing', () {
      media.setQuery(MediaKind.images, 'zzz');
      expect(media.state(MediaKind.images).visibleCount, 0);

      media.setQuery(MediaKind.images, '');
      expect(media.state(MediaKind.images).visibleCount, 4);
    });
  });

  group('grouping', () {
    test('all is a single unlabelled bucket', () {
      final groups = media.state(MediaKind.images).groups;
      expect(groups, hasLength(1));
      expect(groups.single.label, isNull);
      expect(groups.single.entries, hasLength(4));
    });

    test('years bucket by modified date, newest group first', () {
      media.setGroupMode(MediaKind.images, MediaGroupMode.year);
      final groups = media.state(MediaKind.images).groups;

      expect(groups.map((g) => g.label), ['2026', '2025']);
      expect(groups.first.entries.map((e) => e.name),
          ['beach.jpg', 'Alps.png']);
      expect(groups.last.entries.map((e) => e.name), ['dog.png', 'cat.jpeg']);
    });

    test('months carry the year so December and January can\'t collide', () {
      media.setGroupMode(MediaKind.images, MediaGroupMode.month);
      final groups = media.state(MediaKind.images).groups;

      expect(
        groups.map((g) => g.label),
        ['August 2026', 'March 2026', 'December 2025', 'August 2025'],
      );
      expect(groups.every((g) => g.entries.length == 1), isTrue);
    });

    test('group order follows the sort direction', () {
      media.setGroupMode(MediaKind.images, MediaGroupMode.year);
      media.toggleSortDirection(MediaKind.images);

      expect(
        media.state(MediaKind.images).groups.map((g) => g.label),
        ['2025', '2026'],
      );
    });

    test('grouping only buckets what survives the search filter', () {
      media.setGroupMode(MediaKind.images, MediaGroupMode.year);
      media.setQuery(MediaKind.images, 'png');

      final groups = media.state(MediaKind.images).groups;
      expect(groups.map((g) => g.label), ['2026', '2025']);
      expect(groups.expand((g) => g.entries).map((e) => e.name),
          ['Alps.png', 'dog.png']);
    });
  });

  group('selection', () {
    test('select-all covers the filtered listing, not the whole library', () {
      media.setSelecting(MediaKind.images, true);
      media.setQuery(MediaKind.images, 'png');
      media.selectAllVisible(MediaKind.images);

      expect(media.state(MediaKind.images).selected, hasLength(2));
    });

    test('leaving selection mode drops the selection', () {
      media.setSelecting(MediaKind.images, true);
      media.selectAllVisible(MediaKind.images);
      media.setSelecting(MediaKind.images, false);

      expect(media.state(MediaKind.images).selected, isEmpty);
    });

    test('removePaths drops entries and their selection after a trash', () {
      media.setSelecting(MediaKind.images, true);
      media.toggleSelect(MediaKind.images, '/library/cat.jpeg');
      media.removePaths(MediaKind.images, ['/library/cat.jpeg']);

      final st = media.state(MediaKind.images);
      expect(st.totalCount, 3);
      expect(st.selected, isEmpty);
      expect(st.visible.any((e) => e.name == 'cat.jpeg'), isFalse);
    });
  });

  group('per-kind isolation', () {
    test('each kind keeps its own listing and view state', () {
      media.seedEntries(MediaKind.documents, [
        entry('notes.pdf', modified: DateTime(2026, 1, 1)),
      ]);
      media.setQuery(MediaKind.documents, 'nothing');

      expect(media.state(MediaKind.images).visibleCount, 4);
      expect(media.state(MediaKind.documents).visibleCount, 0);
    });

    test('documents default to the list view, images to the grid', () {
      expect(media.state(MediaKind.images).viewMode, MediaViewMode.grid);
      expect(media.state(MediaKind.documents).viewMode, MediaViewMode.list);
    });
  });
}
