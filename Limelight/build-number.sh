cd "$SRCROOT"
git=`sh /etc/profile; which git`
bundleVersion=`"$git" rev-list --count HEAD`
echo "BUILD_NUMBER = $bundleVersion" > "${PROJECT_DIR}/Limelight/Version.xcconfig"
