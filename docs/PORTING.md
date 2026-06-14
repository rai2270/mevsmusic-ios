# How MeVsMusic Was Ported from Android to iOS

A plain-language walkthrough of rebuilding a 2012 Android 3D music game as a
native Swift app. The entire port — code, assets, app icon, screenshots, this
document — was done with Claude Code (Fable 5), working from the original
Android source as the reference.

If you only read one paragraph: the game *plays* identically to the Android
original, but almost none of the original code runs. The two biggest pieces the
Android version leaned on — a 3D rendering engine and a music/FFT library —
don't exist on iOS, so they were rebuilt on Apple's own frameworks. The trick
was keeping the part that makes the game *the game* (the rules) untouched while
swapping everything underneath it.

---

## What "porting" actually means here

It would be easy to assume porting is line-by-line translation: read a line of
Java, write a line of Swift. It isn't, and it can't be — because a lot of the
Android app's behavior came from libraries that have no iOS equivalent:

- **Rajawali** — an OpenGL 3D engine that drew the room, the ship, and the
  spectrum bars.
- **BASS** — a licensed audio library that played the song *and* produced the
  frequency analysis (the "spectrum") the whole game reacts to.

You can't copy those onto an iPhone. So the real job was: **reproduce what they
did using Apple's frameworks**, while keeping the game's feel pixel-for-pixel
faithful. Think of it like moving a play to a new theater — same script, same
blocking, but new lighting rig, new sound system, new stage crew.

One rule guided the whole effort: **behavior was ported from the original code,
never from memory.** Every timing constant, every collision distance, every
quirk was read out of the Java and carried across deliberately — including the
odd ones (more on those later).

---

## The one decision that made everything else easier

The original authors had already done something smart: they kept the **game
rules** in a file with no ties to Android, graphics, or audio —
`GameLogic.java`. Scoring, lives, when an enemy spawns, when the game ends — all
of it lived in one self-contained "brain" that the rest of the app just fed
information to.

The port preserved that seam exactly. The Swift `GameLogic` imports nothing from
UIKit, SceneKit, or AVFoundation. It's pure logic. That single choice paid off
immediately: **the brain could be tested on its own before any graphics or sound
existed at all** (see "How we knew it worked," below).

The mental model for the whole app:

```
  Your music  ──▶  AudioEngine  ──▶  GameLogic  ──▶  GameRenderer  ──▶  Screen
  (an MP3)         (sound + FFT)     (the rules)     (the 3D scene)
                                          ▲
                                          │
                                     your taps / tilt
```

Everything below walks that pipeline left to right.

---

## Step by step

### 1. The rulebook — `GameLogic.swift`

This is the brain, translated from `GameLogic.java`. It tracks your score and
lives, decides when a chord (an enemy) launches out of the spectrum, runs the
2.5-second bonus spawner, and drives the staged "game over" sequence.

The translation stayed faithful in behavior but became idiomatic Swift on the
surface: the four integer state constants became a Swift `enum`; the six bonus
types became an `enum` whose order matches the original art; Android's
`mScore` / `bRingOn` naming convention was dropped for Swift's `score` /
`isRingOn`.

Faithful means faithful, including the strange parts. The original computed one
frequency constant with integer division (`16000 / 26 = 615`, throwing away the
remainder) — the port keeps that exactly, because changing it would shift which
sounds trigger enemies and the game would no longer "feel" the same.

### 2. Sound and the spectrum — `AudioEngine.swift` (the hardest swap)

This was the most delicate piece. The Android game used BASS for two jobs at
once: **play the song**, and hand the game a **frequency spectrum** 50 times a
second — the data that makes the bars dance and enemies erupt from loud notes.

On iOS:

- **Playback** uses `AVAudioEngine`.
- The **spectrum** is computed by hand using Apple's Accelerate framework
  (`vDSP`), which does the heavy math (a "Fast Fourier Transform," or FFT) very
  efficiently. A small "tap" listens to the audio as it plays, keeps the most
  recent slice of sound, and converts it into frequency bands.

The catch: the original game's rules were *tuned* against BASS's exact numbers.
BASS scaled its output by some internal factor that isn't written down anywhere.
If the iOS spectrum came out even twice as loud or quiet, enemies would pour out
constantly or barely appear — the game would feel wrong.

So that one missing number was **recovered experimentally.** An offline harness
ran both demo songs through the real game rules while sweeping different scaling
values, and the value that reproduced the Android original's enemy-spawn rhythm
was locked in. It's a single, clearly-commented constant in the code, left easy
to re-tune.

### 3. The 3D world — `GameObjects.swift` + `GameRenderer.swift`

Rajawali (OpenGL) was replaced with **SceneKit**, Apple's high-level 3D
framework. SceneKit was chosen over the newer RealityKit on purpose: it maps
almost one-to-one onto how the original scene was organized, and it supports the
particle effects the game needs on older iOS versions.

The 3D models — the room, the ship, its three orbiting weapon rings — are the
**original art assets**, loaded straight from the Android project's model files.
The 14 spectrum bars are simple boxes that stretch upward with the music.

A subtle but important detail: the original renderer drew the world "mirrored"
along one axis compared to the space where collisions were calculated. The port
standardizes on the collision space — the self-consistent world where enemies
chase the ship, bullets fly along its heading, and the camera trails behind it —
so the math stays clean.

