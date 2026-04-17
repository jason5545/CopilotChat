# CopilotChat Agent Notes

## Signed macOS deploys

- When deploying `CopilotChatMac.app` to `/Applications`, always use a properly signed build.
- Do not deploy a build created with `CODE_SIGNING_ALLOWED=NO` to `/Applications`.
- An unsigned/ad-hoc deploy changes the app identity and can break OAuth persistence because the app loses the expected keychain/iCloud entitlements.
- For deploy builds, use normal Xcode signing so the app keeps:
  - `Authority=Apple Development`
  - `TeamIdentifier=MW4GWYGX56`
  - `keychain-access-groups`
  - iCloud / ubiquity entitlements

## Safe deploy checklist

- Build `CopilotChatMac` without disabling code signing.
- Before replacing `/Applications/CopilotChatMac.app`, verify the built app is signed.
- After copying to `/Applications`, verify:
  - `codesign -dv --verbose=4 /Applications/CopilotChatMac.app`
  - `codesign -d --entitlements - /Applications/CopilotChatMac.app`
- If an unsigned app was deployed by mistake, tell the user clearly that OAuth/keychain state may appear lost because of the bad deploy method.
