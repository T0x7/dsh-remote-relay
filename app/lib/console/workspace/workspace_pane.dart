import 'package:dsh_remote_core/api/engine_gateway.dart';
import 'package:dsh_remote_core/api/error_code.dart';
import 'package:dsh_remote_core/api/engine_models.dart';
import 'package:dsh_remote_app/l10n/generated/app_localizations.dart';
import 'package:dsh_remote_app/logging/app_log.dart';
import 'package:dsh_remote_app/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../inline_error_card.dart';

/// The workspace view (mockup 屏 M, 工作区 segment).
///
/// The tree is the **session's** own workspace, not the machine's: the Host
/// resolves `workspaceFileScope` from the session header
/// (`api/workspace-files/src/index.ts:210-224`), so this pane can only ever
/// show what that one session is allowed to see. That is the property worth
/// stating in the UI, so the header says "this session" rather than "this
/// machine".
///
/// **Two path vocabularies, and the pane keeps them apart**
/// (`types.ts:1-15`): the directory list walks *workspace paths* (`''` is the
/// root, children join with `/`), while opening a file asks for its
/// **absolute** path — which is exactly what the listing's children do not
/// carry. So a child is navigated by its workspace path, and a file is read
/// by asking `stat` for the absolute path of `root + workspacePath`; the
/// root comes from the same listing round-trip that produced the entries, so
/// the App never assembles a path itself.
///
/// **D-043: the root's loose files fold into a virtual「未分类」group**
///
/// A session's `cwd` is often a working directory rather than a curated tree
/// (the reference case, `~/.dsh-host/data/inbox/`, holds 3 folders next to 23
/// generated `*.md` files), so the root renders as a wall of files. The group
/// is a **presentation-only** device: the Host still sees a flat directory, no
/// file is moved, and every path the pane sends is still the listing's own
/// workspace path. It is deliberately scoped to the root — 「未分类」states
/// "not filed under a directory *here*", and that only means something at the
/// level where a user would file things in the first place; folding a
/// subdirectory's loose files would say the same thing about a directory the
/// user already organized.
class WorkspacePane extends StatefulWidget {
  const WorkspacePane({
    super.key,
    required this.gateway,
    required this.sessionId,
    required this.l10n,
  });

  final EngineGateway gateway;
  final String sessionId;
  final L10n l10n;

  @override
  State<WorkspacePane> createState() => _WorkspacePaneState();
}

class _WorkspacePaneState extends State<WorkspacePane> {
  /// Workspace path of the directory on screen; `''` is the root.
  String _path = '';

  WorkspaceDirectoryListing? _listing;
  AppError? _error;
  bool _loading = false;

  /// The file being viewed, if any.
  _OpenFile? _open;

  /// D-043: the root's「未分类」group is **open by default**. Folding is
  /// tidying, not hiding: a group that starts closed costs the user one tap per
  /// visit to see a file they already had, and the pane has no other collapsed
  /// affordance to normalize against. The group is a presentation device, so
  /// an open-by-default group is also the one that cannot surprise anyone into
  /// believing a file is missing.
  bool _uncategorizedExpanded = true;

