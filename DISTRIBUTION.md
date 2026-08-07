# CoughButton — signing, notarisation and release

How to sign, notarise and publish CoughButton as a downloadable DMG on GitHub
Releases. One-time setup first; after that every release is a single
`make release VERSION=x.y.z`.

Developer ID distribution needs **no App ID and no provisioning profile** — just
the certificate plus notary credentials.

## What `make release` does

1. Runs the unit tests (a failing test aborts the release).
2. `swift build -c release` and assembles `CoughButton.app` via `build-app.sh`.
3. Signs it with the **Developer ID Application** certificate + **Hardened
   Runtime** + secure timestamp, using `CoughButton.entitlements`, and stamps
   the version into the bundle.
4. **Notarises and staples the .app itself**, then packages the DMG and
   notarises that too.
5. Runs `stapler validate` and a Gatekeeper assessment.
6. Tags `vX.Y.Z`, pushes, and creates a GitHub Release with the DMG attached.

> **Why the .app is stapled as well as the DMG:** the built-in updater verifies
> a downloaded build with `spctl` before installing it. A stapled app carries
> its notarisation ticket locally, so that check succeeds offline instead of
> depending on a live call to Apple.

## One-time setup

### 1. Developer ID Application certificate

Already present on this machine:

```sh
security find-identity -v -p codesigning
# Developer ID Application: Victor Rodrigues (9N354A3UZK)
```

If you ever need it on another Mac, export it there as a `.p12` **with the
private key** (Keychain Access ▸ right-click ▸ Export) and import it.

### 2. App Store Connect API key

Reuse the same key as BarPilot/Siloquy if you still have it. To make a fresh
one: appstoreconnect.apple.com ▸ Users and Access ▸ **Integrations** ▸
**App Store Connect API** ▸ **+**, access **Developer**. Download the
`AuthKey_XXXXXXXX.p8` — it is only downloadable once — and note the **Key ID**
and **Issuer ID**.

### 3. notarytool keychain profile

Store the key once so releases notarise non-interactively:

```bash
xcrun notarytool store-credentials "coughbutton-notarization" --key ~/path/to/AuthKey_XXXXXXXX.p8 --key-id KEY_ID --issuer ISSUER_ID
```

Or reuse an existing profile without creating a new one:

```bash
make release VERSION=0.1.0 NOTARIZE_PROFILE=barpilot-notarization
```

### 4. Tools

```bash
brew install create-dmg
```

`gh` must be authenticated. The Makefile forces pushes through the
gh-authenticated account, which avoids a stale keychain credential 403ing.

### 5. GitHub repository

The updater and the release target both point at `vmlrodrigues/CoughButton`.
Create it public before the first release:

```bash
gh repo create vmlrodrigues/CoughButton --public --source . --remote origin
```

## Releasing

```bash
make check
```

```bash
make release VERSION=0.1.0
```

`make check` verifies the certificate, the notary profile, `create-dmg`, `gh`
and `notarytool` before you start.

## Verifying a build

```bash
xcrun stapler validate CoughButton.dmg
```

```bash
codesign -dvv CoughButton.app
```

Expect `Authority=Developer ID Application: Victor Rodrigues (9N354A3UZK)`,
`TeamIdentifier=9N354A3UZK`, and `flags=0x10000(runtime)`.

## Entitlements

`CoughButton.entitlements` is deliberately minimal:

- `com.apple.security.app-sandbox = false` — **required**. The app is built on
  `AXUIElement` calls into another process, which the sandbox forbids outright.
- **Nothing else.** No microphone, camera or screen-recording entitlement: the
  app never touches audio or video itself, it only presses Teams' own buttons.
  Hardened Runtime is applied at signing time (`--options runtime`), which is
  what notarisation requires.

Accessibility permission is a TCC grant made by the user in System Settings, not
an entitlement — there is nothing to declare in the bundle for it.

## Troubleshooting

- **Notarisation returns "Invalid":**
  `xcrun notarytool log <submission-id> --keychain-profile coughbutton-notarization`
  gives the reason. Usually a missing Hardened Runtime or timestamp; CoughButton
  is a single binary with no embedded frameworks, so this is rare.
- **`git push` 403 (denied to another user):** the macOS keychain is serving a
  different GitHub credential. The Makefile already forces the gh account for
  pushes; to fix it globally run `gh auth switch` and clear the stale github.com
  entry in Keychain Access.
- **"App is damaged" after download:** notarisation or stapling failed. Re-run
  and confirm the Gatekeeper step prints OK.
- **App runs but does nothing:** Accessibility permission. After *replacing* a
  build in place, macOS sometimes keeps a stale TCC entry — remove CoughButton
  from System Settings ▸ Privacy & Security ▸ Accessibility and re-add it.
- **`make test` fails with "no such module XCTest":** XCTest ships with Xcode,
  not the Command Line Tools. The Makefile already points `DEVELOPER_DIR` at
  `/Applications/Xcode.app` for the test target, so this only bites if Xcode
  isn't installed there.
