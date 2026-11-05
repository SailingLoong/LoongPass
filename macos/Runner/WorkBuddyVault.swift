import Foundation
import Security
import FlutterMacOS
import Darwin

// One lifetime lock for cooperating LoongPass processes; no account database.
// Never unlink owner.lock on release, otherwise another inode could fork owners.
final class WorkBuddyVaultOwnership {
    let root:URL
    private var directory:Int32 = -1, descriptor:Int32 = -1
    enum Failure:Error {case unavailable}
    init(privateRoot:URL)throws{
        root=privateRoot
        guard root.path==root.resolvingSymlinksInPath().path else{throw Failure.unavailable}
        directory=open(root.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard directory>=0 else{throw Failure.unavailable}
        do{
            try validateDirectory()
            descriptor=openat(directory,"owner.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard descriptor>=0 else{throw Failure.unavailable}
            var info=stat()
            guard fstat(descriptor,&info)==0,info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid==geteuid(),info.st_mode & 0o7777==0o600,info.st_nlink==1,
                  flock(descriptor,LOCK_EX|LOCK_NB)==0 else{throw Failure.unavailable}
            try check()
        }catch{release();throw error}
    }
    private func validateDirectory()throws{
        guard let security=filesec_init() else{throw Failure.unavailable};defer{filesec_free(security)}
        var info=stat(),pathInfo=stat()
        guard directory>=0,fstatx_np(directory,&info,security)==0,lstat(root.path,&pathInfo)==0,
              info.st_dev==pathInfo.st_dev,info.st_ino==pathInfo.st_ino,
              info.st_mode & S_IFMT == S_IFDIR,pathInfo.st_mode & S_IFMT == S_IFDIR,
              info.st_uid==geteuid(),info.st_mode & 0o7777==0o700 else{throw Failure.unavailable}
        var present:Int32=0
        guard filesec_query_property(security,FILESEC_ACL,&present)==0 else{throw Failure.unavailable}
        if present==0{return}
        var value:acl_t?
        guard filesec_get_property(security,FILESEC_ACL,&value)==0,let acl=value else{throw Failure.unavailable}
        defer{acl_free(UnsafeMutableRawPointer(acl))}
        guard acl_valid(acl)==0 else{throw Failure.unavailable}
        var entry:acl_entry_t?;errno=0
        guard acl_get_entry(acl,Int32(ACL_FIRST_ENTRY.rawValue),&entry) == -1,errno==EINVAL else{throw Failure.unavailable}
    }
    func check()throws{
        try validateDirectory()
        var opened=stat(),pathInfo=stat()
        guard descriptor>=0,fstat(descriptor,&opened)==0,
              fstatat(directory,"owner.lock",&pathInfo,AT_SYMLINK_NOFOLLOW)==0,
              opened.st_dev==pathInfo.st_dev,opened.st_ino==pathInfo.st_ino,
              pathInfo.st_mode & S_IFMT == S_IFREG,pathInfo.st_uid==geteuid(),
              pathInfo.st_mode & 0o7777==0o600,pathInfo.st_nlink==1 else{throw Failure.unavailable}
    }
    func release(){if descriptor>=0{flock(descriptor,LOCK_UN);close(descriptor);descriptor = -1};if directory>=0{close(directory);directory = -1}}
    deinit{release()}
}

// No default/login Keychain is ever selected. Only explicit fixture injection
// exists in this candidate; real persistent access remains separately disabled.
final class WorkBuddyVault {
    enum Failure: Error { case invalid, unavailable, corrupt }
    private static let lock = NSLock()
    private let keychain: SecKeychain
    private let service = "com.sailingloong.loongpass.workbuddy"
    private let ownership:WorkBuddyVaultOwnership
    init(syntheticKeychain:SecKeychain,ownership:WorkBuddyVaultOwnership)throws{
        try ownership.check()
        var length:UInt32=4096;var bytes=[CChar](repeating:0,count:4096)
        guard SecKeychainGetPath(syntheticKeychain,&length,&bytes)==errSecSuccess,
              URL(fileURLWithPath:String(cString:bytes)).deletingLastPathComponent().path==ownership.root.path else{throw Failure.invalid}
        keychain=syntheticKeychain;self.ownership=ownership
    }
    private init(approvedDefault:SecKeychain,ownership:WorkBuddyVaultOwnership)throws{
        try ownership.check();keychain=approvedDefault;self.ownership=ownership
    }
    static func approvedDefault(ownership:WorkBuddyVaultOwnership)throws->WorkBuddyVault{
        guard persistentAccessValidated else{throw Failure.unavailable}
        try ownership.check()
        var keychain:SecKeychain?
        guard SecKeychainCopyDefault(&keychain)==errSecSuccess,let selected=keychain else{throw Failure.unavailable}
        return try WorkBuddyVault(approvedDefault:selected,ownership:ownership)
    }
    func savedKeys()throws->[String]{
        Self.lock.lock();defer{Self.lock.unlock()};try ownership.check()
        let q:[String:Any]=[kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,
            kSecAttrSynchronizable as String:false,kSecMatchSearchList as String:[keychain],
            kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail,
            kSecMatchLimit as String:kSecMatchLimitAll,kSecReturnAttributes as String:true]
        var output:CFTypeRef?
        let status=try withoutInteraction{SecItemCopyMatching(q as CFDictionary,&output)}
        if status==errSecItemNotFound{return []}
        guard status==errSecSuccess,let rows=output as? [[String:Any]],rows.count<=16 else{throw Failure.unavailable}
        let keys=try rows.map{row->String in
            guard let key=row[kSecAttrAccount as String] as? String,key.utf8.count==64,key.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{throw Failure.corrupt};return key
        }
        guard Set(keys).count==keys.count else{throw Failure.corrupt};return keys.sorted()
    }
    private func query(_ key: String) throws -> [String: Any] {
        try ownership.check()
        guard key.utf8.count == 64, key.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else { throw Failure.invalid }
        return [kSecClass as String:kSecClassGenericPassword,
                kSecAttrService as String:service,kSecAttrAccount as String:key,
                kSecAttrSynchronizable as String:false,
                kSecMatchSearchList as String:[keychain],
                kSecUseAuthenticationUI as String:kSecUseAuthenticationUIFail]
    }
    private func readUnlocked(_ key: String) throws -> [String: Any]? {
        var q = try query(key);q[kSecMatchLimit as String]=kSecMatchLimitOne;q[kSecReturnData as String]=true
        var out: CFTypeRef?
        let status=try withoutInteraction { SecItemCopyMatching(q as CFDictionary,&out) }
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.unavailable }
        guard let data=out as? Data, data.count<=65536,
              let row=try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw Failure.corrupt }
        try validate(row);return row
    }
    private func integer(_ value: Any?) -> Int? {
        guard let n=value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
              n.doubleValue>0, n.doubleValue<=Double(Int32.max),n.doubleValue.rounded()==n.doubleValue else{return nil}
        return n.intValue
    }
    private func validate(_ row: [String:Any]) throws {
        guard integer(row["schema"])==1,integer(row["revision"]) != nil,let state=row["state"] as? String else{throw Failure.invalid}
        if state=="revoked" { guard Set(row.keys)==Set(["schema","revision","state"]) else{throw Failure.invalid};return }
        guard state=="active"||state=="rotationPending",
              Set(row.keys).isSubset(of:Set(["schema","revision","state","domain","endpoint","uid","accessToken","refreshToken","expiresAt"])) else{throw Failure.invalid}
        for name in ["domain","endpoint"] {guard let v=row[name] as? String,["www.workbuddy.cn","www.codebuddy.cn"].contains(v) else{throw Failure.invalid}}
        for name in ["uid","accessToken","refreshToken"] {
            if name=="refreshToken" && row[name]==nil{continue}
            guard let v=row[name] as? String,!v.isEmpty,v.utf8.count<=(name=="uid" ? 512:16384),v.utf8.allSatisfy({(33...126).contains($0)}) else{throw Failure.invalid}
        }
        guard let expiry=row["expiresAt"] as? NSNumber,CFGetTypeID(expiry) != CFBooleanGetTypeID(),expiry.doubleValue>0,expiry.doubleValue<=8640000000000000,expiry.doubleValue.rounded()==expiry.doubleValue else{throw Failure.invalid}
    }
    func read(_ key:String) throws -> [String:Any]? {
        Self.lock.lock();defer{Self.lock.unlock()};return try readUnlocked(key)
    }
    // CAS is protected by both the process lock and the lifetime owner flock.
    // Production Keychain provisioning remains disabled.
    func compareExchange(_ key:String,expected:Int?,value:[String:Any]) throws -> Bool {
        Self.lock.lock();defer{Self.lock.unlock()}
        try validate(value)
        let old=try readUnlocked(key)
        guard old.flatMap({integer($0["revision"])})==expected else{return false}
        let revision=integer(value["revision"])!
        guard revision==(expected ?? 0)+1 else{throw Failure.invalid}
        if let old=old {
            guard old["state"] as? String != "revoked" else{return false}
            if value["state"] as? String != "revoked" {
                guard old["state"] as? String == "active" && ["active","rotationPending"].contains(value["state"] as? String ?? "") || old["state"] as? String == "rotationPending" && value["state"] as? String == "active" else{throw Failure.invalid}
                for name in ["uid","domain","endpoint"]{guard old[name] as? String == value[name] as? String else{throw Failure.invalid}}
            }
        }else{guard ["active","revoked"].contains(value["state"] as? String ?? "") else{throw Failure.invalid}}
        let data=try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        guard data.count<=65536 else{throw Failure.invalid}
        let q=try query(key)
        let status:OSStatus
        if old==nil {
            var add=q;add.removeValue(forKey:kSecMatchSearchList as String);add[kSecUseKeychain as String]=keychain;add[kSecValueData as String]=data
            status=try withoutInteraction { SecItemAdd(add as CFDictionary,nil) }
        }else{status=try withoutInteraction { SecItemUpdate(q as CFDictionary,[kSecValueData as String:data] as CFDictionary) }}
        guard status==errSecSuccess else{throw Failure.unavailable}
        guard let after=try readUnlocked(key),NSDictionary(dictionary:after).isEqual(to:value) else{throw Failure.unavailable}
        return true
    }
    // Legacy Keychain ignores per-query UI flags in some locked cases. Reuse
    // the existing process-wide bridge lock and restore the process UI flag.
    // This never unlocks a Keychain or changes system security configuration.
    private func withoutInteraction(_ operation:()->OSStatus) throws -> OSStatus {
        try LoongPassKeychainLock.withLock {
            var previous=DarwinBoolean(false)
            guard SecKeychainGetUserInteractionAllowed(&previous)==errSecSuccess,
                  SecKeychainSetUserInteractionAllowed(false)==errSecSuccess else{throw Failure.unavailable}
            let status=operation()
            guard SecKeychainSetUserInteractionAllowed(previous.boolValue)==errSecSuccess else{throw Failure.unavailable}
            return status
        }
    }
    static let persistentAccessValidated=true
    static func handle(call:FlutterMethodCall,result:FlutterResult,synthetic:WorkBuddyVault?=nil,production:(()throws->WorkBuddyVault)?=nil)->Bool {
        guard ["readWorkBuddyVault","compareExchangeWorkBuddyVault","listWorkBuddyVaultKeys"].contains(call.method) else{return false}
        let args=call.arguments as? [String:Any]
        let key=args?["key"] as? String
        if call.method != "listWorkBuddyVaultKeys" {
            guard let key=key,key.utf8.count==64,key.utf8.allSatisfy({(48...57).contains($0)||(97...102).contains($0)}) else{result(FlutterError(code:"InvalidVaultArguments",message:nil,details:nil));return true}
        }
        do {
            let vault:WorkBuddyVault
            if let injected=synthetic{vault=injected}
            else{guard persistentAccessValidated,let factory=production else{throw Failure.unavailable};vault=try factory()}
            if call.method=="listWorkBuddyVaultKeys"{result(try vault.savedKeys());return true}
            guard let key=key,let args=args else{throw Failure.invalid}
            if call.method=="readWorkBuddyVault"{result(try vault.read(key))}
            else {
                guard let row=args["value"] as? [String:Any] else{throw Failure.invalid}
                let expected:Int?
                if args["expected"]==nil||args["expected"] is NSNull {expected=nil}
                else {guard let n=vault.integer(args["expected"]) else{throw Failure.invalid};expected=n}
                result(try vault.compareExchange(key,expected:expected,value:row))
            }
        }catch{result(FlutterError(code:"WorkBuddyVaultUnavailable",message:nil,details:nil))}
        return true
    }
}
