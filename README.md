# SpeakCast

A tiny macOS menu bar app that plays your Mac's audio through **several outputs at once, in sync**. Combine your speakers, Bluetooth headphones, an HDMI display and a USB DAC, then fine-tune each output's delay, volume and channel mode.

## Features

- Play system audio through any combination of output devices
- **Pro engine**
  - All outputs run on one clock, so they stay locked together
  - Per-output **delay** (0–300 ms, 0.5 ms steps) to compensate for slow devices such as Bluetooth
  - Per-output **volume** (0–150%)
  - Per-output **channel mode**: stereo, left only, right only, or mono (handy for using two speakers as a stereo pair)
  - Master volume and mute
  - **Sync test**: a repeating click so you can line outputs up by ear
- **Simple engine**: creates a standard macOS Multi-Output device for you and restores your previous output when you stop
- Optional **microphone passthrough** to all selected outputs
- Selectable sample rate (auto picks the highest rate every selected device supports, up to 96 kHz) and buffer size (64–1024 frames)
- Shows the latency each device reports to macOS
- Pauses when a selected output is unplugged and resumes automatically when it returns
- Remembers your outputs and settings between launches
- Runs from the menu bar only, with no Dock icon

## Requirements

- macOS **14.2** (Sonoma) or later. System-audio taps are not available on older versions.
- Xcode Command Line Tools (full Xcode is not needed):

  ```bash
  xcode-select --install
  ```

## Install

Download or clone this repository, then run:

```bash
chmod +x build.sh
./build.sh
```

The script compiles the app with `swiftc`, ad-hoc signs it, installs it to `~/Applications/SpeakCast.app` and launches it. Running it again rebuilds and replaces the installed copy.

## Usage

1. Click the speaker icon in the menu bar.
2. Tick every output you want to use.
3. Choose **Pro** or **Simple** at the top.
4. Click **Activate**. In Pro mode macOS asks for the *System Audio Recording* permission the first time. Allow it, and press **Activate** again if audio doesn't start right away.
5. Click **Stop** to go back to normal output.

### Pro vs Simple

| | Pro | Simple |
|---|---|---|
| Single shared clock | Yes | Yes (macOS drift correction) |
| Per-output delay | Yes | No |
| Per-output volume | Yes | No |
| Stereo / left / right / mono per output | Yes | No |
| Master volume and mute | Yes | Use the system volume |
| Sync test click | Yes | No |
| Needs System Audio Recording permission | Yes | No |
| Changes the system default output | No | Yes (restored on stop) |

## Getting outputs in sync

Different outputs have different latency. Wired and HDMI outputs are usually fast, while Bluetooth is often 100 ms or more. To line them up:

1. Switch to **Pro** and turn on **Sync test (repeating click)**.
2. Listen. If you hear a double click, the output that plays it *first* is the fast one.
3. Increase the **delay** of the fast output until you hear a single click.
4. Turn the test off.

The *Reported* latency shown next to each device is what the device tells macOS. Extra processing hidden inside a TV or monitor is not included, so trust your ears over the number.

## Permissions

- **System Audio Recording** (Pro mode): needed to capture the system audio. Manage it in *System Settings → Privacy & Security → Screen & System Audio Recording*.
- **Microphone**: only requested if you enable microphone passthrough.

## How it works

Pro mode creates a global stereo process tap that excludes SpeakCast itself, so there is no feedback loop, and mutes the original output while it is tapped. The tap and all selected output devices are combined into one private aggregate device. A single real-time IOProc writes the captured audio (plus microphone and test click) into a ring buffer, then renders each output from that buffer with its own delay, gain and channel mode. Drift between device clocks is corrected by Core Audio with the highest quality setting.

Simple mode builds a stacked Multi-Output aggregate device, makes it the default output, and puts your previous default back when you stop.

## Troubleshooting

- **No sound after Activate**: check that the permission above is allowed, then press **Reapply**. The status line at the bottom of the window shows the last error.
- **Permission prompt returns after every rebuild**: the app is ad-hoc signed, so macOS treats each build as a new app. Remove the old SpeakCast entry in System Settings and allow the new one.
- **Howling or squealing with the microphone on**: that's acoustic feedback. Use headphones or lower the microphone level.
- **Silence from some streaming apps**: protected (DRM) content may not be capturable through a system-audio tap.
- **An output stays out of sync**: increase its delay, and note that the UI delay range is 0–300 ms.

### Uninstall

```bash
rm -rf ~/Applications/SpeakCast.app
defaults delete com.matinalijani.speakcast   # optional: clears saved settings
```

## Limitations

- Audio is routed as stereo. On outputs with more than two channels only channels 1 and 2 are used.
- The app is signed ad-hoc and not notarized, so it is meant to be built locally with `build.sh`.

## Project layout

| File | Purpose |
|---|---|
| `SpeakCast.swift` | The whole app: Core Audio helpers, real-time router, manager and SwiftUI interface |
| `build.sh` | Compiles, signs, installs and launches the app |
| `LICENSE` | MIT license |

## License

Released under the [MIT License](LICENSE).

## Author

**Matin Alijani**

- Email: [matin.alijani@gmail.com](mailto:matin.alijani@gmail.com)
- LinkedIn: [linkedin.com/in/matin-alijani](https://www.linkedin.com/in/matin-alijani/)

Issues and pull requests are welcome.