  @override
  void initState() {
    super.initState();
    // The root listing is the pane's first frame, not something the user asks
    // for: without this the tree opens blank until a pull-to-refresh.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _listing == null) _load('');
    });
  }

  @override
  void didUpdateWidget(WorkspacePane old) {
    super.didUpdateWidget(old);
    if (old.sessionId != widget.sessionId) {
      // A different session is a different tree: drop the root, the path and
      // any open file rather than showing another session's files.
      _path = '';
      _listing = null;
      _open = null;
      _error = null;
      // Same reasoning for the D-043 group: its collapsed state belongs to the
      // tree the user was just looking at, not to the session.
      _uncategorizedExpanded = true;
    }
  }

  Future<void> _load(String path) async {
    setState(() {
      _path = path;
      _loading = true;
      _error = null;
    });
    final result =
        await widget.gateway.workspaceList(sessionId: widget.sessionId, path: path);
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result.isOk) {
        final listing = result.value! as WorkspaceDirectoryListing;
        _listing = listing;
      } else {
        AppLog.w('workspace',
            'listing failed: code=${result.error!.code} ${result.error!.message}');
        _error = result.error!.toAppError();
      }
    });
  }

  Future<void> _openEntry(WorkspaceDirectoryEntry entry) async {
    if (entry.isDirectory) {
      await _load(_listing!.pathOf(entry));
      return;
    }
    // A `file` listing is not a promise the content reads (a symlink reports
    // its destination's type, and `read` refuses links). `stat` both proves
    // readability and hands back the absolute path in the same round-trip.
    final childPath = _listing!.pathOf(entry);
    final located = await _resolve(childPath);
    if (!mounted) return;
    if (located == null) {
      setState(() => _error = _unreadableEntry());
      return;
    }
    setState(() {
      _error = null;
      _open = _OpenFile(path: childPath, absolutePath: located);
    });
    await _readPage(offset: 1);
  }

  /// Confirm a listed file is readable, and learn its absolute path.
  ///
  /// `list` returns only a basename, and the Host accepts *either* vocabulary
  /// on `stat`/`read` ("absolute **or** path relative to the workspace root",
  /// `index.ts:298-302`), so the workspace path is sent unchanged and the
  /// absolute form comes back in the response. Building an absolute path in
  /// the App would mean guessing the session's root, which the App does not
  /// know — this is the only correct join point.
  Future<String?> _resolve(String workspacePath) async {
    final result = await widget.gateway.workspaceStat(
      sessionId: widget.sessionId,
      absolutePath: workspacePath,
    );
    if (result.isOk) {
      return (result.value! as WorkspaceFileStat).absolutePath;
    }
    return null;
  }

  Future<void> _readPage({required int offset}) async {
    final open = _open;
    if (open == null) return;
    final result = await widget.gateway.workspaceRead(
      sessionId: widget.sessionId,
      absolutePath: open.absolutePath,
      offset: offset,
    );
    if (!mounted) return;
    setState(() {
      if (result.isOk) {
        open.page = result.value! as WorkspaceFileText;
        _error = null;
      } else {
        AppLog.w('workspace',
            'file open failed: code=${result.error!.code} ${result.error!.message}');
        _error = result.error!.toAppError();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = widget.l10n;
    if (_open != null) return _buildViewer(l10n);
    if (_loading && _listing == null) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null && _listing == null) {
      return InlineErrorCard(
        error: _error!,
        l10n: l10n,
      );
    }

    final listing = _listing;
    final directories = listing?.entries.where((e) => e.isDirectory).toList() ?? const [];
    final files = listing?.entries.where((e) => !e.isDirectory).toList() ?? const [];

    // D-043: the group exists at the root only. At every other level the loose
    // files stay flat, so exactly one of these two lists is ever non-empty —
    // which is what keeps an entry from being rendered twice or not at all.
    final groupLooseFiles = _path.isEmpty;
    final looseFiles =
        groupLooseFiles ? files : const <WorkspaceDirectoryEntry>[];
    final flatFiles = groupLooseFiles
        ? const <WorkspaceDirectoryEntry>[]
        : files;

    return RefreshIndicator(
      onRefresh: () => _load(_path),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppTheme.l, AppTheme.m, AppTheme.l, AppTheme.xl),
        children: [
          _Breadcrumbs(
            path: _path,
            l10n: l10n,
            onNavigate: (path) => _load(path),
          ),
          const SizedBox(height: AppTheme.s),
          if (listing?.truncated ?? false)
            Padding(
              padding: const EdgeInsets.only(bottom: AppTheme.s),
              child: Text(l10n.workspaceTruncated,
                  style: const TextStyle(fontSize: 11, color: AppTheme.warn)),
            ),
          if (_path.isNotEmpty)
            _Row(
              icon: Icons.arrow_upward,
              title: l10n.workspaceParent,
              subtitle: null,
              onTap: () => _load(_parentOf(_path)),
            ),
          for (final entry in directories)
            _Row(
              icon: Icons.folder_outlined,
              title: entry.name,
              subtitle: null,
              onTap: () => _openEntry(entry),
            ),
          for (final entry in flatFiles)
            _Row(
              icon: _fileIconOf(entry),
              title: entry.name,
              subtitle: _sizeOf(entry),
              onTap: () => _openEntry(entry),
            ),
          // D-043: no group is drawn for an empty set — a header the user
          // cannot expand is a dead row, and the root's "all folders" case
          // should keep looking exactly like the pane looked before D-043.
          if (looseFiles.isNotEmpty) ...[
            _GroupHeader(
              title: l10n.workspaceUncategorized,
              expanded: _uncategorizedExpanded,
              onTap: () =>
                  setState(() => _uncategorizedExpanded = !_uncategorizedExpanded),
            ),
            if (_uncategorizedExpanded)
              for (final entry in looseFiles)
                _Row(
                  icon: _fileIconOf(entry),
                  title: entry.name,
                  subtitle: _sizeOf(entry),
                  onTap: () => _openEntry(entry),
                  // Nested, so a grouped file reads as belonging to the
                  // header rather than as another root child.
                  indent: AppTheme.m,
                ),
          ],
          if (listing != null && listing.entries.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppTheme.xl),
              child: Text(l10n.workspaceEmpty,
                  textAlign: TextAlign.center,
                  style:
                      const TextStyle(fontSize: 12.5, color: AppTheme.inkDim)),
            ),
          if (_error != null)
            InlineErrorCard(error: _error!, l10n: l10n),
        ],
      ),
    );
  }

  Widget _buildViewer(L10n l10n) {
    final open = _open!;
    final page = open.page;
    return Column(
      children: [
        Row(
          children: [
            IconButton(
              tooltip: l10n.workspaceBack,
              onPressed: () => setState(() => _open = null),
              icon: const Icon(Icons.arrow_back, size: 18),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(open.path,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                  if (page != null && page.bytes != null)
                    Text(l10n.workspaceSize(page.bytes!),
                        style: const TextStyle(
                            fontSize: 11, color: AppTheme.inkDim)),
                ],
              ),
            ),
            IconButton(
              tooltip: l10n.workspaceCopy,
              onPressed: page == null
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: page.text));
                      if (!mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l10n.workspaceCopied)),
                      );
                    },
              icon: const Icon(Icons.copy_all_outlined, size: 18),
            ),
          ],
        ),
        if (_error != null)
          InlineErrorCard(error: _error!, l10n: l10n),
        Expanded(
          child: page == null
              ? const Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(
                      AppTheme.l, AppTheme.s, AppTheme.l, AppTheme.xl),
                  child: SelectableText(
                    page.text,
                    style: const TextStyle(
                        fontSize: 12, fontFamily: 'monospace', height: 1.45),
                  ),
                ),
        ),
        if (page != null && page.hasMore)
          Padding(
            padding: const EdgeInsets.all(AppTheme.s),
            child: OutlinedButton(
              onPressed: () => _readPage(offset: page.offset + page.lines),
              child: Text(l10n.workspaceMoreLines(page.lines)),
            ),
          ),
      ],
    );
  }

  /// The parent of a workspace path (`''` at the root).
  static String _parentOf(String path) {
    final cut = path.lastIndexOf('/');
    return cut < 0 ? '' : path.substring(0, cut);
  }

  String? _sizeOf(WorkspaceDirectoryEntry entry) {
    final size = entry.size;
    if (size == null) return null;
    return widget.l10n.workspaceSize(size);
  }
}

