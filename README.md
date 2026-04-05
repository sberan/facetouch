# FaceTouch

A macOS menu bar app that watches for face touching via your webcam.

<img width="632" height="560" alt="image" src="https://github.com/user-attachments/assets/62fbd862-74c5-49eb-a527-f52ee3d1d3c6" />



I built this because I kept catching myself picking at my beard while thinking and during meetings. This is technically called trichotillomania. It's also just good hygiene — touching your face is one of the main ways cold and flu viruses spread, and most people do it dozens of times per hour without realizing it.

Facetouch uses Apple's Vision framework to detect hand-face contact and color analysis to catch fabric covering the mouth area.

## What it does

- **Face touch detection** — tracks hand joints and flags when any get too close to your face
- **Mouth covered detection** (optional) — compares lip color to cheek skin tone to detect fabric (shirt collar, mask, etc.)
- **Full-screen red overlay** when detected, click anywhere to dismiss
- **Timed pause** — pause for 15 minutes, 1 hour, or the rest of the day
- **Menu bar history** showing the last 10 checks with timestamps
- **Live preview mode** with real-time detection status and lip color delta readout
- **Configurable check interval** (2s to 60s)
- **Configurable mouth cover sensitivity** — off by default, adjustable to low/medium/high
- Automatically pauses when your screen sleeps

## How it works

The detector grabs frames from your front camera at whatever interval you set. For each check it tries up to 5 frames to find a face (the camera needs a moment to auto-expose after waking up).

**Face touching**: Vision framework detects face bounding box + hand pose joints. If any hand joint lands within 120% of the face bounds, it triggers. Goes into continuous mode while touching is detected.

**Mouth covering** (off by default): Samples RGB values around the outer lip landmarks and compares against a cheek patch near the nose. If the Euclidean color distance exceeds the configured threshold, something non-skin is covering the mouth. Works well for shirt collars, less reliable with skin-tone fabrics. Enable it from the menu bar under Mouth Cover Detection. I made it work for me, but this probably won't work well for all skin tones and lighting conditions. If it doesn't work well for you, sorry in advance! Let's chat - we can likely add some configuration options to make it work for more people and situations.

## Performance

- Uses ~2% CPU during periodic checks (camera on briefly every 10s)
- Memory footprint is around 50MB

## Install

Grab `FaceTouch.app.zip` from [Releases](https://github.com/sberan/facetouch/releases), unzip it, and move to Applications.

If macOS blocks it on first launch, run `xattr -cr FaceTouch.app` in Terminal.

Requires macOS 14+.

## Build from source

```
git clone https://github.com/sberan/facetouch.git
cd facetouch
bash build.sh
open FaceTouch.app
```

Needs Xcode command line tools (`xcode-select --install`).