### 4. The enemies, bullets, and bonuses — `Particles.swift`

In the Android game these were drawn as OpenGL "point sprites." The port
recreates them as small flat images that always face the camera (billboards),
managed in plain Swift arrays. Each chord, bullet, and bonus is one of these.

The collision checks are a direct translation, including the original's cheap,
fast "are these two things within a small box of each other" test and its exact
distances. The chord animations use the original 8×8 sprite sheets (64 little
frames of a spinning musical note).

### 5. The heartbeat — the game loop

`GameRenderer` runs once per frame (60 times a second) as SceneKit's render
delegate, doing exactly what the original `FlyingRenderer` did each frame:

1. advance the rules by the elapsed time,
2. move the ship from your input,
3. pull a fresh spectrum and spawn enemies from peaking frequencies,
4. check every collision (bullet-hits-chord, chord-hits-ship,
   ship-grabs-bonus),
5. update the score/lives display,
6. check whether the song has ended.

### 6. The screens you actually touch — `MenuViewController` + `GameViewController`

Android's two screens (`Activity` classes) became two iOS view controllers:

- **The song menu** lists the two bundled demo tracks, your own music library,
  and a "pick a file" option — then launches the game with your choice.
- **The game screen** hosts the 3D view plus the heads-up display: score,
  remaining ships, the start countdown, the on-screen steering pad, and the
  staged game-over overlay.

Where Android read your songs through `MediaStore`, iOS uses the music-library
and Files pickers; where Android saved the accelerometer preference to a file,
iOS uses `UserDefaults`.

### 7. Making it feel like a real iPhone app

Several things had no direct Android equivalent and were built fresh:

- **Controls.** An on-screen pad for steering and firing, plus optional
  **tilt steering** via CoreMotion (the iPhone's motion sensors), filtered so it
  feels smooth rather than twitchy.
- **App icon.** The Android icon was tiny (72×72) pixel art. Rather than ship a
  blurry upscale, it was re-rendered crisply at full 1024×1024 by scaling the
  pixel art by an exact whole-number factor onto the app's blue gradient — so
  the equalizer motif stays sharp.
- **Lifecycle.** Pausing audio and the game when you leave the app, resuming
  cleanly when you return.

### 8. The "make it beautiful" pass (the `1.1` graphics update)

Once the faithful port worked, a separate branch pushed the visuals to modern
hardware — **without touching gameplay** (positions, timings, and collisions are
all unchanged). This included HDR lighting with a soft **bloom/glow**,
**music-reactive bars that light up** as they peak, a metallic **physically based
ship** lit by an image-based sky, **soft real-time shadows**, a subtly
**reflective floor**, glowing additive bullet flares, an **engine exhaust** trail,
and 4× anti-aliasing. The enemy sprite sheets were also re-scaled up so chords
stay clean when they fly right up to the ship.

This version ships as `1.1`, alongside the faithful `1.0`, so the two can be
compared side by side.

---

## How we knew it actually worked

This is the part that makes a port trustworthy. Correctness was checked at every
layer, not just at the end:

- **The brain was tested alone.** Because `GameLogic` has no graphics or audio
  dependencies, it was compiled by itself with a stub recorder standing in for
  the UI, then driven through whole simulated games: does the 7-second countdown
  fire, does a maxed-out spectrum spawn chords on the right schedule, does
  silence make the bars decay, does scoring/lives/bonus math match the Java,
  does the game-over sequence run in the correct order? All verified before a
  single 3D frame was drawn.
- **It was run, not just compiled.** The app was repeatedly built and launched
  in the iOS Simulator, and **screenshots were captured and inspected** to
  confirm the menu, the dancing spectrum, enemies in flight, and the game-over
  screen all looked right.
- **Even the special weapon was verified on screen.** The ring weapon (which
  volleys shots at every enemy ahead) only appears from a random pickup, so a
  temporary launch hook was added to grant it on demand, its volley was captured
  for the README, and the hook was then removed.
- **Every change ended green.** The project was kept building cleanly with no
  warnings after each step.

---

## Android → iOS at a glance

| Concern | Android (2012) | iOS port |
|---|---|---|
| Language | Java | Swift |
| 3D rendering | Rajawali (OpenGL ES 2.0) | SceneKit |
| Audio playback | BASS | AVAudioEngine |
| Spectrum / FFT | BASS (`BASS_DATA_FFT1024`) | Accelerate (`vDSP`) |
| Game rules | `GameLogic.java` | `GameLogic.swift` (no platform imports) |
| Frame loop | `FlyingRenderer.java` | `GameRenderer.swift` |
| Particles | GL point sprites | Billboarded planes |
| Game screen | `FlyingActivity` | `GameViewController` |
| Song menu | `MeVsMusicActivity` | `MenuViewController` |
| Tilt input | `SensorManager` | CoreMotion |
| Song library | `MediaStore` | Media-library + Files pickers |
| Saved settings | file in app storage | `UserDefaults` |
| Dependencies | Rajawali + BASS | **none** (Apple frameworks only) |

---

## The result

A native Swift game that:

- plays faithfully to the 2012 original, rebuilt on Apple's own frameworks;
- has **zero third-party dependencies** — no packages, no pods;
- builds with a single tap in Xcode;
- and ships in two flavors — a faithful `1.0` and a graphically modernized
  `1.1`.

For how to play and how to build, see the [README](../README.md).
