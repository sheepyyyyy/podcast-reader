# PDF read-aloud: design

Date: 2026-11-05
Status: built, with the changes listed at the end
Extends: `2026-11-05-podcast-reader-design.md`

## Goal

Add a PDF to Podcast Reader and it reads the document aloud on the real page, highlighting each word as it's spoken.

Success looks like this:

- The highlight stays on the word being spoken, across every page of a long document.
- Clicking a word on the page starts reading from that word.
- Skips, speed, search, bookmarks, resume, full screen and shortcuts work the same as for lectures.
- Saved lectures keep working, including the podcast already in the library.

## Scope

**In this version**

- PDFs with real text, added the same way as audio
- Reading on the actual page, with the current word highlighted and pages advancing on their own
- Skipping repeated headers and page numbers
- Reading with the best English voice installed

**Left out for now**

- Scanned PDFs (recognizing text in page images)
- A voice picker
- Reading only selected pages
- Languages other than English
- Filtering footnotes, captions or tables

## Key decision: create the audio up front

| | Create the audio once (chosen) | Speak live |
|---|---|---|
| Start | About 30 s for 30 pages, about 5 min for 300 | Instant |
| Skips and resume | Exact | No real seeking |
| Speed changes | Instant, normal pitch | Must restart the sentence |
| Sharing lecture code | Almost everything | A second playback system |

A PDF becomes a `Lecture` with generated audio and a transcript, so `PlayerController`, `ReaderModel`, the control bar, search and bookmarks work unchanged.

## What testing already showed

Measured on this Mac with throwaway code, using the default Samantha voice:

| Finding | Consequence |
|---|---|
| Rendering runs at about 119× real time: 11,200 words in 33 s | Creating audio up front is practical |
| Every word gets a marker, including `Dr.`, `1885;` and `70%` | Word timing is reliable, given whitespace-separated words |
| Marker offsets reset to 0 every few sentences, at zero-length buffers | Times must be accumulated across chunks |
| Offsets are in bytes (4 per frame), not samples | Must divide by bytes per frame |
| Uncompressed audio is about 300 MB per hour | Must compress to AAC |
| PDFKit located 32,100 of 32,100 words on 30 pages in 93 ms | Word positions are cheap to compute |
| Two-column pages read in the right order | No column logic is needed for well-made PDFs |
| Headers and page numbers appear in `page.string` | They must be filtered out |
| An image-only page returns no text | Scans can be detected |
| Only default-quality voices are installed here | Better voices remain untested |

## Components

**In `PodcastReaderCore`**

| Unit | What it does |
|---|---|
| `DocumentInfo` and `WordLocation` | New optional data on `Lecture`: where each word is on which page |
| `RunningTextFilter` | Decides which margin lines are repeated headers or page numbers |
| `DocumentReader` | Opens a PDF and produces the words to speak, with their page locations |
| `SpeechTimeline` | Turns speech markers into a start and end time for each word |
| `SpeechRenderer` | Renders text to a compressed audio file and collects its markers |
| `DocumentImporter` | Runs the steps above and produces a saved `Lecture` |
| `DocumentWordIndex` | Finds the word at a given page and character, for clicks |

**In `PodcastReaderUI`**

| Unit | What it does |
|---|---|
| `PDFPageView` | Shows the PDF, highlights the active word, follows along and handles clicks |

`AppModel`, `HomeView`, `ReaderView`, `RootView` and `MissingAudioView` gain small changes to route PDFs.

### Data

`Lecture` gains `document: DocumentInfo?`. It must be optional so that lectures saved before this feature still load.

```
DocumentInfo: voiceName, pageCount, locations: [WordLocation]  (one per word)
WordLocation: page, ranges: [location and length in that page's text]
```

A word has two ranges when it was hyphenated across a line break.

For a PDF, `filePath` and `fileBookmark` point at the PDF, which stays where the user keeps it. The audio is saved as `<id>.m4a` beside the lecture's JSON file, and removing the lecture deletes it. The lecture ID is computed from the PDF's bytes, the same way as for audio.

## Which words get read

Text comes from each page's `page.string`, split on whitespace, so a word keeps its punctuation and the voice pauses naturally.

**Hyphenated line breaks:** a word ending in `-` at the end of a line, followed by one starting with a lowercase letter, is joined. `re-` then `building` is spoken as `rebuilding`, and both pieces highlight together.

**Repeated headers and page numbers:** a line is skipped when it sits in the top or bottom 10% of the page and either of these is true:

1. It's only a page number: digits, or `page` followed by digits, ignoring case.
2. The same text, with digits ignored and case folded, appears in those margins on at least 3 pages.

Skipped text still shows on the page but is never highlighted.

