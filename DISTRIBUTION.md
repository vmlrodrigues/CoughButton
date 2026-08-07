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

**If you already have a notarytool profile on this machine, skip to step 3 —
any profile works.** A profile is a credential nickname, not a per-app identity;
sharing one between projects shares the login and nothing else. Each submission
is still notarised independently and gets its own ticket.

The one thing that should make you create a dedicated key is **the key leaving
this machine** — into GitHub Actions secrets, or to a contributor. A shared key
in one repo's secrets can publish every app on the account. Until then, reusing
an existing key is normal practice and costs you nothing.

Creating a key from scratch, since it's done rarely enough to forget:

1. Sign in at **https://appstoreconnect.apple.com**.
2. Go to **Users and Access**, then the **Integrations** tab, then
   **App Store Connect API** in the sidebar. Stay on **Team Keys** — an
   Individual Key is tied to one person and is not what you want here.
3. Click **+** to generate a key.
   - **Name:** something recognisable, e.g. `CoughButton notarisation`.
   - **Access:** **Developer**. That is sufficient for notarisation; don't grant
     Admin or App Manager, this key only needs to submit builds.
4. Click **Generate**, then **Download** the `AuthKey_XXXXXXXX.p8`.

   > **Apple lets you download it exactly once.** There is no second chance —
   > if you lose it, the only fix is to revoke the key and generate a new one.

5. From that same page note two values:
   - **Key ID** — a 10-character string shown in the key's row, and also in the
     filename (`AuthKey_<KEYID>.p8`).
   - **Issuer ID** — a UUID shown once near the top of the page, above the key
     list. It is the same for every key on the account.

Move the key somewhere private and lock it down — **not** into this repo (`.p8`
is gitignored, but don't rely on that):

```bash
mkdir -p ~/.appstoreconnect/private_keys && mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/ && chmod 600 ~/.appstoreconnect/private_keys/*.p8
```

### 3. notarytool keychain profile

A profile is **not** per-app — it is a nickname in your keychain for an App
Store Connect API key, i.e. a login credential. Every submission is notarised
independently and gets its own ticket stapled to its own binary, whichever
profile authenticated it. Sharing a profile between projects shares only the
credential, never the notarisation.

Store the key in the keychain once, so releases notarise without prompting.
Substitute your own Key ID, Issuer ID and filename:

```bash
xcrun notarytool store-credentials "coughbutton-notarization" --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXX.p8 --key-id XXXXXXXXXX --issuer xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

It prints `Validating your credentials...` and then
`Credentials validated.` / `Stored credentials`. If it fails here the key, Key
ID and Issuer ID don't match each other — the usual mistake is pasting the Key
ID into `--issuer`.

`coughbutton-notarization` is what the Makefile defaults to, so once this
succeeds nothing else needs configuring.

**Using a profile you already have instead?** Write its name into
`.notarize-profile` and the Makefile picks it up automatically, so you never
have to remember a flag. The file is gitignored, which is the point — a
machine-specific profile name (possibly naming another project) stays out of a
public repo:

```bash
echo "your-existing-profile-name" > .notarize-profile
```

Resolution order is `NOTARIZE_PROFILE` in the environment, then
`.notarize-profile`, then the default. Confirm whichever you chose with:

```bash
make check
```

**Switching to a dedicated key later is safe and costs nothing.** The API key is
only how you authenticate a submission; what identifies the app is the Developer
ID certificate, which doesn't change. Notarisation happens once per binary and
the ticket is stapled into it, so already-published releases keep working
forever and the old key can be revoked without breaking anything shipped. To
switch: create the key, `store-credentials` it as `coughbutton-notarization`,
then delete `.notarize-profile` — that name is already the Makefile default.

Using a **key of its own** rather than one shared with another project is worth
it for blast radius: revoking it later stops CoughButton releases and leaves
your other apps alone. Create one at appstoreconnect.apple.com ▸ Users and
Access ▸ Integrations ▸ App Store Connect API, access **Developer**.

Any existing profile also works, if you'd rather not set one up yet:

```bash
make release VERSION=0.1.0 NOTARIZE_PROFILE=some-other-profile
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
