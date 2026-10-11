import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/console/inline_error_card.dart';
import 'package:dsh_remote_app/console/workspace/workspace_pane.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_engine_gateway.dart';

/// D-036 — the workspace file browser (mockup 屏 M).
///
/// The pane walks the **session's** workspace through the `workspaceFiles`
/// namespace, which has two path vocabularies on purpose
/// (`api/workspace-files/src/types.ts:1-15`): `list` speaks workspace paths
/// and `read`/`stat` speak absolute ones. These tests pin the two rules that
/// are easy to get wrong and impossible to see in a screenshot:
///
/// - a child is navigated by its **workspace path** (`a/b`), never by a path
///   the App assembled;
/// - a file is read only after `stat` confirmed the **absolute path**, because
///   a listing's `file` type is not a promise the content reads.
Widget _host(Widget child) => MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Scaffold(body: child),
    );

const _file = WorkspaceDirectoryEntry(
    name: 'README.md', type: WorkspaceEntryType.file, size: 12);
const _dir = WorkspaceDirectoryEntry(
    name: 'src', type: WorkspaceEntryType.directory);
const _other = WorkspaceDirectoryEntry(
    name: 'weird.sock', type: WorkspaceEntryType.other);
const _index = WorkspaceDirectoryEntry(
    name: 'index.ts', type: WorkspaceEntryType.file, size: 21);

/// D-042 夹具：散落在根层的文件（根层散落的 23 个 report_*.md 的形态）。
const _loose = WorkspaceDirectoryEntry(
  name: 'gamma-judge_2026-09-22_1218_failed.md',
  type: WorkspaceEntryType.file,
  size: 4096,
);

/// 根层一个真实目录，用来证明它留在分组之外。
const _newsDir =
    WorkspaceDirectoryEntry(name: 'reports', type: WorkspaceEntryType.directory);

/// 子目录里同样散落的文件 —— 用来证明"只在根层折叠"。
const _note =
    WorkspaceDirectoryEntry(name: 'note.md', type: WorkspaceEntryType.file, size: 5);

