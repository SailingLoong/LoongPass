import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'mac_file_backup.dart';
import 'zcode_accounts.dart';

void main() => runApp(const AccountToolApp());

class AccountToolApp extends StatelessWidget {
  const AccountToolApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'LoongPass',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF1664FF),
      ).copyWith(primary: const Color(0xFF1664FF), onPrimary: Colors.white),
      scaffoldBackgroundColor: const Color(0xFFF7F8FA),
      visualDensity: VisualDensity.compact,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFFE5E6EB)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
    ),
    home: const _AccountPage(),
  );
}

class _AccountRow {
  final String id;
  final String product;
  final String region;
  final String label;
  final bool canSwitchSample;
  const _AccountRow(
    this.id,
    this.product,
    this.region,
    this.label, {
    this.canSwitchSample = false,
  });
}

class _AccountPage extends StatefulWidget {
  const _AccountPage();
  @override
  State<_AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<_AccountPage> {
  bool _backingUp = false;
  String? _backupMessage;
  String? _backupPath;
  static const _fileBackup = MacFileBackup();

  Future<void> _backupFile() async {
    if (_backingUp) return;
    setState(() {
      _backingUp = true;
      _backupMessage = null;
      _backupPath = null;
    });
    try {
      final path = await _fileBackup.selectAndBackup();
      if (!mounted) return;
      setState(() {
        _backupPath = path;
        _backupMessage = path == null ? '已取消，未备份任何文件。' : '备份已保存，原文件未改变。';
      });
    } catch (error) {
      if (!mounted) return;
      final code = error is AccountFailure ? error.code : '';
      setState(
        () => _backupMessage = switch (code) {
          'NativeBackupUnavailable' => '无法打开本机备份入口。请检查 Mac 构建是否完整。',
          'InvalidDocument' => '请选择有效的 ZCode 认证 JSON 文件。原文件未改变。',
          'DocumentTooLarge' => '文件超过 4 MiB，未备份。',
          'PrivateDirectoryRequired' => '备份目录不符合本机隐私要求，未写入备份。',
          'SourceChanged' => '文件正在变化，请关闭客户端后重试。未改写原文件。',
          'BackupSavedCleanupFailed' => '副本已保存，但临时文件访问未确认释放。请关闭应用后检查备份目录。',
          'NativeCleanupFailed' => '临时文件访问未确认释放，请关闭应用后重试。',
          _ => '备份未完成，原文件未改变。请检查所选文件后重试。',
        },
      );
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _revealBackup() async {
    final path = _backupPath;
    if (path == null) return;
    try {
      await _fileBackup.reveal(path);
    } catch (_) {
      if (!mounted) return;
      setState(() => _backupMessage = '备份已保存，暂时无法在 Finder 中显示。');
    }
  }

  Widget _backupPanel() => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFE5E6EB)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('本机文件备份', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        const Text(
          '手动选择一个 ZCode 认证 JSON，原样保存到本机应用目录。不修改原文件，不切换账号。',
          style: TextStyle(fontSize: 12, color: Color(0xFF86909C)),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          key: const Key('backup-file'),
          onPressed:
              defaultTargetPlatform == TargetPlatform.macOS && !_backingUp
              ? _backupFile
              : null,
          icon: Icon(
            _backingUp ? Icons.hourglass_empty : Icons.file_copy_outlined,
            size: 16,
          ),
          label: Text(_backingUp ? '正在备份…' : '选择文件并备份'),
        ),
        if (defaultTargetPlatform != TargetPlatform.macOS)
          const Text('文件备份目前仅支持 macOS。', style: TextStyle(fontSize: 12)),
        if (_backupMessage != null) ...[
          const SizedBox(height: 8),
          Text(
            _backupMessage!,
            key: const Key('backup-status'),
            style: const TextStyle(fontSize: 12),
          ),
        ],
        if (_backupPath != null)
          TextButton(
            onPressed: _revealBackup,
            child: const Text('在 Finder 中查看'),
          ),
      ],
    ),
  );

