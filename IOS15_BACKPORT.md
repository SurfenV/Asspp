# Asspp iPadOS 15 Backport

This branch keeps the iOS 15-compatible interface from Asspp 2.3.20 and
updates its App Store protocol implementation to ApplePackage 1.2.7.

## Included fixes

- Resolve the account-specific App Store pod instead of always using `p25`.
- Retry product and version requests through Apple's `redownload` endpoint
  when `volumeStoreDownloadProduct` returns failure type `5002`.
- Learn and persist the pod for accounts saved by older Asspp releases.
- Show history lookup errors instead of leaving an empty loading screen.
- Show the current loading stage and provide a Cancel button.
- Preserve and inject `iTunesMetadata.plist` into downloaded IPA files.
- Keep the deployment target and SwiftUI navigation compatible with iOS 15.

## Build an unsigned TrollStore IPA

Install a full copy of Xcode, select it with `xcode-select`, then run:

```sh
HTTP_PROXY=http://127.0.0.1:7890 \
HTTPS_PROXY=http://127.0.0.1:7890 \
./Resources/Scripts/compile.release.mobile.ci.sh "$PWD" "$PWD/Asspp-iOS15.ipa"
```

The proxy variables are optional. The resulting IPA is unsigned and intended
for installation with TrollStore.

If Xcode is not installed locally, push the `ios15-history-fix` branch to your
own GitHub fork and run the **Build App** workflow manually. Its uploaded
`Asspp.ipa` artifact is the same unsigned TrollStore build.

## First-device verification

1. Install over Asspp 2.3.20 so its bundle identifier and saved data remain.
2. Open an app and enter Version History.
3. Confirm version numbers replace the raw external version IDs.
4. Download one older version and verify it completes.
5. If an account still reports an expired token, remove and add that account
   again so the current login endpoint can refresh its token and pod.
