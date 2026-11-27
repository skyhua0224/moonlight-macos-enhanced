"""Stream-end ownership of the AWDL session: the engine's cases run in tests/awdl-helper-policy, the wiring is checked here."""
from pathlib import Path
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
print('PASS: AWDL session ownership is wired from the stream controller to the engine')