  static const _context = 'synthetic-demo-context';
  final _accounts = <_AccountRow>[
    const _AccountRow(
      'zcode-a',
      'ZCode',
      '国际',
      'ZCode 样例 A',
      canSwitchSample: true,
    ),
    const _AccountRow(
      'zcode-b',
      'ZCode',
      '国际',
      'ZCode 样例 B',
      canSwitchSample: true,
    ),
    const _AccountRow('qoder-cn', 'Qoder', '国内', 'Qoder 国内样例'),
    const _AccountRow('qoder-global', 'Qoder', '国际', 'Qoder 国际样例'),
    const _AccountRow('workbuddy-cn', 'WorkBuddy', '国内', 'WorkBuddy 国内样例'),
    const _AccountRow('workbuddy-global', 'WorkBuddy', '国际', 'WorkBuddy 国际样例'),
    const _AccountRow('minimax-cn', 'MiniMax Code', '国内', 'MiniMax 国内样例'),
    const _AccountRow('minimax-global', 'MiniMax Code', '国际', 'MiniMax 国际样例'),
  ];
  final _snapshots = <String, AccountSnapshot>{};
  String _activeId = 'zcode-a';
  String _query = '';
  int _nextId = 3;
  late Map<String, String> _document;

  @override
  void initState() {
    super.initState();
    _document = _syntheticDocument(_activeId);
    for (final row in _accounts.where((row) => row.canSwitchSample)) {
      _snapshots[row.id] = AccountSnapshot.capture(
        AccountIdentity(_context, 'zai', row.id),
        _syntheticDocument(row.id),
      );
    }
  }

  // Explicitly fabricated opaque data, never loaded from the OS or the user.
  Map<String, String> _syntheticDocument(String id) => {
    'oauth:active_provider': 'SYNTHETIC-zai',
    'oauth:zai:access_token': 'SYNTHETIC-$id-access',
    'oauth:zai:refresh_token': 'SYNTHETIC-$id-refresh',
    'oauth:zai:user_info': 'SYNTHETIC-$id-profile',
    'zcodejwttoken': 'SYNTHETIC-$id-jwt',
    'account-provider:coding-plan:account:zai-individual-coding-plan:account:$id:api-key':
        'SYNTHETIC-$id-coding',
    'account-provider:start-plan:account:zai-start-plan:account:$id:api-key':
        'SYNTHETIC-$id-start',
  };

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _switchSample(_AccountRow row) {
    try {
      final plan = SwitchPlan.prepare(
        AccountIdentity(_context, 'zai', _activeId),
        _document,
        _snapshots[row.id]!,
      );
      final next = plan.apply(_document);
      setState(() {
        _snapshots[_activeId] = plan.backup;
        _activeId = row.id;
        _document = next;
      });
      _notice('仅切换了合成样例，原生客户端未改变。');
    } on AccountFailure {
      _notice('样例切换未完成，请重新打开演示。');
    }
  }

