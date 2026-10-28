Kind: tool. Calm and white: system colors, SF Symbols, a glass Record button over a warm-to-cool waveform as the one bold thing.

# Transcriber

Records a meeting, a lecture or a voice memo and transcribes it on this Mac while it's heard (nothing is sent
anywhere to be transcribed). The window has the recordings in a sidebar (title, date, length; searchable by
title and by what was said) and, on the right, either the recorder or the recording selected. The recorder is a
glass Record button (red-orange record/stop mark inside) set low in the middle of a waveform; the disc is macOS 26 Liquid Glass (`.glassEffect(.clear.interactive())`, a material before 26),
which bends the bars passing behind it. The waveform that stands on the divider above the transcript: thin warm gradient bars rising from the
bottom, spanning the middle 60%, warm (orange-red) for You and cool (blue-violet) for Them, blended per moment
from `RecordingSession.callShares`; the transcript's You/Them labels use the same two colors; a timeline where new sound enters on the right (drawn in `LevelMeter`; the running time is only on the
toolbar's Stop button) and the transcript appearing as it's heard. "Include call audio" is a
switch at the foot of the sidebar (off by default), with a note to check the others are OK with transcribing. With call audio on, what plays through the speakers or headphones (the other side of
a Zoom call) is recorded and transcribed too, and each line is labeled You (microphone) or Them (call). A finished
recording shows its title (click to rename), a Summary made by the person's own AI through `LampAI` (a few
sentences, decisions, and action items as checkboxes), and the transcript with a time on each line; a click on a
line plays the audio from there. AI is optional: without it the transcript works and the Summary says so quietly.

## How the code is organized

- `Sources/App.swift`: the window (default 880×580, minimum 640×420) and the Recording menu (⌘R start/stop,
  ⇧⌘N show the recorder, Clear Examples).
- `Sources/Model/Recording.swift`: `Recording` (title, date, duration, `lines`, `summary`, `audioFileName`,
  `isExample`, `hasCustomTitle`, `transcriptNote`), `TranscriptLine` (start time, text, optional `speaker`: .me / .them), `Summary`,
  `ActionItem`, and the `clock`/`spoken` time formats.
- `Sources/Model/Library.swift`: the one shared `@MainActor` model (`Library.shared`). Holds the recordings and
  the selection, makes every change (add, rename, tick an action item, delete with its audio, Clear Examples),
  starts and stops recording, and asks for summaries. Owns the `RecordingSession` and the `Player`.
- `Sources/Model/Summarizer.swift`: the one `LampAI.ask` call, the transcript passed as `data:`, decoded into a
  `Summary` and a suggested title (used only while the person hasn't renamed the recording).
- `Sources/Model/Examples.swift`: the two sample recordings (a team weekly sync and a lecture), text only.
- `Sources/Audio/RecordingSession.swift`: one recording in progress. `AVAudioEngine`'s input goes to an AAC
  file and to the transcriber from the same tap; publishes the level meter, the lines heard and the words
  still being recognized. A transcription failure never stops the recording: it's kept as `transcriptNote`.
- `Sources/Audio/CallAudio.swift`: `CallAudio` hears system audio with ScreenCaptureKit (needs Screen &
  System Audio Recording, asked for through `LampPermissionView` when the switch is turned on; the app's own
  playback is excluded; gaps are filled with silence to stay in step), and `Mixdown`, which mixes the mic and
  call files into the one .m4a after recording. In `RecordingSession`, each side has its own writer,
  transcriber and `TranscriptCollector(speaker:)`; `StreamClock` aligns them by host time, and `merge` sorts
  both sides. When the call played through speakers (`OutputDevice.mayEcho`: not headphones or a Bluetooth
  headset), a mic line of four words or more that repeats a call line word for word within 2 s is dropped as its echo. Any difference keeps
  the line, since one word added or left out can change what was meant. When the mix fails, the call's file is kept as `Recording.callAudioFileName` and the recording
  says so.
- `Sources/Audio/Transcription.swift`: the `Transcriber` protocol, the choice between the two below, and
  `TranscriptCollector`, which gathers lines from whatever thread they arrive on.
- `Sources/Audio/AnalyzerTranscriber.swift`: macOS 26 and later, `SpeechAnalyzer` + `SpeechTranscriber`
  (downloads the language's model once, converts the microphone's audio to the format it wants).
- `Sources/Audio/ClassicTranscriber.swift`: earlier macOS, `SFSpeechRecognizer` with
  `requiresOnDeviceRecognition`, a new request every 50 seconds, lines split at pauses.
- `Sources/Audio/Permissions.swift`: microphone and speech recognition, and the System Settings page to open
  after a refusal. `Sources/Audio/Player.swift`: plays a recording from a time.
- `Sources/Views/`: `ContentView` (split view, the toolbar's Record/Stop with the time), `RecordingList`
  (sidebar, search, delete, the call audio switch), `RecorderView` (the button, `LevelMeter`, the live
  transcript, permission problems), `RecordingDetail` (title, Play, Copy Transcript, `TranscriptRow`s) and
  `SummarySection`.

## Data

Recordings are the LampStore collection "recordings", one `Recording` each; new properties must be optional so
older recordings keep loading. Audio files are `.m4a` in `LampStore.folder/Recordings/`, named in
`audioFileName`; deleting a recording deletes its file. The selected recording is kept in `@SceneStorage`.

Sample content: `Examples.addOnFirstLaunch` writes two recordings marked `isExample` with no audio (so Play is
hidden and lines aren't clickable) and sets "examplesAdded" in LampStore, so they're written once and never
again. Clear Examples (the Recording menu) deletes only recordings with `isExample`.

## Easy to change

- What the summary contains: the prompt and `Draft` in `Summarizer.swift` (add a field to `Summary` as an
  optional, then show it in `SummarySection`).
- Templates for kinds of recordings (a one-on-one, a lecture): a kind on `Recording` and a prompt per kind in
  `Summarizer`.
- How the transcript is split into lines: `ClassicTranscriber.pause` and `wordsPerLine`; with SpeechAnalyzer
  each result is one line (`AnalyzerTranscriber.start`).
- Language: both transcribers use the Mac's language (`Locale.current`).
- The recorder's look: `RecordButton` and `LevelMeter` (bar count is `RecordingSession.meterLength`).
- Sending action items somewhere (Mail, Reminders): from `Summary.actionItems`, with a toolbar button in
  `RecordingDetail`.
