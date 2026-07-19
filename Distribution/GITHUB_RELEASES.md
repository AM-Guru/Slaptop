# GitHub release configuration

The `Build notarized macOS release` workflow runs only on a push to `main`. Its job additionally checks the exact repository, event, full ref, and ref type before GitHub may schedule it. It targets the dedicated `slaptop-main-release` organization runner group and the runner carrying all of these labels:

- `self-hosted`
- `macOS`
- `macos-build`
- `xcode`

The runner group is restricted by GitHub organization policy to:

- repository `AM-Guru/Slaptop` only;
- workflow `AM-Guru/Slaptop/.github/workflows/release.yml@refs/heads/main` only; and
- public-repository access solely because Slaptop itself is public.

That external runner-group policy prevents workflows from forks, pull requests, other branches, and other repositories from scheduling this runner, even if someone adds matching `runs-on` labels to another workflow. The `slaptop-release` GitHub Environment also requires approval by `kalanihelekunihi` before the job is released to the runner.

Because GitHub will not accept a selected-workflow restriction before that workflow exists at its pinned ref, the initial bootstrap is deliberately fail-closed. Before the reviewed workflow is merged, the `macos-build` runner sits in the Slaptop-only group with public-repository access disabled, so nothing in this public repository can schedule it. Immediately after the workflow first reaches `main`, run:

```bash
Scripts/finalize-release-runner-policy.sh
```

The script enables public access only while simultaneously pinning access to this one workflow at `refs/heads/main`, reapplies the protected environment and Actions restrictions, and audits branch protection, collaborators, signatures, and CODEOWNERS. It fails instead of weakening any missing policy.

`main` is protected on GitHub: only `kalanihelekunihi` may update it, changes require a pull request with one approval and Code Owner review, stale approvals are dismissed, the most recent pusher cannot approve, conversations must be resolved, administrators are included, and force pushes and deletion are disabled. `.github/CODEOWNERS` assigns the entire repository—and explicitly the workflow, release scripts, distribution files, project specification, and signing metadata—to `@kalanihelekunihi`.

It builds an ARM64 Release app, embeds the project license and third-party notices in the app bundle, signs it with the AM Guru Developer ID Application certificate, notarizes and staples both the app and its disk image, verifies the image contains exactly `Slaptop.app`, then publishes `Slaptop.dmg` as the only uploaded GitHub Release asset. GitHub itself also displays its automatically generated source-code links on every release; those are not placed in the DMG.

After the public GitHub Release is created, the same protected job creates a second signed archive with the GitHub run number as `CFBundleVersion` and uploads it to App Store Connect. `Distribution/AppStoreQAExportOptions.plist` sets `testFlightInternalTestingOnly`, so this build is restricted to internal TestFlight QA and cannot be distributed externally or released on the App Store. The workflow does not add the version to an App Review submission and does not release it to customers.

The current sensor implementation uses a privileged launch daemon and a private AppleSPU interface, and the app is not sandboxed. The QA upload step deliberately emits a warning for the missing App Sandbox entitlement. Apple processing or review may reject this architecture; the automated upload is intended to make that feedback visible without presenting the build as App Store-ready.

## Protected GitHub configuration

Private keys, the certificate password, and App Store Connect credentials must be repository **Secrets**, never repository Variables or committed files. The workflow requires these secret names:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64-encoded PKCS#12 export containing `Developer ID Application: AM Guru, LLC (59A594LZGR)` and its private key |
| `DEVELOPER_ID_P12_PASSWORD` | Password protecting that PKCS#12 export |
| `APP_STORE_CONNECT_PRIVATE_KEY_BASE64` | Base64-encoded App Store Connect API `.p8` key used by `notarytool` |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect API issuer ID |

Configure these non-sensitive repository **Variables**:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | `59A594LZGR` |
| `DEVELOPER_ID_APPLICATION` | `Developer ID Application: AM Guru, LLC (59A594LZGR)` |
| `XCODE_DEVELOPER_DIR` | The selected Xcode path on the `macos-build` runner, such as `/Applications/Xcode-beta.app/Contents/Developer` |

Repository administrators can configure values without printing them:

```bash
base64 < DeveloperIDApplication.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --repo AM-Guru/Slaptop
read -rs P12_PASSWORD
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo AM-Guru/Slaptop
unset P12_PASSWORD

base64 < AuthKey_KEYID.p8 | gh secret set APP_STORE_CONNECT_PRIVATE_KEY_BASE64 --repo AM-Guru/Slaptop
printf '%s' 'KEY_ID' | gh secret set APP_STORE_CONNECT_KEY_ID --repo AM-Guru/Slaptop
printf '%s' 'ISSUER_ID' | gh secret set APP_STORE_CONNECT_ISSUER_ID --repo AM-Guru/Slaptop

gh variable set APPLE_TEAM_ID --body '59A594LZGR' --repo AM-Guru/Slaptop
gh variable set DEVELOPER_ID_APPLICATION --body 'Developer ID Application: AM Guru, LLC (59A594LZGR)' --repo AM-Guru/Slaptop
gh variable set XCODE_DEVELOPER_DIR --body '/Applications/Xcode-beta.app/Contents/Developer' --repo AM-Guru/Slaptop
```

The signing certificate and API key are decoded only beneath `RUNNER_TEMP`. The job imports the certificate into a temporary keychain and deletes that keychain and all credential files on success, failure, cancellation, or timeout cleanup.

`Scripts/ci-app-store-qa.sh` uses the same App Store Connect key with Xcode’s `-allowProvisioningUpdates` authentication flow. Xcode manages the App Store signing certificate and provisioning profile for the archive, uploads it with the `app-store-connect` export method, and deletes its temporary archive and key material when the step completes or fails.

Before any build starts, `Scripts/validate-release-configuration.sh` verifies that the job is a `push` of the fetched `main` tip in `AM-Guru/Slaptop`, regenerates an isolated Xcode project, checks all three bundle IDs, the AM Guru team ID, signing style, ARM64 architecture, hardened runtime, launch daemon identifiers, and distribution plists, then validates the Developer ID certificate and App Store Connect private key without printing credential contents. Any changed bundle ID, team, identity, signing data, branch, repository, or event fails the job before compilation.
