import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'mac_qoder_import.dart';
import 'mac_qoder_journal.dart';
import 'qoder_account_flow.dart';
import 'qoder_claim.dart';
import 'qoder_pat_import.dart';

typedef QoderFilePicker =
    Future<QoderPatCandidate?> Function(Future<String?> Function(List<String>));

class QoderAccountsPanel extends StatefulWidget {
  final QoderAccountFlow? flow;
  final QoderFilePicker? picker;
  const QoderAccountsPanel({super.key, this.flow, this.picker});
  @override
  State<QoderAccountsPanel> createState() => _QoderAccountsPanelState();
}

class _QoderAccountsPanelState extends State<QoderAccountsPanel> {
  late QoderAccountFlow flow;
  late bool _ownsFlow;
  bool _importing = false;
  String? _message;
  int _generation = 0;

  void _setFlow() {
    _ownsFlow = widget.flow == null;
    flow = widget.flow ?? QoderAccountFlow(openJournal: MacQoderJournal.open);
  }

  @override
  void initState() {
    super.initState();
    _setFlow();
  }

  @override
  void didUpdateWidget(covariant QoderAccountsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.flow, widget.flow)) {
      if (_ownsFlow) flow.dispose();
      _setFlow();
      _generation++;
      _message = null;
      // Keep a pending picker busy until its finally releases the native scope.
    }
  }

  @override
  void dispose() {
    if (_ownsFlow) flow.dispose();
    super.dispose();
  }

  Future<String?> _chooseProvider(List<String> ids) async {
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('选择 Qoder 配置'),
        content: SizedBox(
          width: 360,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final id in ids)
                  TextButton(
                    key: Key('qoder-provider-$id'),
                    onPressed: () => Navigator.pop(context, id),
                    child: Text(
                      id,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
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
        ],
      ),
    );
  }

  Future<void> _import() async {
    if (_importing || flow.busy) return;
    setState(() {
      _importing = true;
      _message = null;
    });
    final owner = flow;
    final generation = _generation;
    try {
      final candidate = await (widget.picker ?? const MacQoderImport().select)(
        (ids) => mounted && generation == _generation
            ? _chooseProvider(ids)
            : Future<String?>.value(null),
      );
      if (!mounted || generation != _generation) return;
      if (candidate != null) owner.put(candidate);
      setState(
        () => _message = candidate == null
            ? '已取消，未导入账号。'
            : '配置已导入，尚未验证登录。仅保留在本机内存，关闭后需重新导入。',
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      final code = error is QoderFailure ? error.code : '';
      setState(
        () => _message = switch (code) {
          'NativeImportUnavailable' => '无法打开系统文件选择器，请检查 Mac 构建。',
          'NativeImportCleanupFailed' => '文件访问未确认释放，未接收该账号。请关闭应用后重试。',
          'AmbiguousProvider' => '所选文件存在重复账号标识，请先核对文件。',
          'UnsupportedCredentialSource' =>
            '未找到支持的 Qoder 国际版配置。普通 SQL、加密备份和托管账号暂不支持。',
          'AmbiguousCredential' => '所选账号包含不一致的凭据，未导入。',
          _ => '导入未完成，请检查所选配置文件。',
        },
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  String _status(String status) => switch (status) {
    'unverified' => '已导入，未验证',
    'checking' => '正在验证与核对…',
    'claimed' => '本次领取成功 +100',
    'already' => '本轮已领取，未新增额度',
    'confirmed' => '已确认领取，新增额度未知',
    'unknown' => '结果未知，不重复领取',
    'verification' => '认证或官方设备验证未通过',
    'limited' => '请求受限，暂不重试',
    'blocked' => '本机领取记录未能确认，操作被阻止',
    'ineligible' => '当前没有可领取的活动',
    _ => '签到不可用，认证与设备验证尚未接入',
  };

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: flow,
    builder: (context, _) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFE5E6EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Qoder 国际版账号',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '选择已有 Provider JSON，或已有 LoongPort 明文导出中的一条 Qoder 配置。不生成或上传导出文件，不改原文件。',
            style: TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            key: const Key('qoder-import-file'),
            onPressed:
                !_importing &&
                    !flow.busy &&
                    (widget.picker != null ||
                        defaultTargetPlatform == TargetPlatform.macOS)
                ? _import
                : null,
            icon: Icon(
              _importing ? Icons.hourglass_empty : Icons.file_open_outlined,
              size: 16,
            ),
            label: Text(_importing ? '正在导入…' : '从文件导入 Qoder'),
          ),
          if (widget.picker == null &&
              defaultTargetPlatform != TargetPlatform.macOS)
            const Text('系统文件导入目前仅支持 macOS。', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 10),
          if (flow.authenticate == null)
            const Text(
              '认证及官方设备验证尚未接入，签到暂不可用。导入配置不等于登录成功。',
              style: TextStyle(fontSize: 12, color: Color(0xFF9A6700)),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _message!,
                key: const Key('qoder-import-status'),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (flow.accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Text('尚未导入账号', style: TextStyle(color: Color(0xFF86909C))),
            ),
          for (final account in flow.accounts)
            Padding(
              key: Key('qoder-account-${account.providerId}'),
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          account.providerId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton(
                        key: Key('qoder-claim-${account.providerId}'),
                        onPressed:
                            !_importing && flow.canClaim(account.providerId)
                            ? () => flow.claim(account.providerId)
                            : null,
                        child: Text(
                          flow.authenticate == null
                              ? '签到未接入'
                              : account.status == 'checking'
                              ? '核对中…'
                              : account.status == 'unknown'
                              ? '核对结果'
                              : '验证并签到',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _status(account.status),
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
