# Release versions and update channels

Two kinds of build, one rule each.

| | Stable | Test build |
| --- | --- | --- |
| Version | `1.3.9`, `2.0.0` (semantic) | commit time in UTC, `2026.1124.103317` |
| Tag | `v1.3.9` | `v2026.1124.103317` (also `v1.3.9-rc.N` for old-style candidates) |
| GitHub release | Latest | pre-release, never Latest |
| `UpdateChannel` | `stable` | `beta` |
| Notes | `.github/release-notes/<tag>.md` | `.github/release-notes/beta.md` (shared: the tag is the commit's time, so it cannot name a file inside that commit) |

## Test-build version

`scripts/release_info.py` takes the committer time of the tagged commit, converts it to UTC and returns
`year.{month, no padding}{day, two digits}.{hour minute second as one number}`. This is the rule Foundation Sunshine
uses (`scripts/ci/release-info.py` there). The tag is never typed by hand: `python3 scripts/release_info.py` prints
`release_tag`, and CI runs `--check-tag` and rejects a tag that is not the one the tagged commit gives.

`CFBundleShortVersionString` / `MARKETING_VERSION` is the timestamp. Apple requires three period-separated integers
for that key, which the timestamp is. `CFBundleVersion` stays `1335 + run number`.

## Which release is an update

A timestamp is larger than any stable number (`2026 > 2`), so version strings cannot be compared across the two
kinds. Sparkle compares `CFBundleVersion` with `sparkle:version` and filters items by channel; an updater cannot leave
the default channel, so a beta install also sees stable items
([Sparkle: publishing](https://sparkle-project.org/documentation/publishing/)).

The release-page check in Settings follows the same rule (`UpdateVersionPolicy`):

- A stable install never offers a pre-release or a timestamp tag.
- A beta install reads the `appcast.xml` of its newest eligible releases and compares build numbers. Without a
  build number on either side it falls back to comparing the versions.

## Feeds

"Latest" is always a stable release, so a beta install reads the `chore/update-feed` branch feed first. That
`appcast.xml` must list the newest test build (channel `beta`) and the current stable release, with build numbers
above every earlier one. Stable installs keep reading the Latest release.

## Publishing a test build

1. `python3 scripts/release_info.py` on the commit to publish; tag it with the printed `release_tag` and push the tag.
2. CI builds and makes a draft pre-release with the DMGs. Update `.github/release-notes/beta.md` before tagging.
3. Sign the universal DMG into `appcast.xml` with the Sparkle EdDSA key and `SPARKLE_CHANNEL=beta`
   (`scripts/generate_sparkle_appcast.sh`). The generator writes only the items it can build from
   `SPARKLE_ARCHIVES_DIR`, so for the feed branch put the new test build's DMG and the current stable release's
   universal DMG (with its notes) in that directory, and check that the result lists both. Upload that file to the
   feed branch. The release gets its own `appcast.xml` made from the new DMG alone; the release-page check reads
   its build number.
4. Publish with `gh release edit <tag> --draft=false --prerelease --latest=false`.
