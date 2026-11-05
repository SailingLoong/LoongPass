import Cocoa
import FlutterMacOS

struct Failed: Error {}
var passed=0, failed=0
func require(_ value: Bool) throws { if !value { throw Failed() } }
func test(_ name:String,_ body:() throws -> Void) {do {try body();passed+=1;print("PASS \(name)")} catch {failed+=1;print("FAIL \(name)")} }
func denied(_ action:() throws -> Void) throws {do {try action()}catch{return};throw Failed()}
let root=URL(fileURLWithPath:CommandLine.arguments[1]).resolvingSymlinksInPath()
let app=root.appendingPathComponent("Fixture.app")
let contents=app.appendingPathComponent("Contents")
let executable=contents.appendingPathComponent("MacOS/ZCode")
let info=contents.appendingPathComponent("Info.plist")
let fm=FileManager.default
try fm.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
try Data("synthetic executable only".utf8).write(to:executable);try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable.path)
func writeInfo(_ overrides:[String:Any]=[:]) throws {var p:[String:Any]=["CFBundleIdentifier":"dev.zcode.app","CFBundleShortVersionString":"3.17.2","CFBundleExecutable":"ZCode"];p.merge(overrides){_,v in v};try PropertyListSerialization.data(fromPropertyList:p,format:.xml,options:0).write(to:info)}
try writeInfo()
let collector=ZcodeAppIdentityCollector()
test("valid synthetic bundle yields selected executable physical identity") {let a=try collector.collect(at:app);try require(a.app.bundleId=="dev.zcode.app" && a.version=="3.17.2" && a.app.executablePath==executable.path && a.app.inode>0)}
test("wrong bundle identity rejected") {try writeInfo(["CFBundleIdentifier":"other.app"]);defer{try? writeInfo()};try denied{_ = try collector.collect(at:app)}}
test("unreviewed version rejected") {try writeInfo(["CFBundleShortVersionString":"3.18.0"]);defer{try? writeInfo()};try denied{_ = try collector.collect(at:app)}}
test("executable traversal rejected") {try writeInfo(["CFBundleExecutable":"../outside"]);defer{try? writeInfo()};try denied{_ = try collector.collect(at:app)}}
test("symlink bundle rejected") {let alias=root.appendingPathComponent("Alias.app");try fm.createSymbolicLink(at:alias,withDestinationURL:app);try denied{_ = try collector.collect(at:alias)}}
test("symlink executable rejected without following it") {let moved=executable.appendingPathExtension("original");try fm.moveItem(at:executable,to:moved);try fm.createSymbolicLink(at:executable,withDestinationURL:moved);defer{try? fm.removeItem(at:executable);try? fm.moveItem(at:moved,to:executable)};try denied{_ = try collector.collect(at:app)}}
test("oversize plist refused") {try Data(repeating:65,count:1048577).write(to:info);defer{try? writeInfo()};try denied{_ = try collector.collect(at:app)}}
test("hardlinked plist rejected as an alias") {let saved=contents.appendingPathComponent("Info-original.plist");try fm.moveItem(at:info,to:saved);try fm.linkItem(at:saved,to:info);defer{try? fm.removeItem(at:info);try? fm.moveItem(at:saved,to:info)};try denied{_ = try collector.collect(at:app)}}
test("FIFO plist refused without blocking") {let saved=contents.appendingPathComponent("Info-saved.plist");try fm.moveItem(at:info,to:saved);guard mkfifo(info.path,0o600)==0 else {throw Failed()};defer{try? fm.removeItem(at:info);try? fm.moveItem(at:saved,to:info)};let start=Date();try denied{_ = try collector.collect(at:app)};try require(Date().timeIntervalSince(start)<1)}
test("FIFO executable refused without blocking") {let saved=executable.appendingPathExtension("saved");try fm.moveItem(at:executable,to:saved);guard mkfifo(executable.path,0o700)==0 else {throw Failed()};defer{try? fm.removeItem(at:executable);try? fm.moveItem(at:saved,to:executable)};let start=Date();try denied{_ = try collector.collect(at:app)};try require(Date().timeIntervalSince(start)<1)}
let encoder=JSONEncoder();let decoder=JSONDecoder()
test("three fact states retain exact Rust wire shape") {for (fact,want) in [(ZcodeObservedFact.unknown,"unknown"),(.unset,"unset"),(.value("synthetic"),"value")] {let data=try encoder.encode(fact);let d=try JSONSerialization.jsonObject(with:data) as! [String:Any];try require(d["state"] as? String==want);try require(try decoder.decode(ZcodeObservedFact.self,from:data)==fact)}}
test("unknown fact with attached value rejected") {try denied{_ = try decoder.decode(ZcodeObservedFact.self,from:Data(#"{"state":"unknown","value":"CANARY"}"#.utf8))}}
test("unsupported fact state rejected") {try denied{_ = try decoder.decode(ZcodeObservedFact.self,from:Data(#"{"state":"guessed"}"#.utf8))}}
test("fact debug description redacts values") {try require(!String(describing:ZcodeObservedFact.value("SYNTHETIC-CANARY")).contains("SYNTHETIC-CANARY"))}
let provider=ZcodeFactsProvider()
test("default inspection never invents runtime facts") {let report=provider.inspect(appURL:app);try require(report.app != nil && report.unknownFields.contains("effectiveHome") && report.unknownFields.contains("runtimeFacts.processArch") && report.unknownFields.contains("credentialSecret"));try require(report.diagnostics.contains(.credentialContextUnproven) && report.diagnostics.contains(.writerCoverageUnproven) && report.diagnostics.contains(.launchContractUnproven))}
test("absent bundle produces diagnosis rather than discovery") {let report=provider.inspect(appURL:root.appendingPathComponent("Missing.app"));try require(report.app==nil && report.diagnostics.contains(.appIdentityUnproven))}
var evidence=ZcodeFactsEvidence();evidence.source = .synthetic;evidence.revision=7;evidence.runtimeDataDir = .value("/synthetic/runtime");evidence.effectiveHome = .value("/synthetic/home");evidence.platform = .value("darwin");evidence.username = .value("synthetic-user");evidence.runtimeFacts.processArch = .value("arm64")
test("unobserved bootstrap or ready phase cannot assert runtime directory") {let report=provider.inspect(appURL:app,evidence:evidence);try require(report.unknownFields.contains("runtimeDataDir") && report.diagnostics.contains(.dataDirectoryPhasesUnproven))}
evidence.bootstrapObserved=true;evidence.readyObserved=true
let report=provider.inspect(appURL:app,evidence:evidence)
test("explicit nonsecret evidence preserves state source revision") {let d=try JSONSerialization.jsonObject(with:report.rustFactsData()) as! [String:Any];try require((d["runtimeDataDir"] as? [String:Any])?["value"] as? String=="/synthetic/runtime");try require(report.source == .synthetic && report.revision==7)}
test("missing secret remains unknown even with other explicit facts") {let d=try JSONSerialization.jsonObject(with:report.rustFactsData()) as! [String:Any];try require((d["credentialSecret"] as? [String:Any])?["state"] as? String=="unknown" && report.rustMetadataAvailable==false)}
test("unavailable provenance discards supplied values") {var untrusted=evidence;untrusted.source = .unavailable;let r=provider.inspect(appURL:app,evidence:untrusted);try require(r.unknownFields.contains("platform") && r.unknownFields.contains("runtimeDataDir"))}
test("diagnostic output contains no evidence values") {var e=evidence;e.effectiveHome = .value("/SYNTHETIC-CANARY");let r=provider.inspect(appURL:app,evidence:e);try require(!String(describing:r).contains("SYNTHETIC-CANARY"))}
test("incomplete writer snapshot never authorizes stopped proof") {let owner=try report.makeBlockedOwner(uid:501);try denied{try owner.checkStopped()}}
test("blocked owner refuses stop and reopen without lifecycle effects") {let owner=try report.makeBlockedOwner(uid:501);var stopFailed=false,reopenFailed=false;owner.requestStop{if case .failure = $0 {stopFailed=true}};owner.reopen{if case .failure = $0 {reopenFailed=true}};try require(stopFailed && reopenFailed)}
print("\(passed) passed; \(failed) failed; synthetic inputs only")
exit(failed==0 ? 0:1)
