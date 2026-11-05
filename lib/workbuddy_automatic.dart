// In-process scheduling. The existing claim journal decides whether a daily
// attempt may be sent. Credential restoration belongs to the account owner.
import 'dart:async';
import 'workbuddy_accounts.dart';
import 'workbuddy_claim.dart';

typedef WorkBuddySchedule = void Function() Function(Duration,void Function());
void Function() _once(Duration delay,void Function() action){final timer=Timer(delay,action);return timer.cancel;}
void Function() _periodic(Duration period,void Function() action){final timer=Timer.periodic(period,(_)=>action());return timer.cancel;}

class WorkBuddyAutomatic {
  final WorkBuddyAccounts accounts;
  final WorkBuddySchedule once,periodic;
  final void Function()? onChanged;
  final _enabled=<String>{};
  final _revisions=<String,int>{};
  bool _closed=false,_ticking=false,_started=false;
  int _revision=0,_timerEpoch=0;
  void Function()? _cancelStartup,_cancelPeriodic;
  WorkBuddyAutomatic(this.accounts,{WorkBuddySchedule? once,WorkBuddySchedule? periodic,this.onChanged})
    :once=once??_once,periodic=periodic??_periodic;
  WorkBuddyAccountSession? _account(String id){for(final s in accounts.accounts){if(s.id==id)return s;}return null;}
  bool enabled(String id)=>!_closed&&_enabled.contains(id)&&_account(id)!=null;
  bool _current(String id,int revision)=>enabled(id)&&_revisions[id]==revision;
  void _notify(){try{onChanged?.call();}catch(_){/* UI cannot alter claim outcome. */}}
  bool setEnabled(String id,bool value){
    if(_closed)return false;
    if(value){
      if(enabled(id))return true;
      final account=_account(id);
      if(account==null||account.busy||!account.canClaim||!account.claimOwnerAvailable)return false;
      _enabled.add(id);_revisions[id]=++_revision;_start();
    }else{
      if(!_enabled.remove(id))return true;
      _revisions[id]=++_revision;
      if(_enabled.isEmpty)_stopTimers();
    }
    _notify();return true;
  }
  void _start(){
    if(_closed)return;
    if(!_started){_started=true;_timerEpoch++;}
    final epoch=_timerEpoch;
    void fire(){if(!_closed&&_timerEpoch==epoch)unawaited(tick());}
    // Same existing in-process cadence as MiniMax, never a daemon/login item.
    _cancelStartup?.call();
    _cancelStartup=once(const Duration(seconds:30),fire);
    _cancelPeriodic??=periodic(const Duration(minutes:15),fire);
  }
  void _stopTimers(){
    _timerEpoch++;_cancelStartup?.call();_cancelPeriodic?.call();
    _cancelStartup=null;_cancelPeriodic=null;_started=false;
  }
  Future<void> tick()async{
    if(_closed||_ticking||_enabled.isEmpty)return;
    _ticking=true;
    final snapshot=[for(final id in _enabled)(id:id,revision:_revisions[id]!)];
    try{
      for(final policy in snapshot){
        final id=policy.id,revision=policy.revision;
        if(_enabled.contains(id)&&_account(id)==null){setEnabled(id,false);continue;}
        if(!_current(id,revision))continue;
        final account=_account(id);
        if(account==null||account.busy||accounts.claimBusy)continue;
        if(!account.canClaim){setEnabled(id,false);continue;}
        try{
          final checking=accounts.refreshStatus(id,admission:()=>_current(id,revision));_notify();await checking;
          if(!_current(id,revision))continue;
          if(account.status==WorkBuddyState.needsVerification){setEnabled(id,false);continue;}
          if(account.status!=WorkBuddyState.available||!account.canClaim||accounts.claimBusy)continue;
          final claiming=accounts.claim(id,admission:()=>_current(id,revision));_notify();await claiming;
          // Settled days remain scheduled for tomorrow. An unknown outcome or
          // invalid authorization stops; the durable journal is never reset.
          if(_current(id,revision)&&!account.canClaim)setEnabled(id,false);
        }catch(_){
          // No error permits a POST retry. Existing core/journal retain intent.
          if(_current(id,revision))setEnabled(id,false);
        }
      }
    }finally{_ticking=false;if(!_closed)_notify();}
  }
  void close(){
    if(_closed)return;_closed=true;_revision++;_enabled.clear();_stopTimers();
    // Do not notify during widget disposal; in-flight work is gated by closed.
  }
}