Footnotes, captions and tables are read as they are, and equations will sound poor. The spoken order is the PDF's own text order.

**Pages with no text** are passed over silently and stay visible when scrolling. A PDF with no text at all can't be added.

## Audio

- Voice: the highest-quality English voice installed, preferring `en-US` when tied. The name is saved with the lecture.
- Format: AAC in an `.m4a` file, mono, 22,050 Hz, about 40 kbps. That should be roughly 20 MB per hour.
- A PDF keeps its voice until it's removed and added again.

## What you see and do

**Home screen:** the prompt becomes `Drop an audio file or PDF here`, and the file picker accepts PDFs. A small icon tells PDFs and audio apart in recents. While working, it shows `Preparing <title>…` with a progress bar and a `Cancel` button.

**Reader:** the page fills the space above the control bar on the Aurora background, fit to the window's width.

- The current word is highlighted in mint, `#6FF5CF`.
- When the active word is outside the visible area, the view moves so that it's about 20% from the top, turning pages as needed.
- Scrolling by hand stops the following and shows `Back to now`, the same as for captions.
- Clicking a word jumps there, and paused stays paused. Clicking a skipped header or a gap between words does nothing.
- Dragging across text still selects it, so copying still works.
- In full screen, the controls fade as they do for captions and the page takes the freed space.

## When things go wrong

| Situation | What happens |
|---|---|
| The file can't be opened | `This file couldn't be opened. Try an MP3, M4A, WAV or PDF file.` |
| No text in the whole PDF | `This PDF has no readable text. It may be a scan, which isn't supported yet.` |
| Password protected | `This PDF is password protected. Remove the password and try again.` |
| Rendering fails | `Preparing this PDF didn't finish. Try again.`, with `Try again` |
| Canceled | Back to the drop area. Nothing is saved, including partial audio |
| The PDF was moved or deleted | `This PDF has moved.` with `Locate file`. A different PDF is refused, as for audio |
| The saved audio is missing | The PDF is prepared again, keeping bookmarks and position |

## Testing

**Automated, in `PodcastReaderCoreTests`:**

- `RunningTextFilter`: page numbers, repeated headers, a line repeated on only 2 pages, body text in the middle of a page
- `DocumentReader`, on PDFs generated during the test: word order, ranges that locate the right text, hyphen joining, two columns, skipped headers, blank pages, no text, password protection
- `SpeechTimeline`: resets across chunks, bytes per frame, a missing marker, times that never go backward, the final word ending at the end of the audio
- `SpeechRenderer`: a real render whose duration and word count are right, with audio compressed and the last word near the end
- `DocumentWordIndex`: a word, a gap, a skipped region, a hyphenated word, an unknown page
- `Library`: a lecture saved before this feature still loads, removal deletes the audio, and locating refuses a different PDF
- `DocumentImporter`: end to end, cancellation leaves nothing behind

**Automated, in `PodcastReaderUITests`:** importing a PDF through `AppModel`, each message above, and reading controls on a PDF lecture.

**Offscreen checks:** rendered images of the page with a highlight, plus stress timing on a long generated PDF.

**For a person to try:** real clicks on the page, scrolling and following along, real PDFs of their own, and how the voice sounds.

## Known risks

- **Better voices are untested.** None are installed here. If one fails to render or to report word markers, the importer must fall back to another voice rather than fail.
- **Real PDFs vary.** Text order, ligatures and unusual fonts can produce odd reading or highlighting, and only generated PDFs and any found on this Mac can be tested here.
- **Audio timing.** AAC adds a tiny delay at the start of the audio, which may shift the highlight by a fraction of a word. Only listening can confirm this is unnoticeable.
- **Long documents take storage.** A 300-page textbook could be around 10 hours of speech, or roughly 200 MB.

## Changes made while building

Testing and review led to these changes from the design above:

- **Chunks:** each speech marker records its chunk when it arrives. Inferring chunks from offsets failed on lists and symbols, because several words can share one offset. Those words now share the time up to the next word.
- **Saving:** position and last-opened time are saved in a small `<id>.state` file, because a long document's lecture file is many megabytes. Bookmarks rewrite the lecture in the background, and closing waits only for the small file.
- **Clicks:** PDFKit keeps gesture recognizers from firing, so clicks are detected from mouse events. A click on a link reads from that word and doesn't follow the link.
- **Headers:** text repeated exactly on 3 pages is skipped as designed. Text that differs only by its numbers must also be on at least 25% of pages, so that `Chapter 1`, `Chapter 2` and `Figure 3` still get read.
- **Ligatures:** characters like `ﬁ` become plain letters for speech and search.
- **Wording:** locating the wrong PDF shows `That's a different PDF. Choose the original file.`
