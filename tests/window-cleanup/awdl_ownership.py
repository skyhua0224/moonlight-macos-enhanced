"""Stream-end ownership of the AWDL session: the engine's cases run in tests/awdl-helper-policy, the wiring is checked here."""
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parents[2]

# Old and new owners with equal generation numbers, termination/deinit, repeated and missing-owner cleanup and disabled
# sessions are cases of the session engine (AwdlHelperPolicy.swift), run there against a fake awdl0.
subprocess.run(['sh', str(root / 'tests/awdl-helper-policy/run.sh')], check=True)

manager = (root / 'Limelight/macOS/Helpers/AwdlHelperManager.swift').read_text()
assert 'self.engine.end(forOwner: ownerID' in manager
assert 'func endStreamSession(forOwner ownerID: String?' in manager

controller = (root / 'Limelight/macOS/ViewControllers/StreamViewController.m').read_text()
assert 'self.awdlSessionOwnerID = NSUUID.UUID.UUIDString;' in controller
assert 'endStreamSessionWithReason:' not in controller
# The session starts with the controller's owner id, and every way a stream ends passes the same id.
assert re.search(r'beginStreamSessionIfEnabled:.*?ownerID:self\.awdlSessionOwnerID\]', controller, re.S)
ends = re.findall(r'endStreamSessionForOwner:self\.awdlSessionOwnerID\s+withReason:', controller)
assert len(ends) >= 5, f'expected the begin-stop, dealloc, termination, stage-failure and launch-failure ends, found {len(ends)}'
print('PASS: AWDL session ownership is wired from the stream controller to the engine')