void main() {
  late FakeEngineGateway gateway;

  setUp(() {
    gateway = FakeEngineGateway();
    addTearDown(gateway.dispose);
  });

  /// A two-level tree: root → src → index.ts
  void seedTree() {
    gateway.workspaceListings[''] = const WorkspaceDirectoryListing(
      path: '',
      entries: [_file, _dir, _other],
      truncated: false,
    );
    gateway.workspaceListings['src'] = WorkspaceDirectoryListing(
      path: 'src',
      entries: const [_index],
      truncated: false,
    );
    gateway.workspaceFiles['/ws/src/index.ts'] = const WorkspaceFileText(
      absolutePath: '/ws/src/index.ts',
      version: 'v1',
      bytes: 21,
      offset: 1,
      text: "export const a = 1;",
      lines: 1,
      eof: true,
    );
  }

  Future<void> open(WidgetTester tester) async {
    late L10n l10n;
    await tester.pumpWidget(_host(Builder(builder: (context) {
      l10n = L10n.of(context);
      return WorkspacePane(
        gateway: gateway,
        sessionId: 'session-1',
        l10n: l10n,
      );
    })));
    await tester.pumpAndSettle();
  }

  group('D-036 workspace browser', () {
    testWidgets('lists the root with directories before files', (tester) async {
      seedTree();
      await open(tester);

      expect(find.text('本会话工作区'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('src'), findsOneWidget);

      // Directories lead, so a long file list never buries the folders.
      final dirY = tester.getTopLeft(find.text('src')).dy;
      final fileY = tester.getTopLeft(find.text('README.md')).dy;
      expect(dirY, lessThan(fileY));
    });

    testWidgets('a directory is opened by its workspace path, not a built one',
        (tester) async {
      seedTree();
      await open(tester);

      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();

      final listed = gateway.calls.where((c) => c.call == 'workspaceList');
      expect(listed.map((c) => c.args), containsAllInOrder(['', 'src']),
          reason: 'the root first, then the child joined with "/"');
      expect(find.text('index.ts'), findsOneWidget);
      // The breadcrumb is a row of tappable segments, not one string.
      expect(find.text('本会话工作区'), findsOneWidget);
      expect(find.text('src'), findsWidgets);
    });

    testWidgets('a file is stat-ed for its absolute path before it is read',
        (tester) async {
      seedTree();
      await open(tester);

      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('index.ts'));
      await tester.pumpAndSettle();

      // The App sends the workspace path unchanged and learns the absolute
      // one back from stat — it never assembles a path itself.
      final stats =
          gateway.calls.where((c) => c.call == 'workspaceStat').map((c) => c.args);
      expect(stats, contains('src/index.ts'));
      final reads =
          gateway.calls.where((c) => c.call == 'workspaceRead').map((c) => c.args);
      expect(reads, contains('/ws/src/index.ts'),
          reason: 'read is issued with the absolute path stat returned');
      expect(find.text('export const a = 1;'), findsOneWidget);
    });

    testWidgets('the 上一级 row walks back up the tree', (tester) async {
      seedTree();
      await open(tester);

      expect(find.text('上一级'), findsNothing, reason: 'the root has no parent');
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      expect(find.text('上一级'), findsOneWidget);

      await tester.tap(find.text('上一级'));
      await tester.pumpAndSettle();

      expect(find.text('README.md'), findsOneWidget);
      final listed = gateway.calls.where((c) => c.call == 'workspaceList');
      expect(listed.map((c) => c.args), containsAllInOrder(['', 'src', '']),
          reason: 'the parent of "src" is the root, walked as a workspace path');
    });

    testWidgets('the viewer back button closes the file, not the pane',
        (tester) async {
      seedTree();
      await open(tester);
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('index.ts'));
      await tester.pumpAndSettle();
      expect(find.text('export const a = 1;'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pumpAndSettle();

      expect(find.text('export const a = 1;'), findsNothing);
      expect(find.text('index.ts'), findsOneWidget,
          reason: 'the listing is still mounted underneath');
    });

    testWidgets('an unreadable entry reports instead of opening', (tester) async {
      seedTree();
      gateway.workspaceUnreadable.add('src/index.ts');
      await open(tester);

      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('index.ts'));
      await tester.pumpAndSettle();

      expect(gateway.calls.where((c) => c.call == 'workspaceRead'), isEmpty,
          reason: 'a refused stat must not turn into a read attempt');
      expect(find.text('src'), findsOneWidget);
    });

    testWidgets('a missing directory shows the error card', (tester) async {
      await open(tester);
      expect(find.byType(InlineErrorCard), findsOneWidget);
    });

    testWidgets('an empty directory says so instead of showing nothing',
        (tester) async {
      gateway.workspaceListings[''] =
          const WorkspaceDirectoryListing(path: '', entries: [], truncated: false);
      await open(tester);
      expect(find.text('这个目录是空的'), findsOneWidget);
    });

    testWidgets('a truncated listing warns', (tester) async {
      gateway.workspaceListings[''] = const WorkspaceDirectoryListing(
        path: '',
        entries: [_dir],
        truncated: true,
      );
      await open(tester);
      expect(find.textContaining('条目过多'), findsOneWidget);
    });

    testWidgets('a multi-page file offers the next page', (tester) async {
      seedTree();
      gateway.workspaceFiles['/ws/src/index.ts'] = const WorkspaceFileText(
        absolutePath: '/ws/src/index.ts',
        version: 'v1',
        bytes: 42,
        offset: 1,
        text: 'line one',
        lines: 1,
        eof: false,
      );
      await open(tester);
      await tester.tap(find.text('src'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('index.ts'));
      await tester.pumpAndSettle();

      expect(find.text('line one'), findsOneWidget);
      expect(find.text('再看 1 行'), findsOneWidget);
    });
  });

  /// D-042 —— 根层散落文件收进「未分类」虚拟分组（纯展示层，磁盘不动）。
  ///
  /// 关键约束是**只折叠根目录这一层**：子目录里的散落文件保持平铺。所以每个
  /// 用例都必须同时钉住「分组出现了」和「真实目录留在分组之外」——只断言前
  /// 者的话，把目录也塞进分组里同样会绿。
  group('D-042 未分类分组（只折叠根层）', () {
    /// 根层混着真实目录、散落文件和一个 `other` 条目（news/ 的真实形态）。
    void seedMixedRoot() {
      gateway.workspaceListings[''] = const WorkspaceDirectoryListing(
        path: '',
        entries: [_loose, _other, _newsDir],
        truncated: false,
      );
      // workspaceRoot 默认 '/ws'，所以工作区路径 report-*.md 对应绝对路径
      // /ws/report-*.md —— 和 Host 接受两种词汇的行为一致。
      gateway.workspaceFiles['/ws/${_loose.name}'] = const WorkspaceFileText(
        absolutePath: '/ws/gamma-judge_2026-09-22_1218_failed.md',
        version: 'v1',
        bytes: 4096,
        offset: 1,
        text: 'judge failed',
        lines: 1,
        eof: true,
      );
    }

    testWidgets('根层的散落文件进分组，真实目录留在分组之外', (tester) async {
      seedMixedRoot();
      await open(tester);

      expect(find.text('未分类'), findsOneWidget);
      expect(find.text('reports'), findsOneWidget);

      // 顺序即归属：目录 → 分组标题 → 分组内文件。目录落在分组标题之前，
      // 说明它没有被收进去。
      final dirY = tester.getTopLeft(find.text('reports')).dy;
      final groupY = tester.getTopLeft(find.text('未分类')).dy;
      final fileY = tester.getTopLeft(find.text(_loose.name)).dy;
      expect(dirY, lessThan(groupY));
      expect(groupY, lessThan(fileY));
    });

    testWidgets('默认展开：分组不额外藏起任何文件', (tester) async {
      seedMixedRoot();
      await open(tester);

      // 折叠是视觉归置，不是"藏起来"。用户不该为了看见自己 cwd 里的文件
      // 多按一次，所以进来就是展开的。
      expect(find.text(_loose.name), findsOneWidget);
      expect(find.byIcon(Icons.expand_more), findsOneWidget,
          reason: '展开态用向下的箭头表示');
      expect(find.byIcon(Icons.chevron_right), findsNothing);
    });

    testWidgets('点标题收起分组，文件从列表消失、目录仍在', (tester) async {
      seedMixedRoot();
      await open(tester);

      await tester.tap(find.text('未分类'));
      await tester.pumpAndSettle();

      expect(find.text(_loose.name), findsNothing);
      expect(find.text('weird.sock'), findsNothing,
          reason: 'other 类型也是"没归置"，跟文件一起收');
      expect(find.text('reports'), findsOneWidget,
          reason: '真实目录在分组之外，收起不该动它');
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);

      await tester.tap(find.text('未分类'));
      await tester.pumpAndSettle();

      expect(find.text(_loose.name), findsOneWidget);
      expect(find.text('reports'), findsOneWidget);
    });

    testWidgets('根层只有目录时不出现分组', (tester) async {
      gateway.workspaceListings[''] = const WorkspaceDirectoryListing(
        path: '',
        entries: [_newsDir],
        truncated: false,
      );
      await open(tester);

      expect(find.text('未分类'), findsNothing,
          reason: '没有可归置的文件就不该凭空造一个分组');
      expect(find.text('reports'), findsOneWidget);
    });

    testWidgets('根层只有散落文件时照样分组（规则统一，不看目录数）',
        (tester) async {
      // 规则是"根层有没归置的文件就分组"，不是"根层有目录才分组"。让一个
      // 扁平输出目录表现不同，只会让人以为分组是某种自动整理的结果。
      gateway.workspaceListings[''] = const WorkspaceDirectoryListing(
        path: '',
        entries: [_loose, _note],
        truncated: false,
      );
      await open(tester);

      expect(find.text('未分类'), findsOneWidget);
      expect(find.text(_loose.name), findsOneWidget);
      expect(find.text('note.md'), findsOneWidget);
    });

    testWidgets('子目录里的散落文件不分组，仍然平铺', (tester) async {
      gateway.workspaceListings[''] = const WorkspaceDirectoryListing(
        path: '',
        entries: [_newsDir],
        truncated: false,
      );
      gateway.workspaceListings['reports'] = const WorkspaceDirectoryListing(
        path: 'reports',
        entries: [_index, _note],
        truncated: false,
      );
      await open(tester);

      await tester.tap(find.text('reports'));
      await tester.pumpAndSettle();

      expect(find.text('未分类'), findsNothing,
          reason: '「未分类」只表达"根目录没归置"这一个语义');
      expect(find.text('index.ts'), findsOneWidget);
      expect(find.text('note.md'), findsOneWidget);
      // 平铺的证据：两个文件行顶部对齐，没有谁缩进在谁下面。
      expect(tester.getTopLeft(find.text('index.ts')).dx,
          tester.getTopLeft(find.text('note.md')).dx);
    });

    testWidgets('分组内文件的字节数照常显示', (tester) async {
      seedMixedRoot();
      await open(tester);

      expect(find.text('4096 字节'), findsOneWidget,
          reason: '分组是展示层，不能顺手把文件信息也收走');
    });

    testWidgets('展开状态下分组内文件仍能点开', (tester) async {
      seedMixedRoot();
      await open(tester);

      await tester.tap(find.text(_loose.name));
      await tester.pumpAndSettle();

      // 折叠不改变取文件的那条路径：先 stat 问绝对路径，再按绝对路径 read。
      final stats =
          gateway.calls.where((c) => c.call == 'workspaceStat').map((c) => c.args);
      expect(stats, contains(_loose.name));
      final reads =
          gateway.calls.where((c) => c.call == 'workspaceRead').map((c) => c.args);
      expect(reads, contains('/ws/${_loose.name}'));
      expect(find.text('judge failed'), findsOneWidget);
    });
  });
}