  Future<void> _importSample() async {
    final form = GlobalKey<FormState>();
    var label = 'ZCode 样例 $_nextId';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入合成样例'),
        content: SizedBox(
          width: 360,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('添加一个 ZCode 国际版合成账号。不会读取认证文件，也不会连接任何服务。'),
                const SizedBox(height: 20),
                TextFormField(
                  key: const Key('import-label'),
                  initialValue: label,
                  autofocus: true,
                  maxLength: 32,
                  decoration: const InputDecoration(labelText: '账号备注'),
                  onChanged: (value) => label = value,
                  validator: (value) =>
                      value == null || value.trim().isEmpty ? '请输入账号备注' : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-import'),
            onPressed: () {
              if (form.currentState!.validate())
                Navigator.pop(context, label.trim());
            },
            child: const Text('添加样例'),
          ),
        ],
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      final id = 'zcode-${_nextId++}';
      _accounts.add(
        _AccountRow(id, 'ZCode', '国际', result, canSwitchSample: true),
      );
      _snapshots[id] = AccountSnapshot.capture(
        AccountIdentity(_context, 'zai', id),
        _syntheticDocument(id),
      );
    });
    _notice('已添加合成样例，未读取任何认证文件。');
  }

  Widget _status(_AccountRow row) => row.id == _activeId
      ? Container(
          key: Key('current-${row.id}'),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: const Color(0xFFE8F3FF),
            borderRadius: BorderRadius.circular(6),
          ),
          child: const Text(
            '当前样例',
            style: TextStyle(color: Color(0xFF165DFF), fontSize: 12),
          ),
        )
      : Text(
          row.canSwitchSample ? '可演示切换' : '待适配',
          style: const TextStyle(color: Color(0xFF86909C), fontSize: 12),
        );

  Widget _actions(_AccountRow row) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      OutlinedButton(
        key: Key('switch-${row.id}'),
        onPressed: row.canSwitchSample && row.id != _activeId
            ? () => _switchSample(row)
            : null,
        child: const Text('切换样例'),
      ),
      const SizedBox(width: 8),
      OutlinedButton(
        key: Key('checkin-${row.id}'),
        onPressed: null,
        child: const Text('签到'),
      ),
    ],
  );

  Widget _list(List<_AccountRow> rows, bool wide) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 70),
        child: Column(
          children: [
            Icon(Icons.search_off, size: 38, color: Color(0xFF86909C)),
            SizedBox(height: 12),
            Text('没有匹配的账号'),
            SizedBox(height: 8),
            Text('试试平台名称或账号备注。'),
          ],
        ),
      );
    }
    if (wide) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E6EB)),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: DataTable(
                headingRowColor: const WidgetStatePropertyAll(
                  Color(0xFFF2F3F5),
                ),
                headingRowHeight: 44,
                dataRowMinHeight: 58,
                dataRowMaxHeight: 58,
                columnSpacing: 32,
                columns: const [
                  DataColumn(label: Text('平台')),
                  DataColumn(label: Text('账号备注')),
                  DataColumn(label: Text('地区')),
                  DataColumn(label: Text('状态')),
                  DataColumn(label: Text('签到')),
                  DataColumn(label: Text('操作')),
                ],
                rows: rows
                    .map(
                      (row) => DataRow(
                        key: ValueKey(row.id),
                        cells: [
                          DataCell(
                            Text(
                              row.product,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          DataCell(
                            SizedBox(
                              width: 180,
                              child: Text(
                                row.label,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          DataCell(Text(row.region)),
                          DataCell(_status(row)),
                          const DataCell(
                            Text(
                              '未接入',
                              style: TextStyle(color: Color(0xFF86909C)),
                            ),
                          ),
                          DataCell(_actions(row)),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ),
        ),
      );
    }
    return Column(
      children: rows
          .map(
            (row) => Container(
              key: Key(row.id),
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE5E6EB)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _status(row),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${row.product} · ${row.region} · 签到未接入',
                    style: const TextStyle(
                      color: Color(0xFF86909C),
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 12),
                  _actions(row),
                ],
              ),
            ),
          )
          .toList(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final query = _query.trim().toLowerCase();
    final rows = _accounts
        .where(
          (row) => '${row.product} ${row.region} ${row.label}'
              .toLowerCase()
              .contains(query),
        )
        .toList();
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => ListView(
            padding: EdgeInsets.all(constraints.maxWidth < 600 ? 18 : 28),
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8F0FF),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.switch_account_outlined,
                      color: Color(0xFF1664FF),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'LoongPass',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          '同机账号管理',
                          style: TextStyle(
                            color: Color(0xFF86909C),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF0D9),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      '开发预览',
                      style: TextStyle(color: Color(0xFF9A6700), fontSize: 12),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF5FF),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '下方账号列表仅使用合成样例，不读取真实账号、不执行签到，关闭后不保存。本机文件备份为独立入口。',
                  style: TextStyle(
                    color: Color(0xFF3A5A8C),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _backupPanel(),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: constraints.maxWidth < 600
                        ? constraints.maxWidth - 36
                        : 320,
                    child: TextField(
                      key: const Key('account-search'),
                      decoration: const InputDecoration(
                        hintText: '搜索平台或账号备注',
                        prefixIcon: Icon(Icons.search, size: 20),
                        isDense: true,
                      ),
                      onChanged: (value) => setState(() => _query = value),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: _importSample,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('导入样例'),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                '${_accounts.length} 个样例账号',
                style: const TextStyle(color: Color(0xFF86909C), fontSize: 12),
              ),
              const SizedBox(height: 10),
              _list(rows, constraints.maxWidth >= 1000),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('自动签到'),
                      SizedBox(width: 8),
                      Switch(
                        key: Key('auto-checkin'),
                        value: false,
                        onChanged: null,
                      ),
                    ],
                  ),
                  Text(
                    '尚未接入平台授权和签到协议。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
