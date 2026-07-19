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

Apple documents the IOKit user-client temporary-exception entitlement, but temporary exceptions require a justification during App Store submission. This makes the implementation technically sandboxed and least-privilege, not a guarantee that App Review will approve the undocumented sensor interface. The fallback if Apple rejects it is to keep Slaptop distributed as a notarized Developer ID app unless Apple provides a public Mac motion API or grants an appropriate entitlement.

Relevant Apple documentation:

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 2.4.5 (Mac App Store sandboxing and no independent updater) and 2.5.1 (public APIs)
- [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)
- [App Sandbox temporary exception entitlements](https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html)
- [App sandbox information for app uploads](https://developer.apple.com/help/app-store-connect/reference/app-uploads/app-sandbox-information)

## Suggested App Review explanation

> Slaptop is a free, open-source Utilities app that translates intentional taps on a MacBook display into the user's configured Mission Control and Spaces keyboard shortcuts. The Mac App Store build is sandboxed, contains no updater or privileged helper, and collects or transmits no user data. It requests the `IOHIDLibUserClient` temporary IOKit exception solely for read-only access to accelerometer and gyroscope input reports from the built-in AppleSPU HID device. It does not set driver properties, access arbitrary HID devices, or use the exception for file, network, or process access. Source code is available at https://github.com/AM-Guru/Slaptop and product/privacy information is at https://slaptop.am.guru/.

This explanation must accompany the temporary exception. It should not claim that the AppleSPU report format is a public API.
