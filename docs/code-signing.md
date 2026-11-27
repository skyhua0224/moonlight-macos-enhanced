# Code signing

Release builds are signed with one fixed, self-signed code-signing certificate
(`Moonlight Enhanced Code Signing`, SHA-1
`39:61:36:AB:87:15:2D:3A:07:6F:09:C7:5F:28:5C:69:F2:7A:1B:50`).
It costs nothing and is not an Apple Developer ID: builds are still not
notarized, so Gatekeeper treats them exactly like the previous ad-hoc builds.

## Why a fixed certificate

An ad-hoc signature has no certificate, so its designated requirement is the
build's code-directory hash (Apple TN3127, "Inside Code Signing: Requirements").
Every build then looks like a different app to TCC, and the Input Monitoring
grant is lost on each update. With a fixed certificate the requirement is

    identifier "std.skyhua.MoonlightMacEnhanced" and certificate leaf = H"<certificate SHA-1>"

which is the same for every build signed with it.

## How CI signs

`scripts/ci_signing_keychain.sh setup` imports the certificate from the
repository secrets `SIGNING_P12_BASE64` and `SIGNING_P12_PASSWORD` into a
throw-away keychain and checks its SHA-1 against `SIGNING_CERT_SHA1` in
`.github/workflows/build.yml`; a different certificate fails the build.
`scripts/sign_app_bundle.py` then signs all nested code from the inside out.
`cleanup` deletes the keychain afterwards. Builds that cannot read the secrets
(pull requests from forks) sign ad-hoc and still succeed.

Hardened Runtime is not enabled, as before. The signing step stays the same for
the application, the File Provider extension, Sparkle and the AWDL helper.

## Updates

Sparkle authenticates update archives with the EdDSA key in `SUPublicEDKey`,
which is independent of the code-signing certificate. Builds signed with the
fixed certificate keep using the same key and appcast.

## AWDL privileged helper

Installing the helper with `SMJobBless` needs a TeamIdentifier, which neither
an ad-hoc nor a self-signed signature has, and the call is deprecated since
macOS 13. The helper is therefore installed as a launchd daemon with one
administrator dialog (see `awdl-helper.md`). The `SMAuthorizedClients`
requirement (`anchor apple generic`) is only written when Xcode itself signs the
build with an Apple identity; CI builds with Xcode signing off, so it is not
written for CI builds either. The helper then accepts the client whose
executable sits in an app bundle with the app's bundle identifier.

## Rotating the certificate

Replacing the certificate changes the requirement and every user has to grant
Input Monitoring again. Keep the original PKCS#12 file safe; update the two
secrets and `SIGNING_CERT_SHA1` together only when a move to a Developer ID
certificate is planned.
