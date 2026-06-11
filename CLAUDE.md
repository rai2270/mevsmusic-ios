# Claude Code Guidelines

## Project Overview
MeVsMusic-iOS is the native Swift port of the MeVsMusic Android game — you fly a ship against the spectrum of your own music. Single Xcode project (`mevsmusic.xcodeproj`, scheme `mevsmusic`), Swift 5 mode, deployment target iOS 17.0, landscape-only. UIKit shell hosting a SceneKit `SCNView`.

The Android original is the reference implementation: `/Users/tamir/Desktop/GitHub/MeVsMusic`. The game rules live in its platform-independent `app/src/main/java/mvm/game/GameLogic.java` and `GameEvents.java` — port behavior from that code, never from memory.

## Code Style
- The fewer lines of code, the better. Keep changes minimal and concise.
- Prefer editing existing files over creating new ones.
- Follow Apple's Swift API Design Guidelines: clarity at the point of use, `lowerCamelCase` members, `UpperCamelCase` types, no needless abbreviations.
- Do not carry Android naming into Swift: drop the `mField`/`bFlag` prefixes — e.g. `mScoreCount` → `score`, `bRingOn` → `isRingOn`.
- Prefer `let` over `var`; prefer value types (`struct`/`enum`) unless reference semantics are needed.
- No force unwraps (`!`) or force casts in committed code; use `guard let` early exits.
- New async code uses Swift concurrency (`async/await`, `@MainActor`), not GCD.

## Architecture
- App target `mevsmusic` plus template test targets (empty stubs).
- Rendering: SceneKit (`GameViewController` hosting an `SCNView`; UIKit lifecycle via `AppDelegate`/`SceneDelegate`). SceneKit was chosen over RealityKit because RealityKit has no particle system below iOS 18 and SceneKit maps 1:1 onto the Android game's Rajawali scene graph. SceneKit is soft-deprecated by Apple but fully supported — accept that trade-off, don't revisit it.
- Keep the port seam from Android: game rules go in a pure-Swift `GameLogic` (+ `GameEvents` protocol) with no UIKit/SpriteKit/AVFoundation imports.
- Planned audio: AVAudioEngine playback + Accelerate (vDSP) FFT. GameLogic's spectrum constants (×130 amplitude scaling, 2.0 max) were calibrated against BASS FFT magnitudes on Android — expect one normalization constant to tune until the game feel matches.
- The project uses Xcode folder-synchronized groups: a new `.swift` file created inside `mevsmusic/` joins the target automatically — do not hand-edit `project.pbxproj` to add files.

## Working Directory
- Always work directly in the main project repository at its root. Never use git worktrees or isolated copies. Changes must be visible in the user's working branch immediately.
- Do NOT spawn the Agent tool with `isolation: "worktree"`. Do NOT call `EnterWorktree`. If you need a subagent, spawn it without isolation.
- If you find yourself running inside `.claude/worktrees/` (check `pwd`), stop, return to the main repo path, and tell the user — do not continue work in the worktree.
- If a previous session left a worktree behind under `.claude/worktrees/`, do not silently clean it up; flag it to the user, since it may contain uncommitted work.

## Process
- Take your time to investigate issues thoroughly. Recheck your work before presenting a solution.
- Read existing related code before making changes to understand patterns already in use.
- After finishing changes, verify the project builds:
  `xcodebuild build -project mevsmusic.xcodeproj -scheme mevsmusic -destination 'generic/platform=iOS Simulator' -quiet`
- The test targets are empty template stubs; only run tests when explicitly asked.

## Don'ts
- Don't add dependencies (SwiftPM packages, CocoaPods) without asking first.
- Don't use deprecated APIs when modern alternatives exist.
- Don't change code signing or team settings.
- Don't commit `xcuserdata/` or other user-specific Xcode state (covered by .gitignore).
