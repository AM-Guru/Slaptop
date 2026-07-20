# GitHub release configuration

The `Build macOS releases` workflow runs only on a push to `main`. Both release jobs additionally check the exact repository, event, full ref, and ref type before GitHub may schedule them. They target the dedicated `slaptop-main-release` organization runner group and the runner carrying all of these labels:

- `self-hosted`
- `macOS`
- `macos-build`
- `xcode`

The runner group is restricted by GitHub organization policy to:

- repository `AM-Guru/Slaptop` only;
- workflow `AM-Guru/Slaptop/.github/workflows/release.yml@refs/heads/main` only; and
- public-repository access solely because Slaptop itself is public.

That external runner-group policy prevents workflows from forks, pull requests, other branches, and other repositories from scheduling this runner, even if someone adds matching `runs-on` labels to another workflow. The `slaptop-release` GitHub Environment accepts deployments from the `main` branch only and has no required reviewers or wait timer, so release jobs start automatically when the protected workflow receives a `main` push.

Because GitHub will not accept a selected-workflow restriction before that workflow exists at its pinned ref, the initial bootstrap is deliberately fail-closed. Before the reviewed workflow is merged, the `macos-build` runner sits in the Slaptop-only group with public-repository access disabled, so nothing in this public repository can schedule it. Immediately after the workflow first reaches `main`, run:

```bash
Scripts/finalize-release-runner-policy.sh
```

The script enables public access only while simultaneously pinning access to this one workflow at `refs/heads/main`, creates or reapplies branch protection, restricts the environment explicitly to `main`, enables secret scanning and push protection, reapplies Actions restrictions, and audits collaborators, signatures, and CODEOWNERS. It fails instead of weakening any missing policy.

`main` is protected on GitHub: only `kalanihelekunihi` may update it, signed commits and linear history are required, conversations must be resolved, administrators are included, and force pushes and deletion are disabled. Local commits pushed to `main` must use a signing key registered with GitHub; merging through GitHub's web interface is another way to produce a verified commit. Because AM Guru currently has only one member, requiring an independent pull-request approval would make `main` impossible to update. Once a second write-capable maintainer is added, the finalizer can require one independent code approval, dismiss stale reviews, and require approval of the latest push without adding a manual release-environment gate:

```bash
INDEPENDENT_RELEASE_REVIEWER=github-login Scripts/finalize-release-runner-policy.sh
```

Pass `INDEPENDENT_RELEASE_REVIEWER` on each finalizer run where that pull-request review policy is desired. `.github/CODEOWNERS` assigns the entire repository—and explicitly the workflow, release scripts, distribution files, project specification, and signing metadata—to `@kalanihelekunihi`. Repository secret scanning and push protection are enabled.

The first job builds an ARM64 Release app, embeds the project license and third-party notices in the app bundle, signs it with the AM Guru Developer ID Application certificate, notarizes and staples both the app and its disk image, and publishes `Slaptop.dmg` as the only uploaded GitHub Release asset. The disk image always contains the verified app, `/Applications` shortcut, and branded background asset. A hash-pinned `dmgbuild` environment writes the Finder metadata directly without automating Finder. Before publication, the release script mounts the signed and stapled image and verifies the background bookmark, 660×400 window, 112-point icons, and exact app/Applications positions; missing or incorrect layout metadata fails the release. GitHub itself also displays its automatically generated source-code links on every release; those are not placed in the DMG.

After the public GitHub Release is created, a separate protected job archives the `SlaptopAppStore` target with the GitHub run number as `CFBundleVersion` and uploads it to App Store Connect. The App Store job depends on the completed GitHub job, but the GitHub job does not depend on Mac App Store signing identities or certificates, App Store target validation, packaging, or upload. An App Store failure is therefore reported independently and cannot prevent or undo the public GitHub Release. The App Store Connect API key remains shared because the GitHub app and DMG must be notarized by Apple before publication. `Distribution/AppStoreQAExportOptions.plist` leaves `testFlightInternalTestingOnly` disabled, so the same build can be tested internally and later selected for a public App Store version. The workflow does not attach the build to an App Store version, update App Sandbox Usage Information or Review Notes, add the version to an App Review submission, or release it to customers.

The App Store target is sandboxed, excludes the updater, and contains no privileged helper or launch daemon. It reads AppleSPU reports in-process using the documented temporary IOKit user-client exception for `IOHIDLibUserClient`. The sensor class and report layout remain undocumented, so App Review may still reject it under the public-API rule. The upload job requires a valid Feedback Assistant case number and validates rendered sandbox-usage and review-note text before it imports signing credentials. The investigation, required submission evidence, metadata workflow, and fallback are documented in [MAC_APP_STORE.md](MAC_APP_STORE.md).

## Protected GitHub configuration

Private keys, certificate passwords, and App Store Connect credentials must be repository **Secrets**, never repository Variables or committed files. The workflow requires these secret names:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded PKCS#12 export containing `Developer ID Application: AM Guru, LLC (59A594LZGR)` and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password protecting that PKCS#12 export |
| `APP_STORE_DEVELOPMENT_P12_BASE64` | Base64-encoded PKCS#12 export containing the dedicated `Apple Development: Created via API (AHG2S22W82)` identity and its private key |
| `APP_STORE_DEVELOPMENT_P12_PASSWORD` | Password protecting the Apple Development PKCS#12 export |
| `APP_STORE_DISTRIBUTION_P12_BASE64` | Base64-encoded PKCS#12 export containing `Apple Distribution: AM Guru, LLC (59A594LZGR)` and its private key |
| `APP_STORE_DISTRIBUTION_P12_PASSWORD` | Password protecting the Apple Distribution PKCS#12 export |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key used by `notarytool` |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |

