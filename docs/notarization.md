# Notarizing a macOS release

The macOS CLI tarballs are signed and notarized in CI when the signing
secrets are configured (ADR 0210). The manual runbook below is the fallback:
it was the exact procedure used for v0.0.273 and v0.0.274, and it is still
the path whenever CI ran without the secrets. Half of its steps are
machine-local (a keychain profile, a Developer ID identity) and the other
half are ordering rules that are easy to get subtly wrong.

## What signs what

| Artifact | Signed by | Where |
|---|---|---|
| Linux / Windows tarballs | nobody | CI (`release.yml`) builds and uploads them |
| macOS CLI tarballs | Developer ID Application, then Apple notarized | CI `macos-sign` job when the secrets exist; otherwise **locally**, after CI's draft exists |

The macOS tarballs also carry `nanocua.app` (ADR 0314), built, signed and
notarized with the `graff` beside it by `scripts/release-sign-macos.sh`, and
stapled. The manual steps below cover `graff` alone: a tarball they produce has no
app unless you run `apps/nanocua/macos/package.sh` before notarizing.

## The CI path

`release.yml` runs `build` (cross-compile on Linux) → `macos-sign` (macOS
runner) → `release` (checksums + draft). Nothing is uploaded
until `macos-sign` has finished, so a release never holds unsigned macOS
tarballs next to signed ones, and `SHA256SUMS` is computed once from the
exact bytes that are uploaded. There is no replace-in-place step to race a
maintainer who publishes early.

`macos-sign` needs all five repository secrets:

| Secret | Contents |
|---|---|
| `MACOS_CERT_P12` | base64 of a `.p12` holding only the Developer ID Application certificate and its private key |
| `MACOS_CERT_PASSWORD` | the `.p12` export password |
| `AC_API_KEY_P8` | raw contents of the App Store Connect API key (`AuthKey_<KEYID>.p8`) |
| `AC_API_KEY_ID` | that key's id |
| `AC_API_ISSUER_ID` | the App Store Connect issuer UUID |

With all five, the job does steps 1 to 4 below on the runner: imports the
certificate into a temporary keychain, signs each bare `graff` with
`--options runtime --timestamp`, submits a `ditto` zip with
`notarytool --key/--key-id/--issuer --wait`, and **fails unless the JSON
status is `Accepted`** (notarytool exits 0 on `Invalid`; the job prints the
notary log instead). It skips stapling (step 3), re-tars with the original
`graff-<target>/` layout, checks the members, signature, Developer ID
authority and hardened runtime from the new tarball, and hands the tarballs to
`release`. The submission ids are in the job summary.

If any secret is missing, `macos-sign` logs a notice and succeeds without
doing anything; the draft gets the unsigned macOS tarballs and the job
summary says so. Finish that release with the manual runbook.

If notarization fails with the secrets present, the release job does not run
and no draft is created. Fix the cause and re-run the failed jobs; do not
ship a signed but unnotarized binary (`install.sh` notes that hardened runtime
without notarization gets SIGKILLed on Apple silicon).

Do not run the manual runbook on a release CI already signed: re-signing
changes the bytes Apple scanned. Step 5 (verify like a user) applies to
either path.

## Manual runbook: prerequisites (one-time, this machine)

1. **Developer ID Application certificate** in the login keychain:
   ```bash
   security find-identity -v -p codesigning
   # → "Developer ID Application: Rachit Pradhan (WWP9DLJ27P)"
   ```
2. **A notarytool keychain profile** named `notary-local`:
   ```bash
   xcrun notarytool store-credentials notary-local \
     --apple-id <apple-id> --team-id WWP9DLJ27P \
     --password <app-specific-password>
   # or API-key style:
   xcrun notarytool store-credentials notary-local \
     --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-UUID>
   ```
   The app-specific password comes from appleid.apple.com → Sign-In &
   Security → App-Specific Passwords. Profiles live in the LOGIN keychain;
   if `submit` ever says "No Keychain password item found", the profile was
   lost (keychain reset / new machine) and must be re-stored — see the
   v0.0.273 session, where `codedb-notary`/`codedb-local` had both vanished.

## Manual runbook: per-release procedure

