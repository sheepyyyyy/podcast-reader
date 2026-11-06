# Podcast Reader: design

Date: 2026-11-05
Status: awaiting review

## Goal

A native Mac app for studying lectures and other long talks by reading along while listening. You give it an audio file, and it shows the words as huge synced captions you can click to jump around in the audio.

Success looks like this:

- A 1-hour lecture is ready to read in about a minute, with nothing sent off the Mac.
- In full screen the captions fill the screen and are readable from across a room.
- Clicking any word starts the audio at that word, with no noticeable offset.
- Going back to a lecture is instant and resumes where you stopped.

## Scope

**In the first version**

- Importing MP3, M4A and WAV files by drag and drop or a file picker
- On-device transcription with per-word timing, in English
- Aurora-style captions that highlight word by word, with clickable words
- Skip buttons for 5 and 30 seconds in both directions
- Play and pause, a progress bar you can click, and full screen
- Transcript search
- Playback speed from 0.5× to 2×, with normal voice pitch
- Bookmarks
- A library of recent lectures that remembers your position
- Keyboard shortcuts

**Left out for now**

- Looping a section
- Editing the transcript
- Exporting transcripts or notes
- Labeling who is speaking
- Languages other than English
- Video files
- Notes attached to bookmarks
- App Store distribution or use on other Macs

## Technology

- Swift 6 and SwiftUI, targeting macOS 26 or later, because that is the minimum for the speech engine
- Built with Swift Package Manager and a script, `scripts/build-app.sh`, that assembles `Podcast Reader.app` and signs it ad hoc. No Apple developer account is needed
- Apple's on-device `SpeechAnalyzer` and `SpeechTranscriber` for transcription
- `AVPlayer` for playback

### Why Apple's speech engine

Both engines were tested on the same 3 min 20 s sample of clean, computer-generated speech on this Mac (M5, 16 GB).

| | Apple `SpeechTranscriber` | `faster-whisper` small |
|---|---|---|
| Time taken | 2.9 s (about 69× real time) | 26.4 s (about 7.6× real time) |
| Word timings | 609 of 609 words | 609 of 609 words |
| Dependencies | None beyond macOS | Python packages, and the installed `av` version already breaks its file loading |

Whisper kept more sentence breaks, while Apple's engine used commas in some of those places. Line breaking must not depend on periods alone.

## Components

The code splits into a logic library that can be tested without any interface, and a thin app on top.

**`PodcastReaderCore` (logic library)**

| Unit | What it does |
|---|---|
| `Transcript` | The data: words with text, start and end times, grouped into display lines |
| `LineBuilder` | Turns a list of words into display lines. See the rules below |
| `WordClock` | Given a playback time, finds the active word by binary search. In a pause between words, the last spoken word stays active |
| `SearchIndex` | Given a query, returns matches with surrounding words and a timestamp. Ignores case and punctuation, and matches phrases across word boundaries |
| `Library` | Saves and loads lectures as JSON files |
| `Transcriber` | Turns an audio file into a `Transcript` and reports progress |

**`PodcastReader` (the app)**

| Unit | What it does |
|---|---|
| `PlayerController` | Wraps `AVPlayer`: play, pause, seek, skip, speed, current time |
| `HomeView` | Drop area and recent lectures |
| `ReaderView` | Combines everything below |
| `AuroraBackground` | The slowly drifting color background |
| `CaptionsView` | The lines and clickable words, and following along |
| `ControlBar` | Playback controls and progress bar |
| `SidePanel` | Search and bookmarks tabs |

### Line breaking rules

`LineBuilder` starts a new line when any of these is true:

1. The previous word ends a sentence (`.`, `?`, `!`).
2. The gap before this word is longer than 0.7 seconds.
3. The current line has at least 6 words and the previous word ends in a comma, colon or semicolon.
4. The current line has reached 12 words.

Lines wrap normally if they are wider than the window.

## Saved data

Each lecture is one JSON file in `~/Library/Application Support/Podcast Reader/lectures/`, holding:

- Title, duration and dates added and last opened
- A macOS file bookmark and the path to the audio, which stays where you keep it
- The transcript
- Bookmarks
- Last playback position

A lecture's ID comes from the audio's file size and a SHA-256 hash of its first megabyte. Adding the same file again opens the existing lecture instead of transcribing it twice.

Position is saved every 5 seconds, and when you pause, leave the lecture or quit.

## What you see and do

### Home screen

A drop area with a "Choose file" button, and a list of recent lectures showing title, length and progress. Right-clicking a lecture offers "Remove from library", which deletes the saved transcript and bookmarks but never the audio file.

While a lecture is being transcribed, a progress bar shows how far along it is. The transcript is saved only when it finishes.

### Reader

