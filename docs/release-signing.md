# Release Signing

SystemAudioToMP3 uses **Developer ID Application** signing for Release builds, enabling direct-download distribution outside the Mac App Store (spec Section 2). This is a prerequisite for notarization (REQ-042).

---

## Prerequisites

### 1. Developer ID Application certificate

You need a **Developer ID Application** certificate issued to your Apple Developer account installed in the system Keychain.

To install:

1. Open **Xcode → Settings → Accounts** and sign in with your Apple ID that has a Developer Program membership.
2. Select your team and click **Manage Certificates**.
3. Click `+` and choose **Developer ID Application**.
4. Xcode downloads and installs the certificate automatically.

Alternatively, download the `.cer` from [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates) and double-click to install.

Verify the cert is present:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

Expected output (team ID will differ):

```
1) AABBCCDDEE11223344556677889900AABBCCDDEE "Developer ID Application: Tom Kaczocha (XXXXXXXXXX)"
```

### 2. `DEVELOPMENT_TEAM` environment variable

The Release build setting `DEVELOPMENT_TEAM` is intentionally left as `${DEVELOPMENT_TEAM}` in `project.yml` so the team ID is never hard-coded in version control. You must supply it at build time.

Find your 10-character team ID at [developer.apple.com/account](https://developer.apple.com/account) under **Membership**.

---

## Building a Signed Release Archive

```bash
DEVELOPMENT_TEAM=XXXXXXXXXX xcodebuild \
  -project SystemAudioToMP3.xcodeproj \
  -scheme SystemAudioToMP3 \
  -configuration Release \
  -archivePath build/SystemAudioToMP3.xcarchive \
  archive
```

Replace `XXXXXXXXXX` with your actual 10-character team ID.

After archiving, export the `.app`:

```bash
xcodebuild \
  -exportArchive \
  -archivePath build/SystemAudioToMP3.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist ExportOptions.plist
```

A minimal `ExportOptions.plist` for Developer ID distribution:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>developer-id</string>
  <key>teamID</key>
  <string>XXXXXXXXXX</string>
</dict>
</plist>
```

---

## Verifying the Signature

After the archive/export step, verify the `.app` is correctly signed:

```bash
codesign --verify --deep --strict --verbose=2 build/export/SystemAudioToMP3.app
```

Expected output — exit 0:

```
build/export/SystemAudioToMP3.app: valid on disk
build/export/SystemAudioToMP3.app: satisfies its Designated Requirement
```

Inspect signature details:

```bash
codesign -dvv build/export/SystemAudioToMP3.app
```

Look for:
- `Authority=Developer ID Application: Tom Kaczocha (XXXXXXXXXX)` — confirms Developer ID cert
- `Timestamp=...` — confirms secure timestamp was embedded
- `runtime` in `CodeDirectory flags` — confirms Hardened Runtime

Confirm entitlements match `Resources/SystemAudioToMP3.entitlements`:

```bash
codesign -d --entitlements - build/export/SystemAudioToMP3.app
```

---

## CI / Automated Builds

For GitHub Actions or other CI environments, store the certificate as a base64-encoded secret and install it at build time:

```bash
# Decode and install cert
echo "$DEVELOPER_ID_APPLICATION_CERT_B64" | base64 --decode > /tmp/cert.p12
security create-keychain -p "" build.keychain
security import /tmp/cert.p12 -k build.keychain -P "$CERT_PASSWORD" -T /usr/bin/codesign
security set-keychain-settings build.keychain
security list-keychains -s build.keychain
security default-keychain -s build.keychain
security unlock-keychain -p "" build.keychain
security set-key-partition-list -S apple-tool:,apple: -s -k "" build.keychain
```

Then run the archive step above with `DEVELOPMENT_TEAM` passed via env.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `errSecInternalComponent` | Keychain locked or cert missing | Unlock keychain; re-install cert |
| `No identity found` | `DEVELOPMENT_TEAM` not set or wrong team | Export `DEVELOPMENT_TEAM` before building |
| `code object is not signed at all` | Build used Debug config | Use `-configuration Release` |
| Timestamp server unreachable | Network/firewall blocking `timestamp.apple.com` | Allow outbound HTTPS to Apple's timestamp server |
