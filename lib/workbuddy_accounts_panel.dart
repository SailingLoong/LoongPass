import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'native_account_gate.dart';
import 'workbuddy_account_flow.dart';
import 'workbuddy_accounts.dart';
import 'workbuddy_automatic.dart';
import 'workbuddy_claim.dart';
import 'workbuddy_flutter.dart';
import 'workbuddy_vault.dart';
import 'workbuddy_vault_flutter.dart';

class WorkBuddyAccountsPanel extends StatefulWidget {
  const WorkBuddyAccountsPanel({super.key,this.create,this.openAuthorization,this.identityValidationOnly=false,this.savedSingleAccount=false});
  // Keep callbacks stable for this widget lifetime; use a new key to replace
  // them. Rendering creates only the lazy roster, never native/auth callbacks.
  final FutureOr<WorkBuddyAccountFlow> Function()? create;
  final Future<void> Function(Uri)? openAuthorization;
  final bool identityValidationOnly;
  final bool savedSingleAccount;
  @override State<WorkBuddyAccountsPanel> createState()=>_WorkBuddyAccountsPanelState();
}
class _WorkBuddyAccountsPanelState extends State<WorkBuddyAccountsPanel> {
  late final WorkBuddyAccounts _accounts;
  WorkBuddyAutomatic? _automatic;
  WorkBuddyVault? _savedVault;
  final _savedStore=WorkBuddyVaultFlutter();
  WorkBuddyVault get _vault=>_savedVault??=WorkBuddyVault(_savedStore);
  bool _busy=false;
  String? _message;
  bool get _available=>(!widget.savedSingleAccount||workBuddyPersistentAccessValidated)&&(widget.create!=null||widget.openAuthorization!=null
    ?widget.create!=null&&widget.openAuthorization!=null
    :(widget.identityValidationOnly?workBuddyMemoryIdentityApproved:workBuddyNativeAdapterValidated)&&defaultTargetPlatform==TargetPlatform.macOS);
  @override void initState(){
    super.initState();
    _accounts=WorkBuddyAccounts(create:widget.create??(widget.identityValidationOnly?createWorkBuddyIdentityOwner:createWorkBuddyMemoryOwner),
      onChanged:(){if(mounted)setState((){});});
    if(!widget.identityValidationOnly&&!widget.savedSingleAccount)_automatic=WorkBuddyAutomatic(_accounts,onChanged:(){if(mounted)setState((){});});
  }
  Future<void> _run(Future<void> Function() action)async{
    if(_busy)return;
    setState((){_busy=true;_message=null;});
    try{await action();}
    catch(_){if(mounted)setState(()=>_message='操作未完成；没有自动重试，请核对该账号的记录。');}
    finally{if(mounted)setState(()=>_busy=false);}
  }
  Future<void> _start()=>_run(()async{
    if(widget.savedSingleAccount&&_accounts.sessions.isNotEmpty)return;
    final allowed=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
      title:const Text('添加 WorkBuddy 授权账号'),
      content:Text(widget.savedSingleAccount?'为这一个 WorkBuddy 账号前往官网授权。验证身份后，将访问令牌保存到 macOS 钥匙串，供重启后恢复；退出不删除已保存授权。不会自动签到或切换桌面账号。签到需单独操作；本机移除不代表官网撤权。':widget.identityValidationOnly?'只验证当前两个 WorkBuddy 账号的身份。仅向已核官网进行授权和账号资料请求；凭据只保留在本次内存中。不会保存凭据、查询额度、签到或开启自动化。退出即清空本次会话；本机清空不等于官网撤权。':'为每个账号单独前往官方网页授权。凭据仅保留在本次内存中；不含凭据的领取记录保存在本机。不会切换桌面账号，也不会自动签到。退出后需重新授权，原领取记录继续防止重复发送。取消或退出只停止本机使用，不撤销官网已接受的授权。'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('取消')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('继续官方授权'))],
    ));
    if(allowed!=true||!mounted||!_available)return;
    final grant=await _accounts.beginAuthorization();
    if(!mounted||grant==null)return;
    try{
      await (widget.openAuthorization??(widget.identityValidationOnly?openWorkBuddyIdentityAuthorization:openWorkBuddyAuthorization))(grant.url);
      if(mounted)_accounts.followAuthorization(grant.sessionId,
        vault:widget.savedSingleAccount?_vault:null,
        savedKeys:widget.savedSingleAccount?_savedStore.savedKeys:null);
    }
    catch(_){_accounts.cancelAuthorization(grant.sessionId);if(mounted)_message='未能确认授权页已打开；仅取消本次授权会话。';}
  });
  Future<void> _restore()=>_run(()async{
    if(!widget.savedSingleAccount||_accounts.sessions.isNotEmpty||!_available)return;
    final allowed=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
      title:const Text('恢复 WorkBuddy 账号'),
      content:const Text('读取 LoongPass 自己保存的单个钥匙串授权，并向官网验证账号身份。不会读取官方客户端账号，也不会签到；钥匙串不可用时停止，不修改权限或解锁设置。'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('取消')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('恢复并验证身份'))],
    ));
    if(allowed!=true||!mounted||!_available)return;
    await _accounts.restoreSingle(_vault,_savedStore.savedKeys);
  });
  Future<void> _poll(String id)async{
    if(widget.savedSingleAccount){await _accounts.pollAndSave(id,_vault,savedKeys:_savedStore.savedKeys);}
    else{await _accounts.poll(id);}
  }
  Future<void> _claim(WorkBuddyAccountSession account)=>_run(()async{
    final allowed=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
      title:const Text('通过 LoongPass 签到'),
      content:const Text('仅为当前账号核对活动及完整额度，并尝试一次今日签到。这可能消耗当日签到机会；结果未知时保留记录，不重复补发。不会切换官方客户端账号。'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('取消')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('核对并签到一次'))],
    ));
    if(allowed==true&&mounted)await _accounts.claim(account.id);
  });
  Future<void> _remove(WorkBuddyAccountSession account)=>_run(()async{
    final allowed=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
      title:const Text('移除本次内存账号'),
      content:Text(widget.savedSingleAccount?'仅停止本次内存会话，钥匙串授权与领取记录仍保留，可再次恢复。可能已发出的请求无法撤回；删除保存授权须另行确认。':'仅移除此授权会话，不退出官方客户端、不删除账号数据或领取记录。可能已经发送的请求无法撤回；未知结果不会自动补发。'),
      actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('取消')),
        FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('移除内存账号'))],
    ));
    if(allowed==true&&mounted){_automatic?.setEnabled(account.id,false);_accounts.remove(account.id);}
  });
  void _toggleAutomatic(WorkBuddyAccountSession account,bool value){
    if(widget.identityValidationOnly)return;
    if(!value){_automatic?.setEnabled(account.id,false);return;}
    unawaited(_run(()async{
      final allowed=await showDialog<bool>(context:context,builder:(context)=>AlertDialog(
        title:const Text('开启本次会话一次自动签到'),
        content:const Text('仅为当前选中的授权账号开启。共享会话定时器启动 30 秒后首查，此后每 15 分钟检查；新增账号随下一轮检查；服务端状态可签到时才发送一次。成功或未知结果均停止本次自动尝试，不补发。关闭开关、移除账号或退出面板会话即停止；不保存凭据或自动化选项，重启后不会恢复。已经发送的请求无法撤回。'),
        actions:[TextButton(onPressed:()=>Navigator.pop(context,false),child:const Text('取消')),
          FilledButton(onPressed:()=>Navigator.pop(context,true),child:const Text('开启本次会话'))],
      ));
      if(allowed==true&&mounted&&!(_automatic?.setEnabled(account.id,true)??false)){
        _message='当前账号不能开启自动签到，请核对授权状态与已有领取记录。';
      }
    }));
  }
  String _status(WorkBuddyState state) => switch (state) {
    WorkBuddyState.available => '当前活动可签到（仅查询，尚未领取）',
    WorkBuddyState.alreadyClaimed || WorkBuddyState.claimed => '服务端显示今日已签到（未核实本次额度）',
    WorkBuddyState.unavailable => '当前活动不可领取',
    WorkBuddyState.needsVerification => '账号需要重新核验',
    WorkBuddyState.unconfirmed => '当前活动状态未确认',
  };

  String _result(WorkBuddyResult result) => switch (result.state) {
    WorkBuddyState.claimed => '已核实本次到账 ${result.credited} 额度。',
    WorkBuddyState.alreadyClaimed => '服务端显示已签到，本次没有重复领取。',
    WorkBuddyState.needsVerification => '账号需要重新核验；不会自动重试签到。',
    WorkBuddyState.unavailable => '当前活动不满足领取条件。',
    _ => '本次结果未知，未确认到账，不重复领取；已存在的领取记录会保留。',
  };

  @override void dispose(){_automatic?.close();_accounts.close();_savedVault?.close();super.dispose();}
  @override Widget build(BuildContext context){
    final selected=_accounts.selected,pending=_accounts.pending;
    final status=selected?.status,result=selected?.result;
    return Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      Text(widget.savedSingleAccount?'WorkBuddy 单账号授权、保存恢复与签到。凭据保存在本机钥匙串；签到通过 LoongPass 执行，不自动签到或切换官方客户端。':widget.identityValidationOnly?'WorkBuddy 临时双账号身份验证 · 凭据仅留在内存，退出即清空。此模式不提供签到、额度、自动化或持久保存。':'WorkBuddy 多账号独立授权与签到接线预览。自动默认关闭，可逐账号选择本次会话一次自动检查与签到；不切换桌面账号，凭据仅保留在本次内存中。'),
      const SizedBox(height:12),
      FilledButton(key:const Key('workbuddy-login'),onPressed:_available&&!_busy&&(!widget.savedSingleAccount||_accounts.sessions.isEmpty)?_start:null,
        child:const Text('授权 WorkBuddy 账号')),
      if(widget.savedSingleAccount)TextButton(key:const Key('workbuddy-restore'),onPressed:_available&&!_busy&&_accounts.sessions.isEmpty?_restore:null,child:const Text('恢复已保存账号')),
      if(!_available)Padding(padding:const EdgeInsets.only(top:12),child:Text(widget.identityValidationOnly?'真实身份验证尚未获得当次确认，授权按钮保持关闭。':'真实授权、保存恢复及签到仍等待相应验收和当次确认。当前不得据编译或合成检查认定实号可用。')),
      if(_busy)const LinearProgressIndicator(),
      if(_message??_accounts.message case final String message)
        Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Text(message)),
      for(final session in pending)Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(
        crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('待授权会话 ${session.id}'),
          if(session.message case final String message)Text(message),
          Wrap(spacing:12,children:[
            OutlinedButton(key:Key(pending.length==1?'workbuddy-poll':'workbuddy-poll-${session.id}'),
              onPressed:_busy?null:()=>_run(()=>_poll(session.id)),child:const Text('检查授权结果')),
            TextButton(key:Key(pending.length==1?'workbuddy-cancel':'workbuddy-cancel-${session.id}'),
              onPressed:_busy?null:()=>setState(()=>_accounts.cancelAuthorization(session.id)),child:const Text('取消此授权')),
          ]),
        ],
      ))),
      if(_accounts.accounts.isNotEmpty)Padding(padding:const EdgeInsets.symmetric(vertical:12),child:Wrap(
        spacing:8,runSpacing:8,children:[for(final account in _accounts.accounts)ChoiceChip(
          key:Key('workbuddy-account-${account.id}'),label:Text('${account.uid} · ${account.domain}'),
          selected:selected?.id==account.id,onSelected:_busy?null:(value){if(value)setState(()=>_accounts.select(account.id));},
        )],
      )),
      if(selected?.uid!=null)Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(
        crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text(selected!.uid!),Text(selected.domain??''),
          Text(widget.savedSingleAccount?'已核实授权身份 · 本机保存账号 · 未切换桌面账号':'已核实授权身份 · 本次内存会话 · 未切换桌面账号'),
          if(selected.message case final String message)Text(message),
          const SizedBox(height:8),
          if(!widget.identityValidationOnly)...[
          Wrap(spacing:12,runSpacing:8,children:[
            OutlinedButton(key:const Key('workbuddy-status'),onPressed:_busy?null:()=>_run(()=>_accounts.refreshStatus(selected.id)),child:const Text('查询此账号签到状态')),
            OutlinedButton(key:const Key('workbuddy-balance'),onPressed:_busy?null:()=>_run(()=>_accounts.refreshBalance(selected.id)),child:const Text('查询此账号完整额度')),
            OutlinedButton(key:const Key('workbuddy-claim'),onPressed:!_busy&&!_accounts.claimBusy&&selected.canClaim?()=>_claim(selected):null,child:const Text('核对并签到')),
            TextButton(key:const Key('workbuddy-remove'),onPressed:_busy?null:()=>_remove(selected),child:const Text('移除本次内存账号')),
          ]),
          if(!widget.savedSingleAccount)SwitchListTile.adaptive(
            key:const Key('workbuddy-automatic'),contentPadding:EdgeInsets.zero,
            title:const Text('本次授权会话自动检查并签到一次'),
            subtitle:const Text('共享会话定时器启动 30 秒后首查，之后每 15 分钟检查；新增账号随下一轮。关闭或退出即停止，未知结果不重发。重启后需重新授权和选择。'),
            value:_automatic?.enabled(selected.id)??false,
            onChanged:(_automatic?.enabled(selected.id)??false)||(!_busy&&!selected.busy&&selected.canClaim&&selected.claimOwnerAvailable)
              ?(value)=>_toggleAutomatic(selected,value):null,
          ),
          if(!selected.claimOwnerAvailable)const Text('尚缺持久化领取记录，不能发送签到。'),
          ]else TextButton(key:const Key('workbuddy-remove'),onPressed:_busy?null:()=>_remove(selected),child:const Text('移除本次内存账号')),
          if(selected.totalRemaining case final double total)Text('已核实完整剩余额度：$total'),
          if(status!=null)Padding(padding:const EdgeInsets.only(top:8),child:Text(_status(status))),
          if(result!=null)Padding(padding:const EdgeInsets.only(top:8),child:Text(_result(result))),
        ],
      ))),
    ]);
  }
}
