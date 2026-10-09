import 'package:dsh_remote_core/api/workspace_registry.dart';
import 'package:test/test.dart';

/// D-046: the Workspace registry projection.
///
/// The registry is a **live stream**, so the interesting failures are not "did
/// it parse" but "what happens when frames arrive in an order the projection
/// does not expect". Every case here is one of those.
Map<String, dynamic> view(
  String id, {
  String? title,
  List<String> sessions = const [],
  String path = '/tmp',
}) =>
    {
      'workspaceId': id,
      'path': path,
      'title': title ?? id,
      'sessionIds': sessions,
      'createdAt': '2026-10-01T00:00:00Z',
      'updatedAt': '2026-10-02T00:00:00Z',
    };

Map<String, dynamic> baseline(List<Map<String, dynamic>> items) => {
      'type': 'baseline',
      'value': {
        'items': items,
        'archivedSessionIds': ['arch-1'],
        'pinnedSessionIds': ['pin-1'],
      },
    };

void main() {
  group('baseline', () {
    test('becomes the ordered projection', () {
      final p = WorkspaceRegistryProjection()
        ..apply(decodeWorkspaceFrame(baseline([
              view('w1', title: '定时任务', sessions: ['s1']),
              view('w2', title: '策略交易', sessions: ['s2']),
            ])));

      expect(p.items.map((w) => w.title), ['定时任务', '策略交易']);
      expect(p.items.first.path, '/tmp');
      expect(p.claimedSessionIds, {'s1', 's2'});
      expect(p.archivedSessionIds, ['arch-1']);
      expect(p.pinnedSessionIds, ['pin-1']);
    });

    test('a second baseline replaces rather than appends', () {
      final p = WorkspaceRegistryProjection()
        ..apply(decodeWorkspaceFrame(baseline([view('w1')])))
        ..apply(decodeWorkspaceFrame(baseline([view('w9')])));
      expect(p.items.map((w) => w.workspaceId), ['w9']);
    });
  });

  group('increments', () {
    late WorkspaceRegistryProjection p;

    setUp(() {
      p = WorkspaceRegistryProjection()
        ..apply(decodeWorkspaceFrame(baseline([view('w1', sessions: ['s1'])])));
    });

    test('upsert adds a new workspace at the end', () {
      p.apply(decodeWorkspaceFrame({
        'type': 'upsert',
        'workspace': view('w2', sessions: ['s2']),
      }));
      expect(p.items.map((w) => w.workspaceId), ['w1', 'w2']);
      expect(p.claimedSessionIds, {'s1', 's2'});
    });

    test('upsert on a known id replaces it in place, not appended', () {
      p.apply(decodeWorkspaceFrame({
        'type': 'upsert',
        'workspace': view('w1', title: '改名了', sessions: ['s1', 's9']),
      }));
      expect(p.items.map((w) => w.workspaceId), ['w1'],
          reason: 'a re-upsert must not duplicate the row');
      expect(p.items.single.title, '改名了');
      expect(p.claimedSessionIds, {'s1', 's9'});
    });

    test('remove drops the row and the order entry', () {
      p.apply(decodeWorkspaceFrame({'type': 'remove', 'workspaceId': 'w1'}));
      expect(p.items, isEmpty);
    });

    test('order is absolute — a full list replaces the previous one', () {
      p.apply(decodeWorkspaceFrame({
        'type': 'upsert',
        'workspace': view('w2'),
      }));
      p.apply(decodeWorkspaceFrame({
        'type': 'order',
        'workspaceIds': ['w2', 'w1'],
      }));
      expect(p.items.map((w) => w.workspaceId), ['w2', 'w1']);
    });

    test('order keeps ids we have not seen yet, so their later upsert lands '
        'in the user-chosen position', () {
      p.apply(decodeWorkspaceFrame({
        'type': 'order',
        'workspaceIds': ['w7', 'w1'],
      }));
      p.apply(decodeWorkspaceFrame({
        'type': 'upsert',
        'workspace': view('w7'),
      }));
      expect(p.items.map((w) => w.workspaceId), ['w7', 'w1']);
    });

    test('archived / pinned replace wholesale and report no-op honestly', () {
      p.apply(decodeWorkspaceFrame({
        'type': 'archived',
        'archivedSessionIds': ['arch-1', 'arch-2'],
      }));
      expect(p.archivedSessionIds, ['arch-1', 'arch-2']);
      expect(
        p.apply(decodeWorkspaceFrame({
          'type': 'archived',
          'archivedSessionIds': ['arch-1', 'arch-2'],
        })),
        isFalse,
        reason: 'an identical frame must not trigger a repaint',
      );
    });

    test('an unknown frame kind is kept, not fatal', () {
      expect(
        p.apply(decodeWorkspaceFrame({'type': 'brand-new-thing'})),
        isFalse,
      );
      expect(p.items, hasLength(1), reason: 'a new engine frame type must not '
          'empty the registry');
    });

    test('a malformed upsert degrades to unknown rather than throwing', () {
      expect(
        decodeWorkspaceFrame({'type': 'upsert'}),
        isA<WorkspaceUnknownFrame>(),
      );
    });
  });

  group('ungrouped sessions (dsh 的 UNGROUPED_KEY)', () {
    test('a session in no workspace is derivable as the complement', () {
      // dsh uses the empty string as the group key
      // (`ui-workspace/src/client/tree.ts:18`); the wire never sends it, so
      // the client computes it by subtracting the claimed ids.
      final p = WorkspaceRegistryProjection()
        ..apply(decodeWorkspaceFrame(baseline([
              view('w1', sessions: ['s1', 's2']),
              view('w2', sessions: ['s2', 's3']),
            ])));
      const all = ['s1', 's2', 's3', 's4'];
      expect(
        all.where((id) => !p.claimedSessionIds.contains(id)).toList(),
        ['s4'],
        reason: 's4 belongs to no workspace and must land in the ungrouped row',
      );
    });

    test('archived sessions are excluded from the ungrouped row', () {
      final p = WorkspaceRegistryProjection()
        ..apply(decodeWorkspaceFrame(baseline([view('w1', sessions: ['s1'])])));
      const all = ['s1', 'arch-1'];
      expect(
        all
            .where((id) =>
                !p.claimedSessionIds.contains(id) &&
                !p.archivedSessionIds.contains(id))
            .toList(),
        isEmpty,
      );
    });
  });

  group('stream protocol', () {
    test('an increment before the baseline is a fault, not a silent drop', () {
      // Applying it anyway would attach an increment to an empty projection
      // and leave the registry quietly wrong.
      final frames = <WorkspaceFollowFrame>[];
      final errors = <Object>[];
      final stream = WorkspaceFollowStream.fromSource(
        Stream<Object?>.fromIterable([
          {
            'type': 'upsert',
            'workspace': view('w1'),
          },
        ]),
        onError: errors.add,
      );
      stream.frames.listen(frames.add);
      return Future<void>.delayed(Duration.zero, () async {
        expect(frames.whereType<WorkspaceUpsertFrame>(), isEmpty);
        await stream.dispose();
      });
    });

    test('a well-formed stream delivers baseline then increments', () async {
      final frames = <WorkspaceFollowFrame>[];
      final stream = WorkspaceFollowStream.fromSource(
        Stream<Object?>.fromIterable([
          baseline([view('w1', title: '定时任务')]),
          {
            'type': 'upsert',
            'workspace': view('w2', title: '策略交易'),
          },
        ]),
      );
      stream.frames.listen(frames.add);
      await Future<void>.delayed(Duration.zero);
      final p = WorkspaceRegistryProjection();
      for (final f in frames) {
        p.apply(f);
      }
      expect(p.items.map((w) => w.title), ['定时任务', '策略交易']);
      await stream.dispose();
    });
  });
}