```bash
VER=v0.0.274                     # tag already pushed; release.yml has run green
IDENT=6A862136BA5531200B1E7CD97DEA39476D65B22D   # Developer ID Application hash
```

### 1. Pull the CI archives and sign in place

```bash
mkdir -p .graff/notarize-$VER && cd .graff/notarize-$VER
gh release download $VER -R justrach/codegraff -p 'graff-*macos*' -p SHA256SUMS
tar xzf graff-aarch64-macos.tar.gz && tar xzf graff-x86_64-macos.tar.gz

for d in graff-aarch64-macos graff-x86_64-macos; do
  codesign --force --options runtime --timestamp --sign "$IDENT" "$d/graff"
  codesign --verify --strict "$d/graff" && echo "signed $d"
done
```

`--options runtime` (hardened runtime) and `--timestamp` are required by
Apple's notary service; without them submission is rejected.

### 2. Submit to Apple

Zip with `ditto`, not `zip` — resource forks and extended attributes must
survive exactly:

```bash
ditto -c -k --keepParent graff-aarch64-macos graff-aarch64-macos.notarize.zip
ditto -c -k --keepParent graff-x86_64-macos graff-x86_64-macos.notarize.zip
xcrun notarytool submit graff-aarch64-macos.notarize.zip --keychain-profile notary-local --wait
xcrun notarytool submit graff-x86_64-macos.notarize.zip --keychain-profile notary-local --wait
```

Wait for `status: Accepted` on each. Save the submission ids from the
output — they are the release-log evidence that notarization happened.

### 3. Staple — or knowingly skip it

```bash
xcrun stapler staple <dir>/graff
```

**Known limitation (hit on v0.0.273/v0.0.274):** stapler rejects BARE CLI
executables — its supported list is disk images, executable *bundles*, and
flat packages, so bare binaries fail with error 73 even when the submission
was Accepted. This matches zigrepper's RELEASE.md note that `spctl` can be
odd about bare CLIs too. It is safe to skip: the notarization ticket is
bound to the binary's cdhash on Apple's side, Gatekeeper validates online
at first launch, and `install.sh` only requires the Developer ID signature
plus strict verification. Do NOT modify the binary after submission — ship
the exact bytes Apple scanned.

(Stapling DOES work for `.app` bundles and DMGs.)

### 4. Re-tar, refresh checksums, re-upload

```bash
tar -czf graff-aarch64-macos.tar.gz graff-aarch64-macos
tar -czf graff-x86_64-macos.tar.gz graff-x86_64-macos
shasum -a 256 graff-*macos.tar.gz          # new hashes
# replace ONLY the two macos lines in SHA256SUMS with them, keep name order
cp SHA256SUMS.new SHA256SUMS               # upload under the EXACT asset name
gh release upload $VER -R justrach/codegraff \
  graff-aarch64-macos.tar.gz graff-x86_64-macos.tar.gz SHA256SUMS --clobber
gh release delete-asset $VER -R justrach/codegraff SHA256SUMS.new -y  # if mis-named
```

Gotcha hit on v0.0.273: `gh release upload` names assets after the LOCAL
file — uploading `SHA256SUMS.new` creates a stray asset instead of
replacing `SHA256SUMS`. Always stage the final name first.

### 5. Verify like a user

```bash
cd $(mktemp -d)
gh release download $VER -R justrach/codegraff -p 'graff-aarch64-macos*'
shasum -a 256 -c SHA256SUMS --ignore-missing
tar xzf graff-aarch64-macos.tar.gz
codesign --verify --strict graff-aarch64-macos/graff
codesign -dv graff-aarch64-macos/graff 2>&1 | grep Authority=Developer
```

All four commands must pass. That is the whole release.

## Failure modes seen so far

- **"No Keychain password item found"** — profile gone; re-run
  `store-credentials`. Check BOTH spellings before assuming (`codedb-notary`
  and `codedb-local` predate `notary-local`).
- **stapler error 73 on a bare executable** — expected; skip stapling,
  ship the accepted bytes (step 3).
- **Stray asset after upload** — wrong local filename; delete the stray
  asset and upload again under the canonical name.
