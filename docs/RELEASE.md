# Release: signing and notarisation

The Stem Inspector app in this repository is **not signed with a Developer ID certificate and not notarised**. Both need a Developer ID certificate, which comes with an Apple Developer Program membership ([Developer ID](https://developer.apple.com/developer-id/)); this project does not use one. CI signs the app ad hoc (signing identity `-`, which Xcode calls "Sign to Run Locally"), so the sandbox entitlements and the hardened runtime flag are embedded and can be checked, but the result is not distributable to other Macs.

The steps below are the ones to run with a membership. The signing, checking, archiving, notarisation and stapling commands are taken from the Apple pages listed under each step; the build and archive invocations name this project's files. Placeholders in angle brackets are the account's own values.

## 1. Get a Developer ID Application certificate

Create a "Developer ID Application" certificate in the developer account (only the team's Account Holder can create it, [Developer ID](https://developer.apple.com/developer-id/)) and install it in the login keychain. Confirm it is visible to the signing tools:

```sh
security find-identity -p codesigning -v
```

Source: [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac).

## 2. Build and sign with the hardened runtime

For an app built with Xcode, Apple's page gives this route: archive with `xcodebuild archive`, then export a distribution-signed copy with `xcodebuild -exportArchive` and an export options property list. The page points to `xcodebuild -help` for the supported keys. The values below are the ones that help text lists on the CI runner's Xcode 26.6 (printed in the app job's Toolchain step of run 37400549002, and of every run since 37385637470): `method` `developer-id`, `signingStyle` `manual` (this project signs manually), `signingCertificate` with the automatic selector `Developer ID Application`, and `teamID`. Save this as `ExportOptions.plist`, with the team's ID in place of `YOUR_TEAM_ID`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>teamID</key>
	<string>YOUR_TEAM_ID</string>
</dict>
</plist>
```

Then archive and export:

```sh
xcodebuild archive -project App/StemInspector.xcodeproj -scheme StemInspector -archivePath build/StemInspector.xcarchive
xcodebuild -exportArchive -archivePath build/StemInspector.xcarchive -exportPath build/export -exportOptionsPlist ExportOptions.plist
APP=build/export/StemInspector.app
```

The page's other route, signing each code item with `codesign`, is the one it gives for products that are not apps built with Xcode (non-app products, or products from other build systems); for this app the export above is the documented route. If the manual route is used anyway, build the Release configuration first and sign the app bundle, which contains no nested code, with the Developer ID identity, a secure timestamp, the hardened runtime (`-o runtime`) and the entitlements file:

```sh
xcodebuild build -project App/StemInspector.xcodeproj -scheme StemInspector -configuration Release \
  -destination 'platform=macOS' -derivedDataPath DerivedData
APP=DerivedData/Build/Products/Release/StemInspector.app
codesign -s "Developer ID Application" -f --timestamp -o runtime \
  --entitlements App/StemInspector/StemInspector.entitlements "$APP"
```

Check the signature and the embedded entitlements (the same two commands CI runs on the ad hoc build):

```sh
codesign -d -vv "$APP"
codesign -d --entitlements - --xml "$APP" | plutil -convert xml1 -o - -
```

Sources: [Creating distribution-signed code for macOS](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac), [Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime).

The Release configuration sets `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`, so the build does not carry `com.apple.security.get-task-allow`, which notarisation rejects. Source: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Build settings reference](https://developer.apple.com/documentation/xcode/build-settings-reference).

## 3. Archive for upload

The notary service accepts a ZIP archive made with `ditto`:

```sh
/usr/bin/ditto -c -k --keepParent "$APP" StemInspector.zip
```

Source: [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## 4. Store credentials and submit

Store an app-specific password once in the keychain, then submit and wait for the result:

```sh
xcrun notarytool store-credentials "notarytool-password" --apple-id "<AppleID>" --team-id <DeveloperTeamID> --password <secret_2FA_password>
xcrun notarytool submit StemInspector.zip --keychain-profile "notarytool-password" --wait
```

If the submission is rejected, download the log for its submission id:

```sh
xcrun notarytool log <submission-id> --keychain-profile "notarytool-password" developer_log.json
```

Sources: [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## 5. Staple the ticket

A ZIP archive cannot be stapled. Staple the app itself, then make the distribution ZIP again from the stapled app:

```sh
xcrun stapler staple "$APP"
/usr/bin/ditto -c -k --keepParent "$APP" StemInspector.zip
```

Source: [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## What CI proves today

The `app` job in `.github/workflows/ci.yml` builds the Release configuration with the ad hoc identity and then fails unless:

- the embedded entitlements and the committed entitlements file are each exactly `com.apple.security.app-sandbox` and `com.apple.security.files.user-selected.read-write`, both true, and nothing else (so no network entitlement and no `get-task-allow`);
- `codesign -d -vv` reports the `runtime` flag (hardened runtime).

The signature check output and the entitlements are uploaded as the `app-logs` artifact of every run.
