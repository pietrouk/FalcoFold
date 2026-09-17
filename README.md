# FalcoFold

A free, open-source macOS menu bar app. As you close your MacBook's lid, the desktop tilts, blurs and darkens. Open it again and everything snaps back.

> **Status:** early development. Nothing to download yet.

## Requirements

- Apple silicon MacBook with a lid angle sensor
- macOS 14 Sonoma or later

## Build from source

You need Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

In `project.yml`, set `DEVELOPMENT_TEAM` to your own team ID. A free Apple ID "Personal Team" works, and you can find its ID in Xcode → Settings → Accounts. A stable signature keeps the Screen Recording permission between builds.

```sh
xcodegen generate
xcodebuild -project FalcoFold.xcodeproj -scheme FalcoFold -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/FalcoFold.app
```

Or run `xcodegen generate`, open `FalcoFold.xcodeproj` in Xcode and press Run.

## Privacy

FalcoFold makes no network connections. Screen frames are processed on your Mac and never leave it.

## License

[MIT](LICENSE)
