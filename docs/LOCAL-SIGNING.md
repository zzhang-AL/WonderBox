# Local Signing (stable identity across rebuilds)

`package_app.sh` signs ad-hoc by default. An ad-hoc signature has no certificate, so macOS
identifies the app by its code hash (cdhash) instead: `designated => cdhash H"…"`.

The consequence is visible in Privacy & Security. "Full Disk Access" grants are recorded against
that designated requirement, so **every rebuild that changes the code is a different app** to macOS:

- the grant made for the previous build stops applying,
- the privacy pane accumulates several same-named `WonderBox` entries, and the one the user ticks
  can be an older build that no longer matches the running binary,
- the app's own probe (`open()` on a protected file) keeps returning `EACCES`, so the UI keeps
  reporting "Not Authorized" while the switch looks enabled.

This is not a WonderBox bug and it is not fixed by re-granting. It is how TCC treats unsigned
identities, and it is why `DISTRIBUTION.md` says production releases should use a Developer ID.

## What this script does

`scripts/local_sign.sh` creates a **local, self-signed code-signing certificate** and signs the app
with it. The requirement becomes:

```
designated => identifier "com.wondercraft.WonderBox" and certificate root = H"<certificate>"
```

The hash now belongs to the certificate, not to the code, so rebuilding does not change the
identity and a single Full Disk Access grant keeps applying.

## Two ways to use it

Building from source:

```bash
./scripts/local_sign.sh --setup-only
SIGN_IDENTITY="WonderBox Local Signing" ./scripts/package_app.sh
```

Signing a bundle you already have (a downloaded release, or an earlier local build):

```bash
./scripts/local_sign.sh /Applications/WonderBox.app
```

Then relaunch the app, grant Full Disk Access once, and reinstall the fan background service from
the Fan page if it reports an error — that daemon binds its client authorization to the app's
signing requirement, which has just changed.

## Certificate reuse is mandatory

The script never recreates an existing certificate; it prints the SHA-1 it is reusing. A new
certificate would mean a new requirement, which invalidates every grant the user already made.
Delete `~/Library/Application Support/WonderBox/Signing` and the keychain item only if you
deliberately want a fresh identity.

Keep that directory backed up: it holds the private key (`key.pem`). Without it the identity is
unrecoverable and the grants have to be made again.

Override the location with `WONDERBOX_SIGNING_DIR`, the identity name with `SIGN_IDENTITY`, and the
target keychain with `WONDERBOX_KEYCHAIN`.

## Limits

- **Trust is local.** The certificate is trusted only after the profile is imported into that
  machine's keychain. An app signed with it does not verify on a machine that never imported it
  (`CSSMERR_TP_NOT_TRUSTED`), so do not distribute builds signed with a personal local identity.
  Distribute source, or sign releases with a Developer ID.
- **Not notarized.** Gatekeeper still treats it as unidentified; a downloaded bundle needs its
  quarantine attribute cleared (the script does this for the bundle you pass it) or a Finder
  right-click open.
- **Not an App Store path.** The capability matrix in `DISTRIBUTION.md` still applies unchanged.
- **One identity per machine.** Each machine that builds or re-signs needs its own certificate; the
  grant is per machine, per user, per identity.

For public release the only complete answer remains a Developer ID Application identity plus
notarization; `package_app.sh` accepts that through the same `SIGN_IDENTITY` variable:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package_app.sh
```
