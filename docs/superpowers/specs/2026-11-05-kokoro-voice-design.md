# Kokoro voice: design

Date: 2026-11-05
Status: built
Extends: `2026-11-05-pdf-read-aloud-design.md`

## Goal

Let PDFs be read by Kokoro, a neural voice with more natural flow than Apple's voices, without losing anything PDFs can do today.

Success looks like this:

- A PDF read by Kokoro works exactly like one read by Ava: highlighting, clicks, skips, speed, search, bookmarks and resume.
- The highlight stays with the voice, within about 100 ms at sentence starts.
- A long job can be left running, shows the time remaining, and survives quitting.
- If anything about Kokoro fails, Ava and everything already saved keep working.

## Scope

**In this version**

- A **Voice for PDFs** menu: Heart (the default once set up), Bella, Michael, Emma, and the best Apple voice
- One-time setup, with permission first, and a way to remove it
- Reading a PDF that's already been added again with a different voice
- A time-remaining estimate, and picking up after quitting

**Left out for now**

- Listening while a PDF is still being prepared
- Other Kokoro voices, and voices for audio lectures, which don't use speech

## What testing already showed

Measured on this Mac (M5, 4 performance and 6 efficiency cores):

| Setup | Speed | Word timing |
|---|---|---|
| CPU, 1 process | 32 words/s, about 11× | Yes |
| CPU, 3 processes with 3 threads each | 43 words/s, about 15× | Yes |
| CPU, 4 processes with 2 threads each | 42 words/s | Yes |
| CPU, 5 processes with 2 threads each | 26 words/s | Yes |
| GPU through PyTorch | About 10.6× | Yes |
| GPU through MLX | 13 words/s, about 4.7× | Not reported |

Other findings:

- Every word got a time, including `1885` and `70%`, and the tokens rebuilt the input text exactly.
- Sentence starts were within 92 ms of the sound at worst.
- **`ESPEAK_DATA_PATH` must be set, and short.** The pronunciation library ignores the path passed to it, and fails on a 180-character path. A 110-character one works.
- Each voice is a small separate download on first use, so setup must fetch all four.
- The environment is about 900 MB, plus a 312 MB model.

## Design

### Speech engines

`DocumentImporter` takes a `SpeechEngine`, with two implementations: the existing `SpeechRenderer` and a new `KokoroSpeechEngine`. Both produce an `.m4a` and a time per word, so nothing after that step changes. Kokoro PDFs are stored just like Ava ones, with the voice recorded as `Kokoro Heart`.

### Setup

`KokoroEnvironment` manages `~/Library/Application Support/Podcast Reader/kokoro/`:

1. Find `uv` at `/opt/homebrew/bin/uv`, `/usr/local/bin/uv` or `~/.local/bin/uv`, because an app opened from Finder doesn't get the shell's `PATH`.
2. Create a Python 3.12 environment, and install pinned versions of `kokoro` and its tools.
3. Write the helper program, which ships inside the app's code as text.
4. Download the model, the pronunciation data and all four voices.
5. Write a marker file. Only this means setup finished, so an interrupted setup runs again.

It keeps a short link to the pronunciation data and passes that as `ESPEAK_DATA_PATH`. Models stay inside the folder, through `HF_HOME`, and the download cache is deleted afterward. Removing Kokoro deletes the folder. PDFs already prepared keep working, because their audio is separate.

### Rendering

The helper is a small Python program, run once per job with 3 worker processes of 3 threads each.

- Words are split into chunks of about 300 words, ending at sentence ends where possible.
- Each finished chunk is written as a `.wav` and a `.json` of timed tokens, renamed into place so that a half-written chunk never counts.
- It prints a line per finished chunk for progress, and skips chunks that are already done.
- It exits when its standard input closes, so it can't outlive the app.

Swift then joins the chunks in order into one AAC file, 24,000 Hz mono at 48 kbps, adding up the time offsets.

Work happens in `<id>-kokoro-<voice>/` beside the lecture, named with a hash of the words so that a changed job starts over. It's removed on success or on **Cancel**, and left in place on quitting, which is what lets a job pick up again.

### Word timing

`KokoroTimeline` maps Kokoro's tokens onto the app's words by character position with whitespace ignored, because Kokoro can split a word like `well-known` into several tokens. If the two texts differ in length, positions are scaled. Words without a usable time share the gap between neighbors, using the same logic as Apple's voices.

### Choosing a voice

The home screen shows **Voice for PDFs**. With no choice made, it's Heart once Kokoro is set up, and Apple's best voice before that.

Choosing a Kokoro voice before setup asks first: `Set up Kokoro? This downloads about 1.3 GB once, and stays on this Mac.` Setup shows progress and can be canceled, and if it doesn't finish, the voice doesn't change.

Each PDF keeps the voice it was prepared with. When the current voice is different, right-clicking its row offers **Read again with Heart**, which keeps bookmarks and position, using the existing `regenerateAudio`.

### Time remaining

While preparing, the home screen shows `Preparing <title>…` and, after 5% or 20 seconds, `About 40 minutes left`. Times under a minute read `Less than a minute left`. The estimate comes from elapsed time and progress so far.

## When things go wrong

