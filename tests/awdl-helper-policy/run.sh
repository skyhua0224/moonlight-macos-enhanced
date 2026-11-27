#!/bin/sh
# Builds and runs the AWDL helper rules test with swiftc. Production code:
# Limelight/macOS/Helpers/AwdlHelperPolicy.swift (Foundation only): the default of the setting, when the authorization
# is asked for, the self-check after an install, the stream session and its restore paths.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$dir/../.." && pwd)
policy="$root/Limelight/macOS/Helpers/AwdlHelperPolicy.swift"

# The app and the helper must agree on the interface version: one number in Swift, one in the C header.
swift_version=$(sed -n 's/.*static let interfaceVersion = \([0-9][0-9]*\).*/\1/p' "$policy")
header_version=$(sed -n 's/^#define MLAwdlPrivilegedHelperInterfaceVersion \([0-9][0-9]*\).*/\1/p' "$root/Limelight/macOS/Helpers/AwdlPrivilegedHelperProtocol.h")
if [ -z "$swift_version" ] || [ "$swift_version" != "$header_version" ]; then
  echo "interface version differs: Swift '$swift_version', header '$header_version'"
  exit 1
fi

out=${TMPDIR:-/tmp}/awdl-helper-policy-test.$$
swiftc -O -o "$out" "$policy" "$dir/main.swift"
status=0
"$out" || status=$?
rm -rf "$out"
exit $status