Configure these non-sensitive repository **Variables**:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | `59A594LZGR` |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application: AM Guru, LLC (59A594LZGR)` |
| `APP_STORE_DEVELOPMENT` | `Apple Development: Created via API (AHG2S22W82)` |
| `APP_STORE_DISTRIBUTION` | `Apple Distribution: AM Guru, LLC (59A594LZGR)` |
| `XCODE_DEVELOPER_DIR` | The selected Xcode path on the `macos-build` runner, such as `/Applications/Xcode-beta.app/Contents/Developer` |

Configure this release-specific non-sensitive **Variable** on the protected `slaptop-release` GitHub Environment:

| Variable | Value |
| --- | --- |
| `APP_STORE_FEEDBACK_ID` | The real Feedback Assistant case for the missing public Mac motion-sensor sandbox path, in `FB12345678` form |

Do not use a placeholder case number. The App Store validation and upload steps stop before signing when this variable is absent or malformed.

Repository administrators can configure values without printing them:

```bash
base64 < DeveloperIDApplication.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --repo AM-Guru/Slaptop
read -rs P12_PASSWORD
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo AM-Guru/Slaptop
unset P12_PASSWORD

base64 < AppleDevelopment.p12 | gh secret set APP_STORE_DEVELOPMENT_P12_BASE64 --repo AM-Guru/Slaptop
read -rs APP_STORE_DEVELOPMENT_P12_PASSWORD
printf '%s' "$APP_STORE_DEVELOPMENT_P12_PASSWORD" | gh secret set APP_STORE_DEVELOPMENT_P12_PASSWORD --repo AM-Guru/Slaptop
unset APP_STORE_DEVELOPMENT_P12_PASSWORD

base64 < AppleDistribution.p12 | gh secret set APP_STORE_DISTRIBUTION_P12_BASE64 --repo AM-Guru/Slaptop
read -rs APP_STORE_P12_PASSWORD
printf '%s' "$APP_STORE_P12_PASSWORD" | gh secret set APP_STORE_DISTRIBUTION_P12_PASSWORD --repo AM-Guru/Slaptop
unset APP_STORE_P12_PASSWORD

base64 < AuthKey_KEYID.p8 | gh secret set APP_STORE_CONNECT_PRIVATE_KEY_BASE64 --repo AM-Guru/Slaptop
printf '%s' 'KEY_ID' | gh secret set APP_STORE_CONNECT_KEY_ID --repo AM-Guru/Slaptop
printf '%s' 'ISSUER_ID' | gh secret set APP_STORE_CONNECT_ISSUER_ID --repo AM-Guru/Slaptop

gh variable set APPLE_TEAM_ID --body '59A594LZGR' --repo AM-Guru/Slaptop
gh variable set DEVELOPER_ID_APPLICATION --body 'Developer ID Application: AM Guru, LLC (59A594LZGR)' --repo AM-Guru/Slaptop
gh variable set APP_STORE_DEVELOPMENT --body 'Apple Development: Created via API (AHG2S22W82)' --repo AM-Guru/Slaptop
gh variable set APP_STORE_DISTRIBUTION --body 'Apple Distribution: AM Guru, LLC (59A594LZGR)' --repo AM-Guru/Slaptop
gh variable set XCODE_DEVELOPER_DIR --body '/Applications/Xcode-beta.app/Contents/Developer' --repo AM-Guru/Slaptop
gh variable set APP_STORE_FEEDBACK_ID --body 'FB12345678' --env slaptop-release --repo AM-Guru/Slaptop
```

The signing certificates and API key are decoded only beneath `RUNNER_TEMP`. Each signing step imports its certificate into a temporary keychain and deletes that keychain and all credential files on success, failure, cancellation, or timeout cleanup.

`Scripts/ci-app-store-qa.sh` imports dedicated Apple Development and Apple Distribution identities into an isolated keychain. Xcode uses the development identity for its automatic archive and the distribution identity or cloud signing for export. The script uses the App Store Connect key with Xcode’s `-allowProvisioningUpdates` authentication flow to manage the provisioning profile and upload with the `app-store-connect` export method, then deletes its temporary keychain, archive, and key material when the step completes or fails.

Before either build starts, `Scripts/validate-release-configuration.sh` verifies that the job is a `push` of the fetched `main` tip in `AM-Guru/Slaptop`, regenerates an isolated Xcode project, and validates the App Store Connect private key without printing credential contents. Its `github` mode checks only the Developer ID app/helper targets, launch daemon, hardened runtime, Developer ID certificate, and GitHub distribution settings. Its `app-store` mode independently checks only the sandboxed App Store target, category, temporary exception, Feedback Assistant evidence, generated review metadata, App Store export settings, and Apple Development/Distribution certificates. A failure confined to App Store configuration therefore cannot block GitHub release validation.
