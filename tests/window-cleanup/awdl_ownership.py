"""Run production AWDL session methods with isolated interface operations."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'Limelight/macOS/Helpers/MicrophoneManager.swift').read_text()


def method(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


methods = '\n'.join(method(signature) for signature in (
    '    func beginStreamSessionIfEnabled(', '    func endStreamSession(',
    '    private func resetSessionStateLocked()', '    private func restoreIfNeededLocked('))
program = '''import Foundation
enum Status { case ready,failed,unavailable }
class Helper {
 let sessionQueue=DispatchQueue(label:"test.awdl")
 var sessionGeneration:UInt=0
 var sessionOwnerID:String? = nil
 var sessionEnabled=false
 var interfacePresent=false
 var originalInterfaceUp=false
 var changedInterfaceState=false
 var pendingRestoreRequired=false
 var interfaceUp=true
 var commands:[String]=[]
 func logInfo(_ s:String) {}
 func logWarning(_ s:String) {}
 func updateAuthorizationState(_ s:Status,message:String) {}
 func queryAwdlInterfaceState()->(present:Bool,up:Bool) { (true,interfaceUp) }
 func runPrivilegedIfconfigArgument(_ arg:String)->String? {
  commands.append(arg); interfaceUp=(arg=="up"); return nil
 }
''' + methods + '''
}
let h=Helper()
h.beginStreamSessionIfEnabled(true,generation:1,ownerID:"old")
h.endStreamSession(forOwner:"old",withReason:"begin-stop:old")
// Per-controller generation numbers can be equal. Ownership must be independent.
h.beginStreamSessionIfEnabled(true,generation:1,ownerID:"current")
h.sessionQueue.sync { precondition(h.sessionEnabled && !h.interfaceUp) }
h.endStreamSession(forOwner:"old",withReason:"stream-view-controller-dealloc")
h.sessionQueue.sync {
 precondition(h.sessionEnabled && h.sessionGeneration==1 && !h.interfaceUp)
}
// Stale termination and missing owners are equally harmless.
h.endStreamSession(forOwner:"old",withReason:"connection-terminated")
h.endStreamSession(forOwner:nil,withReason:"never-started")
h.sessionQueue.sync { precondition(h.sessionEnabled && h.sessionOwnerID=="current" && !h.interfaceUp) }
h.endStreamSession(forOwner:"current",withReason:"begin-stop:current")
h.sessionQueue.sync { precondition(!h.sessionEnabled && h.sessionOwnerID==nil && h.interfaceUp) }
let commandCount=h.sessionQueue.sync { h.commands.count }
h.endStreamSession(forOwner:"current",withReason:"repeated-cleanup")
h.sessionQueue.sync { precondition(h.commands.count==commandCount) }
h.beginStreamSessionIfEnabled(false,generation:2,ownerID:"disabled")
h.endStreamSession(forOwner:"disabled",withReason:"disabled-close")
h.sessionQueue.sync { precondition(!h.sessionEnabled && h.commands.count==commandCount) }
print("PASS: stale AWDL cleanup preserves a replacement with the same generation")
print("PASS: current, repeated, missing-owner and disabled-session AWDL cleanup")
'''
with tempfile.TemporaryDirectory(prefix='moonlight-awdl-owner-') as tmp:
    path = Path(tmp) / 'test.swift'
    path.write_text(program)
    subprocess.run(['swift', '-module-cache-path', '/tmp/moonlight-awdl-test-cache', str(path)], check=True)

controller = (root / 'Limelight/macOS/ViewControllers/StreamViewController.m').read_text()
assert 'self.awdlSessionOwnerID = NSUUID.UUID.UUIDString;' in controller
assert 'endStreamSessionWithReason:' not in controller
assert controller.count('endStreamSessionForOwner:self.awdlSessionOwnerID withReason:') == 5
assert 'ownerID:self.awdlSessionOwnerID' in controller
print('PASS: stop, dealloc, termination and launch-failure paths supply the session owner')
