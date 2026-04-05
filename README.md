# FaceTouch

A macOS menu bar app that watches for face touching and mouth covering via your webcam.

<img width="632" height="560" alt="Screenshot 2026-04-05 at 3 53 10 PM" src="https://github.com/user-attachments/assets/ebd8af34-75b5-4538-a450-2380e883c7d2" />


I built this because I kept catching myself picking at my beard while thinking and during meetings. This is technically called trichotillomania.

Facetouch uses Apple's Vision framework to detect hand-face contact and color analysis to catch fabric covering the mouth area.

## What it does

- **Face touch detection** — tracks hand joints and flags when any get too close to your face
- **Mouth covered detection** — compares lip color to cheek skin tone to detect fabric (shirt collar, mask, etc.)
- **Full-screen red overlay** when either is detected, click anywhere to dismiss
- **Menu bar history** showing the last 10 checks with timestamps
- **Live preview mode** with real-time detection status and lip color delta readout
- **Configurable check interval** (2s to 60s)
- **Pause function** - pause for 15 minutes, 1 hour, or all day
- Automatically pauses when your screen sleeps

## How it works

The detector grabs frames from your front camera at whatever interval you set. For each check it tries up to 5 frames to find a face (the camera needs a moment to auto-expose after waking up).

**Face touching**: Vision framework detects face bounding box + hand pose joints. If any hand joint lands within 120% of the face bounds, it triggers. Goes into continuous mode while touching is detected.

**Mouth covering**: Samples RGB values around the outer lip landmarks and compares against a cheek patch near the nose. If the Euclidean color distance exceeds 40, something non-skin is covering the mouth. Works well for shirt collars, less reliable with skin-tone fabrics. I made it work for me, but this probably won't work well for all skin tones and lighting conditions. If it doesn't work well for you, sorry in advance! Let's chat - we can likely add some configuration options to make it work for more people and situations.

## Performance

- Uses ~2% CPU during periodic checks (camera on briefly every 10s)
- Memory footprint is around 50MB

## Install

Grab `FaceTouch.app.zip` from [Releases](https://github.com/sberan/facetouch/releases), unzip it, and move to Applications.

The app is signed with a Developer ID certificate. If macOS still blocks it on first launch, right-click the app and choose "Open", or run `xattr -cr FaceTouch.app` in Terminal.

Requires macOS 14+.

## Build from source

```
git clone https://github.com/sberan/facetouch.git
cd facetouch
bash build.sh
open FaceTouch.app
```

Needs Xcode command line tools (`xcode-select --install`).
