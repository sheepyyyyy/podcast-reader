# Podcast Reader

A Mac app for studying by reading along while you listen.

<a href="https://github.com/sheepyyyyy/podcast-reader/releases/latest/download/Podcast-Reader.dmg"><img src="docs/images/download-button.svg" alt="Download for Mac" width="300" height="72"></a>

Or see it first on [its page](https://sheepyyyyy.github.io/podcast-reader/), where you can try the captions and hear the voice.

- **Audio:** give it a recording, and it shows the words as huge synced captions.
- **PDFs:** give it a PDF, and it reads the document aloud on the real page, highlighting each word as it's spoken.

Either way, click any word to go there. Everything runs on your Mac, so nothing you read or listen to leaves your computer. It's English only for now.

## Install

You'll need a Mac with Apple silicon (M1 or later) and macOS 26 or later.

1. Click **Download for Mac** above, and open the file it downloads.
2. Drag **Podcast Reader** into Applications.
3. Open it. macOS will block it the first time, because this free app isn't signed with a paid Apple Developer ID.
4. Go to System Settings, then Privacy & Security, scroll down and click **Open Anyway**. You only need to do this once.

So far it has only been tested on one Mac, an M5 with 16 GB, so please [open an issue](https://github.com/sheepyyyyy/podcast-reader/issues) if something goes wrong.

## Build it yourself

You'll need macOS 26 or later, and Xcode in `/Applications`.

```bash
scripts/build-app.sh
```

```bash
open "build/Podcast Reader.app"
```

## Using it

Drop an MP3, M4A, WAV or PDF file onto the home screen. The first time takes a moment: about a minute per hour of audio, or for a PDF, a few seconds per page with an Apple voice and longer with Kokoro. After that, it opens instantly and resumes where you stopped.

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

It's built to go easy on your battery. Paused or on the home screen, it does almost nothing. While playing, the background drifts and the highlight follows each word. When the window is covered or minimized, the highlight waits until you can see it again, so listening in the background costs little more than the audio.

Saved transcripts, bookmarks, positions and each PDF's generated speech live in `~/Library/Application Support/Podcast Reader/lectures/`. Your own files stay where you keep them.

### PDF notes

- **What gets read:** repeated headers and page numbers are skipped. Footnotes, captions and tables are read as they are, and equations will sound poor.
- **Scanned PDFs:** these have no real text, so they can't be read yet. The app tells you when a PDF looks like a scan.
- **Words in pieces:** some PDFs, such as ones printed from Chrome, store words in pieces, as in "w" then "ritten". The app joins pieces that touch on the page. Where pieces overlap, it joins them only when they make a real word, so "loan minus" stays two words.
- **Selecting text:** dragging across the page still selects text for copying. A click without a drag jumps to that word.

### Voices for PDFs

Choose the voice under **Voice for PDFs** on the home screen.

- **Kokoro (Heart, Bella, Michael, Emma):** natural, flowing neural voices. They run on your Mac's processor, so a PDF takes much longer to prepare, and your Mac may feel slow and warm until it's done. On an M5 with 16 GB, 15 dense pages took about 8.5 minutes, and 100 pages took about 45, using around 10 GB of memory. A 300-page textbook could take over 2 hours. Macs with less memory run fewer copies of the voice at once, so they'll take longer. You can leave it going and read something else, and the app tells you when it's ready.
- **Apple:** the best English voice installed. It's much faster to prepare, but it doesn't flow as well. For free, better ones, go to System Settings, then Accessibility, then Read & Speak (Spoken Content on some versions of macOS). Click the small info button on the System voice row, or choose Manage Voices if that menu offers it. Look for ones marked Premium or Enhanced, such as Ava (Premium), which has been tested with the highlight. Siri voices aren't available to apps.

Choosing a Kokoro voice the first time asks before downloading about 1.3 GB, once. It needs an internet connection for that, and there's nothing else to install. After setup, Kokoro works offline. To free the space, choose **Remove Kokoro…** in the same menu. PDFs already prepared keep working.

A PDF keeps the voice it was prepared with. To change it, right-click its row and choose **Read again with Heart**, or whichever voice is selected. Your bookmarks and place are kept.

If you quit while a PDF is being prepared with Kokoro, add the same PDF again with the same voice, and it picks up where it stopped. **Cancel** throws that work away.

## Development

Build the installer people download, which needs `uv` (`brew install uv`):

```bash
scripts/build-dmg.sh
```

The download page is `docs/index.html`, which GitHub Pages publishes from the `docs` folder. Its button always fetches `Podcast-Reader.dmg` from the latest release, so keep that file name.

Run the tests:

```bash
scripts/test.sh
```

Use this script rather than plain `swift test`. The Command Line Tools toolchain intermittently fails to find the Swift Testing macros, so the script selects Xcode's toolchain for that one command without changing any system setting.

The first run makes the spoken test clips with your Mac's voice, which needs `ffmpeg` (`brew install ffmpeg`). They aren't in this repository because Apple's license limits sharing recordings of its voices.

The tests that use the real Kokoro voice run only when pointed at an install, such as the app's own, and take several minutes. If you point them at an empty folder, they run the full setup there first, so that's how to test a fresh install:

```bash
KOKORO_TEST_ROOT="$HOME/Library/Application Support/Podcast Reader/kokoro" scripts/test.sh
```

Regenerate the audio and PDF files the tests use:

```bash
scripts/make-fixtures.sh
```

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make-pdf-fixtures.swift Tests/PodcastReaderCoreTests/Fixtures
```

`chrome.pdf` is `scripts/chrome-fixture/page.html` printed by Chrome, which needs the internet for its font:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --user-data-dir="$(mktemp -d)" --no-pdf-header-footer --virtual-time-budget=8000 --print-to-pdf=Tests/PodcastReaderCoreTests/Fixtures/chrome.pdf "file://$PWD/scripts/chrome-fixture/page.html"
```

Check the design without opening the app. This renders every screen to PNG files, offscreen:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ReaderSnapshots screens /tmp/snapshots Tests/PodcastReaderCoreTests/Fixtures/sample.mp3
```

Measure performance on a long recording. This runs real transcription, then times search, saving and highlighting:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ReaderSnapshots stress /tmp/snapshots long-recording.mp3
```

Check that jumps land on the active line, including bursts of seeks like dragging the progress bar. This needs a long audio file, and exits with an error on a miss:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ReaderSnapshots landing /tmp/snapshots long-recording.mp3
```

Check real input without touching the screen. This sends real mouse, keyboard and scroll events to the app's views in an offscreen window, and exits with an error on a failure:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ReaderSnapshots interact /tmp/snapshots Tests/PodcastReaderCoreTests/Fixtures/sample.mp3
```

Measure how much work each screen does, still, playing, and playing with the window covered. Run it with a release build, since a debug build does far more work:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run -c release ReaderSnapshots energy /tmp/snapshots Tests/PodcastReaderCoreTests/Fixtures/sample.mp3
```

Measure a long PDF. This imports it for real, times the work, and checks that jumps keep the highlight in view. If the file doesn't exist, it generates a 300-page PDF there first:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift run ReaderSnapshots pdf-stress /tmp/snapshots /tmp/long.pdf
```

`interact` and `pdf-stress` use an Apple voice unless `KOKORO_TEST_ROOT` is set, in which case they use Kokoro Heart from that install.

## How it's organized

- `Sources/PodcastReaderCore`: data, line breaking, search, saving, transcription, PDF reading, speech and playback, with no interface code.
- `Sources/PodcastReaderUI`: the screens and their models.
- `Sources/PodcastReader`: the app's entry point.
- `Sources/ReaderSnapshots`: the development tool above.
- `docs/index.html`: the download page.
- `docs/superpowers`: the design specs and implementation plans.

## Credits and license

Setup downloads these onto your Mac rather than shipping them with the app, and each has its own license: the [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) voice model (Apache 2.0), [uv](https://github.com/astral-sh/uv) (MIT or Apache 2.0), and the Python packages listed in `Sources/PodcastReaderCore/KokoroPackages.swift`, which include espeak-ng data (GPL 3.0).

Podcast Reader itself is under the [MIT License](LICENSE). It comes with no warranty.
