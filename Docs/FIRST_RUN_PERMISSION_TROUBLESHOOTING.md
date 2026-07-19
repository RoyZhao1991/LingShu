# First-Run macOS Permission Troubleshooting

This page is for first-time LingShu users on macOS 14 and later.

LingShu does not need every permission for every task. A basic text task or document workflow can run without Accessibility, Screen Recording, Microphone, Speech Recognition, or Camera access. Grant only the permission a specific capability needs.

## Permission map

| Permission | Usually requested when... | If denied, you may see... | Recovery path |
| --- | --- | --- | --- |
| Accessibility | You ask LingShu to control or inspect another app's UI | Clicks, typing, or UI inspection fail; the app may report that macOS control is unavailable | Open System Settings > Privacy & Security > Accessibility, enable LingShu, then quit and relaunch the app |
| Screen Recording | You ask LingShu to read pixels from the screen for visual checks or screen-based computer use | Screen capture stays blank or a visual step cannot verify the app state | Open System Settings > Privacy & Security > Screen Recording, enable LingShu, then quit and relaunch |
| Microphone | You start a voice input, voice note, or other live audio capture flow | Voice capture never starts or remains unavailable | Open System Settings > Privacy & Security > Microphone, enable LingShu, then retry the voice feature |
| Speech Recognition | You ask LingShu to transcribe speech on the Mac | Speech-to-text does not start, or the app reports that transcription is unavailable | Open System Settings > Privacy & Security > Speech Recognition, enable LingShu, then retry the transcription flow |
| Camera | You enable camera-based perception or capture | Camera preview or image capture is unavailable | Open System Settings > Privacy & Security > Camera, enable LingShu, then retry the camera feature |

## Safe recovery steps

1. Quit LingShu.
2. Open System Settings > Privacy & Security.
3. Find the relevant permission and enable LingShu.
4. Relaunch LingShu.
5. Retry the same capability, not a different one.

If the permission prompt never appears, trigger the original capability again after relaunch. If the app already appears in the permission list, toggle it off and back on, then relaunch.

## What is optional

- Accessibility and Screen Recording are only needed for UI control and screen-based verification.
- Microphone, Speech Recognition, and Camera are only needed for audio or visual perception features.
- The first document task in the README is designed to work without broad computer-control permissions.

## What to report

If the same capability still fails after granting the permission, include these details in a GitHub Discussion or first-run report:

- macOS version
- LingShu version or release tag
- Which permission was requested
- Which capability you tried
- The visible failure mode
- Whether a relaunch fixed it