The look matches the approved mockup:

- Background: navy `#0A1C4A`, with slow drifting blue, violet and teal color fields
- Type: SF Pro Display Heavy, left aligned, with tight tracking of about −3.5%
- Past lines: `#4F74B5`
- Upcoming lines and words not yet spoken: `#9FC2FF`
- Spoken words: white, with a soft glow on the current word
- Text size follows window width: 5.5% of the width, between 28 and 110 points

Following along:

- The active line sits about 38% of the way down the window.
- Scrolling by hand stops the following and shows a "Back to now" button. Clicking it, or clicking a word, turns following back on.

Clicking a word jumps to that word's start time. Playback stays as it was, so a paused lecture stays paused with the highlight moved.

### Controls

Left to right along the bottom:

- Search (opens the side panel on Search)
- Add bookmark
- Bookmarks list (opens the side panel on Bookmarks)
- Back 30, back 5, play or pause, forward 5, forward 30
- Speed, which cycles through 0.5×, 0.75×, 1×, 1.25×, 1.5×, 1.75× and 2×
- Full screen

Above them is the progress bar with elapsed and total time and a tick for each bookmark. Clicking the bar seeks, and clicking a tick jumps to that bookmark.

Skips stop at the start and end of the audio. At the end, playback stops and the play button restarts from the beginning.

In full screen, the controls and pointer fade after 3 seconds without mouse movement and return when the mouse moves. In a normal window the controls stay visible.

### Side panel

The panel slides in from the right and narrows the captions rather than covering them, so they stay readable.

- **Search:** shows each match with the words around it and a timestamp. Clicking one jumps there and turns following back on.
- **Bookmarks:** shows each bookmark's timestamp and line of text in time order. Clicking one jumps there, and each has a delete button.

Pressing B or the bookmark button marks the current word and shows a brief confirmation. Bookmarking a word that already has one does nothing.

### Keyboard shortcuts

| Key | Action |
|---|---|
| Space | Play or pause |
| ← / → | Back or forward 5 seconds |
| ⇧← / ⇧→ | Back or forward 30 seconds |
| B | Add a bookmark |
| ⌘F | Open search |
| ⌘B | Open bookmarks |
| Esc | Close the side panel |
| ⌃⌘F | Full screen |

Playback shortcuts are ignored while typing in the search box.

## Keeping it accurate and smooth

- **Audio timing:** variable-bitrate MP3s can seek inaccurately, so the player uses precise timing (`AVURLAssetPreferPreciseDurationAndTimingKey`) and zero-tolerance seeks.
- **Long lectures:** an hour of speech is roughly 10,000 words. Lines are rendered lazily, and only the line holding the active word updates as words are spoken.
- **Reduced motion:** with the macOS Reduce Motion setting on, the background holds still and scrolling doesn't animate.

## When things go wrong

| Situation | What happens |
|---|---|
| The file can't be read or is an unsupported format | Message on the home screen: the file couldn't be opened. The library is untouched |
| No speech is found | Message saying no speech was found. Nothing is saved |
| Transcription fails or is canceled | Message with a retry option. Nothing partial is saved |
| The speech model needs downloading | Shows download progress, then continues. macOS manages this download |
| The audio file was moved or deleted | Offers to locate the file. The transcript and bookmarks stay safe |
| A saved lecture file is damaged | That lecture is left out of the list and the others load normally |

During testing, `AssetInventory.status` reported `.supported` even though transcription worked without any download. So the app won't use that status to decide whether it can start. It asks macOS to install anything missing, then tries.

## Testing

**Automated tests** in `PodcastReaderCore`:

- `LineBuilder`: each break rule, plus text with no punctuation
- `WordClock`: before the first word, on word boundaries, in pauses, after the last word
- `SearchIndex`: case, punctuation, phrases, no matches
- `Library`: saving and loading, duplicate IDs, a damaged file
- `Transcriber`: transcribes a sample file and checks that word timings increase and that known words appear

**End-to-end checks** in the real app:

- Add MP3, M4A and WAV files.
- Click words, check all four skip buttons, and try each speed and shortcut.
- Search, add and remove bookmarks, then quit and reopen to confirm position and bookmarks are kept.
- Move an audio file and locate it again.
- Enter full screen and confirm the text scales and the controls fade.
- Run a generated 3-hour file and check that scrolling and highlighting stay smooth.

## Known risks

- **Accuracy on real lectures is untested.** So far only clean computer-generated speech has been tried. Real rooms, accents and technical vocabulary may do worse. Your first real lecture is the true test, and Whisper remains a possible fallback if Apple's engine falls short.
- **Sentence breaks are weaker with Apple's engine.** The pause and comma rules should keep lines a sensible length, but they may need tuning on real speech.
