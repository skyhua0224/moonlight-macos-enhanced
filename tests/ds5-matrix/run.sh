#!/bin/sh
# Builds and runs the client-side matrix of the DualSense tuning keys 10, 100, 101 and 105 with a plain C compiler.
# The rule of key 105 is compiled from the product source: ControllerIsFeedbackTarget is cut out of
# Limelight/Input/ControllerSupport.m and only "support." is rewritten to "support->".  The wiring of the
# four keys into the product (who calls the policy functions) is checked with grep.
set -e
dir=$(cd "$(dirname "$0")" && pwd)
root=$dir/../..
work=${TMPDIR:-/tmp}/ds5-matrix-client.$$
mkdir -p "$work"
trap 'rm -rf "$work"' EXIT
sed -n '/^static BOOL ControllerIsFeedbackTarget/,/^}/p' "$root/Limelight/Input/ControllerSupport.m" | sed 's/support\./support->/g' > "$work/feedback_target.inc"
[ -s "$work/feedback_target.inc" ] || { echo "ControllerIsFeedbackTarget not found in ControllerSupport.m" >&2; exit 1; }
${CC:-cc} -std=c11 -Wall -Wextra -Werror -O1 -I"$work" -o "$work/test" "$dir/test_ds5_client_keys.c"
"$work/test"
wire() {
  if grep -qF "$2" "$root/$1"; then printf 'WIRING\t%s\tPASS\t%s contains %s\n' "$3" "$1" "$2"; else printf 'WIRING\t%s\tFAIL\t%s does not contain %s\n' "$3" "$1" "$2"; fi
}
wire Limelight/Stream/Connection.m 'ds5_resolve_bluetooth_mode((int)config.ds5BtHapticsFallback, (int)config.ds5BtOutput' "10,100 offer IR"
wire Limelight/Input/ControllerSupport.m 'ds5_resolve_bluetooth_mode((int)_ds5BtHapticsFallback, (int)_ds5BtOutput' "10,100 feedback path"
wire Limelight/Input/ControllerSupport.m 'ds5_capped_report_rate(hostRequestedHz, (int)self.reportRateCapHz)' "101 report rate"
wire Limelight/Input/ControllerSupport.m '_reportRateCapHz = streamConfig.reportRateCapHz' "101 from the stream configuration"
wire Limelight/Input/ControllerSupport.m '_controllerFeedbackTarget = streamConfig.controllerFeedbackTarget' "105 from the stream configuration"
wire Limelight/macOS/ViewControllers/StreamViewController.m 'streamConfig.ds5BtOutput = dualSense[@"btOutput"]' "100 from the settings"
wire Limelight/macOS/ViewControllers/StreamViewController.m 'streamConfig.ds5BtHapticsFallback = dualSense[@"btHapticsFallback"]' "10 from the settings"
wire Limelight/macOS/ViewControllers/StreamViewController.m 'streamConfig.reportRateCapHz = (NSInteger)llround(dualSense[@"reportRateCapHz"]' "101 from the settings"
wire Limelight/macOS/ViewControllers/StreamViewController.m 'streamConfig.controllerFeedbackTarget = [SettingsClass controllerFeedbackTargetFor' "105 from the settings"
