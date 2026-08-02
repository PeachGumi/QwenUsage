# QwenUsage

macOS menu bar app that shows your [Qwen Cloud](https://home.qwencloud.com) token plan usage at a glance.

```
Q 5h:86% · W:60%
```

- **5h** — remaining % of the rolling 5-hour token window
- **W** — remaining % of the weekly token window
- Color-coded: green (>50%), yellow (20–50%), red (<20%)

Click the menu bar icon for details: plan name, exact usage numbers, and next refresh time.

## Requirements

- macOS 14.0+
- Xcode 15+ (for building)
- [xcodegen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- A Qwen Cloud account with an active token plan

## Build & Install

```sh
git clone https://github.com/peach/QwenUsage.git
cd QwenUsage
xcodegen generate
xcodebuild -project QwenUsage.xcodeproj -scheme QwenUsage -configuration Release build
cp -R "$(xcodebuild -project QwenUsage.xcodeproj -scheme QwenUsage -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR/ {print $3}')/QwenUsage.app" /Applications/
open /Applications/QwenUsage.app
```

## Usage

1. Launch QwenUsage — a **Q ?** icon appears in the menu bar.
2. Click it → **Login to Qwen Cloud...** — a browser window opens.
3. Sign in to your Qwen Cloud account. The window closes automatically on success.
4. The menu bar now shows your remaining token percentages, updated every 5 minutes.

Session cookies are persisted to `~/Library/Application Support/QwenUsage/` so you stay logged in across restarts. Use **Logout** from the menu to clear them.

## How It Works

QwenUsage authenticates via your browser session cookies (obtained through an embedded WKWebView) and queries Qwen Cloud's internal billing APIs:

| API | Purpose |
|-----|---------|
| `/tool/user/info.json` | Obtain `sec_token` for API auth |
| `zeldaHttp.../subscription` | Plan type, status, remaining days |
| `zeldaHttp.../quota-config` | Token limits per plan tier |
| `zeldaHttp.../usage` | Current usage percentages & reset times |

These are undocumented internal APIs. If Qwen Cloud changes them, the app will show an error until updated.

## Privacy

- No data leaves your machine except requests to Qwen Cloud's own servers.
- Session cookies are stored locally with `0600` permissions.
- No analytics, no telemetry, no third-party services.

## License

[MIT](LICENSE)
