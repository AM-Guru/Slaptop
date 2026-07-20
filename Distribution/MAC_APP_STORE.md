# Mac App Store build

`SlaptopAppStore` is a separate Xcode target for TestFlight and App Review evaluation. Its uploaded builds remain eligible for public App Store submission while they are tested internally. It keeps the `guru.am.slaptop` product identity but deliberately differs from the Developer ID build:

- App Sandbox is enabled.
- The GitHub updater and all updater UI are excluded.
- No privileged helper, launch daemon, ServiceManagement dependency, or background-item UI is included.
- AppleSPU reports are read in-process and are never written to disk or sent over the network.
- `LSApplicationCategoryType` is `public.app-category.utilities`.
- `ITSAppUsesNonExemptEncryption` is `false`; the App Store target contains neither the updater nor other cryptographic code.
- The MIT license and third-party notices are embedded in the app bundle.

The Developer ID `Slaptop` target continues to use its privileged sensor helper and GitHub updater. Generate the project with `xcodegen generate`, then select the `SlaptopAppStore` scheme when testing this variant.

## Sensor API investigation

There is no fully supported public Apple API for this sensor path on macOS. The current macOS SDK marks `CMMotionManager` unavailable on macOS, so Core Motion cannot supply the MacBook's built-in accelerometer or gyroscope. The AppleSPU registry class, vendor usages, and 22-byte report layout used by Slaptop are undocumented hardware interfaces even though the IOKit functions used to open and receive HID reports are public.

A local Apple Silicon Mac probe produced these results:

1. The normal App Sandbox could enumerate the AppleSPU device, but `IOHIDDeviceOpen` was denied.
2. Adding only `com.apple.security.temporary-exception.iokit-user-client-class` for `IOHIDLibUserClient` allowed the sandboxed process to open the accelerometer and gyroscope and receive 74 telemetry callbacks in a three-second test.
3. Writing AppleSPU driver power/reporting properties remained denied in the sandbox and is not needed once the device is already reporting. The `APP_STORE` build therefore omits that mutation code entirely.

Apple documents the IOKit user-client temporary-exception entitlement, but temporary exceptions require both a justification during App Store submission and a Feedback Assistant report for the missing sandbox functionality. This makes the implementation technically sandboxed and least-privilege, not a guarantee that App Review will approve the undocumented sensor interface. The fallback if Apple rejects it is to keep Slaptop distributed as a notarized Developer ID app unless Apple provides a public Mac motion API or grants an appropriate entitlement.

Relevant Apple documentation:

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.4.5 (Mac App Store sandboxing and no independent updater) and 2.5.1 (public APIs)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [App Sandbox temporary exception entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
- [App sandbox information for app uploads](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information)

## Required submission evidence

Before uploading another App Store build:

1. Read the automated `Invalid Binary` email from Apple and preserve its exact diagnostic. An App Store Connect build can show `Validated` while a later submission-specific automated check rejects it.
2. File a Feedback Assistant report explaining that macOS has no public Core Motion path for the built-in Mac motion sensors and that Slaptop needs read-only `IOHIDLibUserClient` access. Do not use a placeholder or fabricated case number.
3. Store the resulting `FB` case number as the `APP_STORE_FEEDBACK_ID` variable on the protected `slaptop-release` GitHub Environment.
4. Generate the exact App Store Connect text locally:

   ```bash
   APP_STORE_FEEDBACK_ID=FB12345678 \
     Scripts/render-app-store-review-metadata.sh /tmp/slaptop-app-store-metadata
   ```

5. Paste `AppStoreSandboxUsage.txt` into App Sandbox Usage Information and `AppStoreReviewNotes.txt` into Review Notes before submitting the new build.

The source-of-truth templates are [AppStoreSandboxUsage.template.txt](AppStoreSandboxUsage.template.txt) and [AppStoreReviewNotes.template.txt](AppStoreReviewNotes.template.txt). They identify the temporary entitlement, its narrow use, the Feedback Assistant case, testing instructions, open-source license, and privacy behavior without claiming that the AppleSPU report format is a public API. The renderer checks the case-number format, resolves every placeholder, and enforces App Store Connect's 4,000-character field limit.

The App Store validation and upload scripts fail closed when `APP_STORE_FEEDBACK_ID` is absent or malformed. They generate and validate the same metadata before touching signing credentials, but they do not modify the App Store Connect listing; step 5 remains an explicit submission task.

If Apple's diagnostic says that `IOHIDLibUserClient`, the temporary exception, or direct AppleSPU access is prohibited rather than merely undocumented or unjustified, a Feedback Assistant number will not make the binary eligible. In that case, remove the App Store submission from review and continue distributing the notarized Developer ID build until Apple provides a supported API or entitlement.
