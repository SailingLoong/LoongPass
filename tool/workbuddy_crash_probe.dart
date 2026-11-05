// Synthetic process-crash probe; never constructs an HTTP/credential owner.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../lib/workbuddy_attempt_journal.dart';
import '../lib/workbuddy_claim.dart';

Future<void> main(List<String> args) async {
  final mode=args[0], root=Directory(args[1]), helper=args[2];
  final generation=args.length>3?args[3]:'synthetic-generation';
  final day=args.length>4?DateTime.parse(args[4]):DateTime.utc(2026,11,4,3);
  final subject=WorkBuddySubject('www.workbuddy.cn','SYNTHETIC-CRASH-UID',generation);
  final ledger=File('${root.parent.path}/synthetic-dispatch-ledger');
  var live=true,syncs=0;
  Future<void> barrier(String label) async {
    stdout.writeln('BARRIER:$label');await stdout.flush();
    final timer=Timer.periodic(const Duration(seconds:1),(_){});
    try { await Completer<void>().future; } finally {timer.cancel();}
  }
  Future<void> nativeSync() async {
    final r=await Process.run(helper,['sync',root.path]);
    if(r.exitCode!=0)throw StateError('SyntheticNativeSyncFailure');
  }
  final journal=WorkBuddyAttemptJournal(root,isCurrent:(_)=>live,syncDirectory:() async {
    syncs++;
    if(mode=='before-sync'&&syncs==1)await barrier('before-sync');
    await nativeSync();
    if(mode=='after-sync'&&syncs==1)await barrier('after-sync');
    if(mode=='receipt'&&syncs==2)await barrier('receipt');
    if(mode=='settled'&&syncs==3)await barrier('settled');
    if(mode=='revoke'&&syncs==1)live=false;
  });
  if(mode=='read'){
    try {final row=await journal.read(subject.key);print(jsonEncode({'revision':row?.revision,'receipt':row?.receipt.name,'settled':row?.settled.name}));}
    on WorkBuddyFailure catch(e){print(jsonEncode({'error':e.code}));}
    return;
  }
  final transport=SyntheticTransport(ledger,mode,barrier);
  try {
    final result=await WorkBuddyClaimCore(journal,transport,()=>day,isCurrent:(_)=>live).claim(subject);
    print(jsonEncode({'state':result.state.name,'credited':result.credited,'posts':transport.posts,'observes':transport.observes}));
  } on WorkBuddyFailure catch(e){print(jsonEncode({'error':e.code,'posts':transport.posts,'observes':transport.observes}));}
}
class SyntheticTransport implements WorkBuddyTransport {
 final File ledger;final String mode;final Future<void> Function(String) barrier;
 int posts=0,observes=0;
 SyntheticTransport(this.ledger,this.mode,this.barrier);
 @override Future<WorkBuddyObservation> observe(WorkBuddySubject who) async {
  observes++;final sent=await ledger.exists()&&await ledger.length()>0;
  return WorkBuddyObservation(who,{'code':0,'data':{'active':true,'today_checked_in':sent}},sent?30:10);
 }
 @override Future<Map<String,Object?>> claim(WorkBuddySubject who) async {
  posts++;await ledger.writeAsString('SYNTHETIC-DISPATCH\n',mode:FileMode.append,flush:true);
  if(mode=='dispatch')await barrier('dispatch');
  return {'code':0,'data':{'credit':20}};
 }
}
