# Android release builds and the Play Store

**Status: DRAFT, Oct 25 2026.** Every decision taken (section 7); waiting for Simon's agreement with all six, and his
go. Nothing here is implemented until then. Before this plan: `-Dplatform=android` builds a debug APK of an app's
single-file page in a WebView (`tools/android_apk.zig`, `src/android/WebViewActivity.java`), with an adaptive icon;
Simon verified the device checks (keyboard, sound, links, rotation) on his Galaxy S23 FE, Oct 25.

This plan covers two items of the Android list: **4, release builds** (what `-Dmode=ship` makes for Android) and **5,
the Play Store** (what Play needs). The Android apps sell nothing inside: go puzzles hero's paywall is not part of its
Android build (D2).

## 1. Where we are

- Every Android build is debug-signed with `~/.android/debug.keystore` (Android Studio's key), marked debuggable
  (`aapt2 link --debug-mode`, which also turns on `chrome://inspect`), `versionCode` 1, `versionName` "1.0",
  `minSdk` 31, `targetSdk` 36.
- Output: one APK, `zig-out/android/<name>.apk`. `run-<app>` installs it with `adb install -r`.
- `-Dmode` (debug | release | ship) changes only the wasm, not the APK.

## 2. Facts that shape the design (checked Oct 25 2026)

- **Play takes app bundles (`.aab`) for new apps**, not APKs - the rule since August 2021. Play builds and signs the
  per-device APKs itself.
- **Play App Signing**: Google holds the key that signs what users install; the developer signs each upload with an
  *upload key*. A lost upload key can be reset through Play support; a lost app signing key cannot - which is why the
  default is that Google generates and keeps it.
- **AABs are signed with `jarsigner`** (JAR signing), not `apksigner`. `jarsigner` ships with the JDK (Android Studio's
  JBR has it).
- **`bundletool`** turns a module zip into an `.aab`, and an `.aab` into installable APKs for a test device. Latest:
  1.18.3 (Dec 15 2025), one 32.5 MB jar from GitHub (`bundletool-all`) - not part of the SDK, nor of Android Studio.
  Gradle's cache has the slim Maven jar of the same version, which runs only with its dependencies' jars beside it.
  `zig fetch` cannot carry it: it unpacks a jar as a zip, and this one holds two names differing only in case, which
  fails on Windows (`zip extract failed: PathAlreadyExists`, tried Oct 25).
- **Target API**: from Aug 31 2026 new apps and updates must target Android 16 (API 36); an extension to Nov 1 2026 can
  be requested. We target 36 already.
- **New personal developer accounts** (created after Nov 13 2023) must run a closed test with at least 12 testers opted
  in for 14 continuous days before production access. Organization accounts are exempt (they need a D-U-N-S number).
  That gates production only: the **internal testing** track - up to 100 testers added by email, no review, no waiting
  period - is open from the start, and does not count toward the 14 days.
- **Payments**: Play's billing rules govern what an app sells inside itself. The Android apps sell nothing (D2), so they
  do not apply; whether a store listing is free or paid up front is a Play Console setting, not build work.
- **Sideloading**: Google's developer verification is enforced from Sep 30 2026 in Brazil, Indonesia, Singapore and
  Thailand, and globally from 2027: an APK installed outside Play must then come from a registered developer, its package
  name and signing key registered. A free "limited distribution" account covers up to 20 devices.

## 3. What `-Dmode=ship -Dplatform=android` makes (proposal)

`debug` and `release` stay debug builds - debug key, debuggable, for development and testing - but install as their
own app (D6): the app ID with `.debug` appended, the label with " (debug)", so they sit on the phone beside the copy
from Play. `ship` is the build that leaves the machine:

- **Not debuggable**: no `--debug-mode`. The activity already turns WebView debugging on only for a debuggable app, so
  `chrome://inspect` goes dark by itself.
- **Signed with the upload key** (section 5), never the debug key; the build fails with the `keytool` command to make
  one when the key is not configured.
- **Version** from the app's row (D3).
- **Output**: `zig-out/android/<name>.aab`, signed with the upload key - the file uploaded to Play (D1). No release APK:
  nothing is downloaded outside Play, and Play signs what phones install (D4).
- **`run-<app>` in ship mode** checks that very bundle on the phone (S3): `bundletool build-apks --connected-device`,
  signed with the debug key, then `install-apks` - under Play's ID, so not over a copy installed from Play.

## 4. The app bundle (proposal)

Same inputs as the APK, a different packaging:

1. `aapt2 link --proto-format` - the manifest and resources in protobuf form, which bundles need, instead of binary XML.
2. Lay the result out as a bundle module: `manifest/AndroidManifest.xml`, `dex/classes.dex`, `res/...`,
   `resources.pb`, `assets/index.html` - then zip it as `base.zip`.
3. `bundletool build-bundle --modules=base.zip --output=<name>.aab`.
4. `jarsigner` with the upload key.
5. Checked before any upload: `bundletool build-apks --connected-device` then `install-apks` puts on the phone exactly
   what Play would.

`bundletool` is downloaded once by the tool and pinned by its SHA-256 (D5).

## 5. Keys

- **Upload key**: one keystore made once with `keytool` (RSA 4096, valid 30 years), kept outside the repo and backed up.
  It signs every `.aab` sent to Play, and nothing else. The build reads its path and passwords from the environment,
  never from a file in the tree: `ZIMR_ANDROID_KEYSTORE`, `ZIMR_ANDROID_KEYSTORE_PASSWORD`, `ZIMR_ANDROID_KEY_ALIAS`. A
  lost upload key is replaced through Play support.
- **Play's app signing key: Google's (D4).** Google makes and keeps the key that signs what phones install, so no key of
  ours signs an installed release, and none can be lost for good.
- The debug key stays for `debug` and `release`.

## 6. The Play process (not build work, Simon's side)

**To test (now):** create the app in Play Console under its package name - `com.bofstudios.gopuzzleshero`, his for good
once used; choose Play's app signing key at the first upload (D4); upload the `.aab` to internal testing; add testers'
emails (Simon's own included); install from the Play link on the phone.

**To publish (later):** store listing (512x512 icon, 1024x500 feature graphic, screenshots, description); privacy policy
URL; data safety form; content rating questionnaire; target audience; then the closed test (12 testers, 14 days) for a
personal account created after Nov 13 2023; then production.

## 7. Decisions

- **D1 - Distribution: DECIDED (Simon, Oct 25) - Play, on the internal testing track first.** Simon has a Play account
  and wants to try the whole path; production, and with it the closed test, is a later decision. Direct downloads are
  not planned.
- **D2 - The hero's paywall on Android: DECIDED (Simon, Oct 25) - none.** Its code is commented out of the Android build;
  it may live on Simon's own web page later, outside this plan. Nothing in the Android builds sells anything.
- **D3 - Version numbers: DECIDED (Simon, Oct 25) - fields in the app's row**, `.android_version = .{ .code = 2,
  .name = "1.1" }`, bumped by hand before an upload; an app without one is code 1, "1.0". The same sources always build
  the same bundle.
- **D4 - Play's app signing key: DECIDED (Simon, Oct 25) - Google's.** We hold only the upload key (section 5).
- **D5 - bundletool: DECIDED (Simon, Oct 25) - the tool downloads it, pinned.** The first ship build fetches
  `bundletool-all-1.18.3.jar` from GitHub, refuses it unless its SHA-256 is the one written in the tool (recorded when
  S2 is built), and keeps it in `~/.android/zimr/` - beside the debug keystore, so clearing zig's cache does not mean
  another download. `BUNDLETOOL_JAR` names a jar to use instead, for a machine without internet.
- **D6 - The debug builds' app ID: DECIDED (Simon, Oct 25) - `.debug` appended**, as Gradle does, and " (debug)" on
  the label: a debug build and Play's copy live side by side, each with its own progress. The copy on Simon's phone now
  (Play's ID, the debug key) is uninstalled once before the first install from Play.

## 8. Steps, once decided

- **S1** `-Dmode=ship` for Android: not debuggable, the upload key from the environment, the version from the row
  (D3); `debug` and `release` under the `.debug` ID and label (D6).
- **S2** The app bundle (section 4), `bundletool` downloaded and pinned by the tool (D5).
- **S3** `run-<app>` in ship mode checks the bundle on the phone through `bundletool build-apks` / `install-apks`. It
  installs under Play's ID with the debug key, so it cannot go over a copy installed from Play; the tool says so and
  names the uninstall. Once uploads begin, Play's internal track is the real check.
- **S4** Docs: `readme.html`, `template/build.zig`, this plan's journal.

## 9. Journal

- Oct 25: plan drafted; facts checked (section 2).
- Oct 25: D2 decided by Simon - no paywall on Android; Play's billing rules drop out of the plan.
- Oct 25: D1 decided by Simon - Play, internal testing first (he has an account); no closed test needed for that.
- Oct 25: D4 decided by Simon - Google's app signing key; we keep only an upload key.
- Oct 25: D3 decided by Simon - version code and name as fields in the app's row.
- Oct 25: D5 decided by Simon - the tool downloads bundletool, pinned by SHA-256, cached in `~/.android/zimr/`.
- Oct 25: D6 decided by Simon - debug builds under `<id>.debug`, labelled " (debug)". Every decision taken; the plan
  waits for Simon's agreement with all six, and his go.