/// One open file: the workspace path it was found at, the absolute path the
/// engine confirmed, and the page currently rendered.
class _OpenFile {
  _OpenFile({required this.path, required this.absolutePath});

  final String path;
  final String absolutePath;
  WorkspaceFileText? page;
}

/// A listing fact that `stat` refused — the honest "listed but not
/// readable" answer, distinct from a transport error.
AppError _unreadableEntry() => const AppError(
      ErrorCode.engineUnknown,
      detail: 'workspace-file: listed but unreadable',
    );

/// The glyph for a non-directory entry. Shared by the flat and grouped
/// rendering so D-043's grouping cannot quietly change what a row looks like.
IconData _fileIconOf(WorkspaceDirectoryEntry entry) =>
    entry.type == WorkspaceEntryType.other
        ? Icons.help_outline
        : Icons.insert_drive_file_outlined;

/// D-043's「未分类」header.
///
/// It is drawn like a row but is not one: the icon is a label rather than a
/// folder (no such directory exists on disk) and the title is weighted to
/// separate it from a filename at a glance. The chevron sits on the trailing
/// edge, which is why the header keeps the same left inset as its children —
/// the nesting is carried by the children's indent, not by pushing the group
/// title in.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.expanded,
    required this.onTap,
  });

  final String title;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.s),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(vertical: 9, horizontal: AppTheme.xs),
          child: Row(
            children: [
              Icon(Icons.label_outlined, size: 16, color: AppTheme.inkDim),
              const SizedBox(width: AppTheme.s),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.ink)),
              ),
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: AppTheme.inkDim,
              ),
            ],
          ),
        ),
      );
}

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({
    required this.path,
    required this.l10n,
    required this.onNavigate,
  });

  final String path;
  final L10n l10n;
  final void Function(String path) onNavigate;

  @override
  Widget build(BuildContext context) {
    final segments = path.isEmpty ? const <String>[] : path.split('/');
    final children = <Widget>[
      GestureDetector(
        onTap: () => onNavigate(''),
        child: Text(l10n.workspaceRootLabel,
            style: TextStyle(
              fontSize: 12,
              fontFamily: 'monospace',
              color: segments.isEmpty ? AppTheme.ink : AppTheme.accent,
            )),
      ),
    ];
    var walked = '';
    for (final segment in segments) {
      walked = walked.isEmpty ? segment : '$walked/$segment';
      final target = walked;
      children
        ..add(Text(' /',
            style: const TextStyle(fontSize: 12, fontFamily: 'monospace')))
        ..add(GestureDetector(
          onTap: () => onNavigate(target),
          child: Text(segment,
              style: const TextStyle(
                  fontSize: 12, fontFamily: 'monospace', color: AppTheme.accent)),
        ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: children),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.indent = 0,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  /// Extra left inset, used by D-043 to nest a grouped file under its header.
  final double indent;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.s),
        child: Padding(
          padding: EdgeInsets.fromLTRB(AppTheme.xs + indent, 9, AppTheme.xs, 9),
          child: Row(
            children: [
              Icon(icon, size: 16, color: AppTheme.inkDim),
              const SizedBox(width: AppTheme.s),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(fontSize: 13, color: AppTheme.ink)),
                    if (subtitle != null)
                      Text(subtitle!,
                          style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'monospace',
                              color: AppTheme.inkDim)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}