| Situation | What happens |
|---|---|
| Setup fails | `Setting up Kokoro didn't finish. Check your connection and try again.` with `Try again` |
| Rendering fails | `Preparing this PDF didn't finish. Try again.` with `Try again`, keeping finished chunks |
| Kokoro was removed outside the app | Its menu items offer setup again, and saved PDFs still play |
| Quitting during a job | Adding the same PDF again picks up where it stopped |

The voice never changes silently partway through a PDF, and a Kokoro failure never falls back to Ava by itself.

## Testing

**Automated:** chunking, token-to-word mapping, the time-remaining text, finding `uv`, the environment variables and short link, voice defaults and menu rules, and routing through `AppModel` with a stand-in engine.

**Real Kokoro,** in tests that run only when pointed at an installed environment: real setup, a real render, sound alignment under 120 ms at sentence starts, cancel leaving no files and no processes, resume reusing finished chunks, the helper quitting when its input closes, and a full PDF import.

**In the app:** the existing real-event harness on a Kokoro PDF, and a long PDF for timing and memory.

**For a person to try:** how it sounds on real PDFs, the setup flow and menus, and quitting partway.

## Known risks

- **Dependencies can change.** Everything is locked to tested versions, but setup needs network access, and those downloads have to stay available.
- **Unusual text.** Kokoro normalizes text, so symbols, foreign words or long numbers might confuse the mapping. Scaling and interpolation should keep timing close, but only real PDFs will show.
- **Pronunciation.** Technical terms may be mispronounced, and there's no way to correct them yet.
- **Long jobs.** A textbook can take over 2 hours, using most of the CPU and about 10 GB of memory, and the Mac may feel slow. The app asks macOS not to sleep while preparing.

## Changes made while building

- **Work folder:** the caller chooses it per lecture and voice, as `<id>-kokoro-<voice>/`, so `Library.remove` can clear it. A signature file holds the hash of the words and voice, rather than the folder's name, and a mismatch starts over. Removing Kokoro also clears unfinished work, which can reach gigabytes.
- **16-bit chunks:** the helper writes 16-bit audio rather than float, to halve unfinished work's size.
- **Sync limit:** the real-voice test allows 120 ms at true sentence starts. Measured on real sound, the average is 38 ms and the worst 100 ms. "Dr." ends in a period with no pause after it, so it doesn't count as a sentence start.
- **Prompts on the page:** setup and removal questions appear in place of the menu rather than as alerts, like the app's other prompts.
- **Long jobs don't interrupt:** a job that finishes while you're reading something else says `<title> is ready.` rather than taking you out of what you're reading. This wasn't in the design, but a long job makes it matter.
- **A PDF being prepared is held:** it can't be opened or removed until its job ends, and Kokoro can't be removed during a job, because each would break the job.
- **Try again keeps the voice:** it uses the voice that failed, even if the menu has changed since.
- **Missing audio:** when a PDF's audio file is gone, it's made again with the PDF's own voice. If that voice was Kokoro and Kokoro is gone, it uses Apple's, since the choice is then that or nothing.
- **Time remaining:** it ignores the first 15 seconds, when the voice is loading and work picked up from before quitting arrives all at once, so a resumed job's estimate isn't falsely short.
- **Checks on saved work:** finished chunks are matched against a hash of the voice, the words and where the chunks fall, so an update that changes chunking can't reuse old ones. A chunk that can't be read is removed, so that Try again makes it again rather than failing forever.
- **Audio size:** a PDF records its audio file's size. Audio and word times are saved in two steps, so quitting between them would leave them mismatched. A size that doesn't match counts as missing audio, and the audio is made again.
- **Kokoro gone during a job:** this gets its own message rather than the general failure, and no Try again.
- **Workers:** each worker also watches for its parent's exit, in case the helper dies without stopping them.

## Changes made for publishing

So that it works on other people's Macs, and replacing where this document says setup finds `uv`:

- **Getting `uv`:** setup downloads one fixed build of `uv`, checks its SHA-256 fingerprint before running it, and deletes it afterward. Nobody has to install anything, so the error for a missing `uv` is gone.
- **Python:** it stays inside the Kokoro folder, whatever Python or `uv` settings are already on the Mac, so **Remove Kokoro…** frees all of it.
- **Locked versions:** `KokoroPackages.swift` lists the exact version of every Python package, installed with `--no-deps --no-build`. Building a package would need developer tools most Macs don't have, so `docopt`, which has no ready-made package and which only a command-line script uses, is left out. The helper asks Hugging Face for one exact version of the model.
- **Smaller Macs:** the number of workers follows the Mac's memory, one at 8 GB, two at 12 GB and three from 16 GB, and threads follow its cores. Only the 16 GB, 10-core case has been measured.

## Measured on real PDFs

Full jobs ran well below the short speed test's 43 words a second. Other work was also running on the Mac during these, so a quiet Mac may do somewhat better.

| PDF | Time | Words | Speed | Speech | Audio |
|---|---|---|---|---|---|
| Apple's license, 15 dense pages | 507 s | 11,133 | 22 words/s, about 9× | 1.3 hours | 29 MB |
| Generated, 100 pages of lists and symbols | 2,728 s | 46,500 | 17 words/s, about 8× | 6.4 hours | 142 MB |

- Helper memory peaked at about 10 GB, adding up all its processes, which counts shared memory more than once.
- Pages of the same text took 225 to 232 seconds each across 97 pages, so timing doesn't drift over a long document.
- All 46 jump and burst checks kept the highlight in view, and the highlight updated in about 1 ms a word.
