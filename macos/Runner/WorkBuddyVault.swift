import Foundation
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
    func synchronize() throws { try check(); guard fsync(directory) == 0 else { throw Failure.unavailable } }
    func release(){if descriptor>=0{flock(descriptor,LOCK_UN);close(descriptor);descriptor = -1};if directory>=0{close(directory);directory = -1}}
    deinit{release()}
}

// Plain JSON storage for the current single-account release.
final class WorkBuddyVault {
    enum Failure: Error { case invalid, unavailable, corrupt }
    private static let lock = NSLock()
    private let ownership: WorkBuddyVaultOwnership
    private let file: URL

    init(ownership: WorkBuddyVaultOwnership) throws {
        try ownership.check()
        self.ownership = ownership
        file = ownership.root.appendingPathComponent("accounts.json")
    }

    private func validateKey(_ key: String) throws {
        guard key.utf8.count == 64,
              key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Failure.invalid
        }
    }

    private func readRecords() throws -> [String: [String: Any]] {
        try ownership.check()
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return [:] }
            throw Failure.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1,
              info.st_size <= 1_048_576 else { throw Failure.corrupt }
        let data = try Data(contentsOf: file)
        guard let records = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]],
              records.count <= 16 else { throw Failure.corrupt }
        for (key, value) in records {
            try validateKey(key)
            try validate(value)
        }
        return records
    }

    func savedKeys() throws -> [String] {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return try readRecords().keys.sorted()
    }

    func read(_ key: String) throws -> [String: Any]? {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try validateKey(key)
        return try readRecords()[key]
    }

    func compareExchange(_ key: String, expected: Int?, value: [String: Any]) throws -> Bool {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try validateKey(key)
        try validate(value)
        var records = try readRecords()
        let old = records[key]
        guard old.flatMap({ integer($0["revision"]) }) == expected else { return false }
        guard integer(value["revision"]) == (expected ?? 0) + 1 else { throw Failure.invalid }
        if let old = old {
            guard old["state"] as? String != "revoked" else { return false }
            if value["state"] as? String != "revoked" {
                guard old["state"] as? String == "active" && ["active", "rotationPending"].contains(value["state"] as? String ?? "")
                    || old["state"] as? String == "rotationPending" && value["state"] as? String == "active" else { throw Failure.invalid }
                for name in ["uid", "domain", "endpoint"] {
                    guard old[name] as? String == value[name] as? String else { throw Failure.invalid }
                }
            }
        } else {
            guard ["active", "revoked"].contains(value["state"] as? String ?? "") else { throw Failure.invalid }
        }
        records[key] = value
        guard records.count <= 16 else { throw Failure.invalid }
        let data = try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
        guard data.count <= 1_048_576 else { throw Failure.invalid }
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
        try ownership.synchronize()
        guard let after = try readRecords()[key], NSDictionary(dictionary: after).isEqual(to: value) else {
            throw Failure.unavailable
        }
        return true
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
              Set(row.keys).isSubset(of:Set(["schema","revision","state","domain","endpoint","uid","accessToken","refreshToken","expiresAt","refreshExpiresAt","registrationId","accessRejected","refusalRecoveryAttempted"])) else{throw Failure.invalid}
        for name in ["accessRejected", "refusalRecoveryAttempted"] {
            guard let raw = row[name] else { continue }
            guard let flag = raw as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { throw Failure.invalid }
        }
        if let registration = row["registrationId"] { guard let value = registration as? String, value.count == 32, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.invalid } }
        for name in ["domain","endpoint"] {guard let v=row[name] as? String,["www.workbuddy.cn","www.codebuddy.cn"].contains(v) else{throw Failure.invalid}}
        for name in ["uid","accessToken","refreshToken"] {
            if name=="refreshToken" && row[name]==nil{continue}
            guard let v=row[name] as? String,!v.isEmpty,v.utf8.count<=(name=="uid" ? 512:16384),v.utf8.allSatisfy({(33...126).contains($0)}) else{throw Failure.invalid}
        }
        for name in ["expiresAt", "refreshExpiresAt"] {
            guard let rawExpiry = row[name] else { continue }
            guard let expiry = rawExpiry as? NSNumber, CFGetTypeID(expiry) != CFBooleanGetTypeID(),
                  expiry.doubleValue > 0, expiry.doubleValue <= 8640000000000000,
                  expiry.doubleValue.rounded() == expiry.doubleValue else { throw Failure.invalid }
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
