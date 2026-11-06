import Foundation

/// The Python program that runs Kokoro, written into its environment during setup.
enum KokoroHelper {
    /// The version of the model on Hugging Face that this was tested with.
    static let modelVersion = "f3ff3571791e39611d31c381e3a41a3af07b4987"

    /// Three workers of three threads were fastest on a 10-core M5 with 16 GB: about 43 words
    /// a second, where one process manages 32, and five fall to 26. They used about 10 GB
    /// together on long PDFs, so a Mac with less memory runs fewer to leave room for the rest.
    static func workload(memoryBytes: UInt64, cores: Int) -> (workers: Int, threads: Int) {
        let gigabytes = Int(memoryBytes >> 30)
        let workers = max(1, min(3, (gigabytes - 4) / 4))
        return (workers, max(1, cores / workers))
    }

    /// Part of what finished chunks are checked against. Change it when their format changes.
    static let chunkFormat = 1

    static let source = #"""
    import json, math, os, signal, sys, threading, warnings
    from concurrent.futures import ProcessPoolExecutor, as_completed
    import multiprocessing, multiprocessing.connection

    warnings.filterwarnings("ignore")
    RATE = 24000
    VOICES = ["af_heart", "af_bella", "am_michael", "bf_emma"]
    MODEL_VERSION = "\#(modelVersion)"


    def lead_own_process_group():
        """Workers join this group, so they can all be stopped together. It must be this
        program's own group, or stopping it would also stop whatever started this."""
        if os.getpgrp() != os.getpid():
            os.setpgid(0, 0)


    def stop_everything(*_):
        os.killpg(os.getpid(), signal.SIGKILL)


    def watch_input():
        """The app holds this input open. If it closes, the app has quit or asked to stop."""
        try:
            while sys.stdin.buffer.read(4096):
                pass
        finally:
            stop_everything()


    def language(voice):
        return "b" if voice.startswith("b") else "a"


    PIPELINES = {}


    def pipeline(voice):
        code = language(voice)
        if code not in PIPELINES:
            import functools, huggingface_hub
            # Kokoro has no way to ask for a version, so this adds it to every download it makes.
            huggingface_hub.hf_hub_download = functools.partial(huggingface_hub.hf_hub_download, revision=MODEL_VERSION)
            from kokoro import KPipeline
            PIPELINES[code] = KPipeline(lang_code=code, repo_id="hexgrad/Kokoro-82M", device="cpu")
        return PIPELINES[code]


    def watch_parent():
        """A worker waiting for its next job wouldn't otherwise notice the helper is gone."""
        multiprocessing.connection.wait([multiprocessing.parent_process().sentinel])
        os._exit(0)


    def start_worker(threads):
        threading.Thread(target=watch_parent, daemon=True).start()
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        warnings.filterwarnings("ignore")
        import torch
        torch.set_num_threads(threads)
        torch.set_num_interop_threads(1)


    def timestamp(value, offset):
        """A time for the file, or nothing, as NaN isn't valid in JSON."""
        return offset + float(value) if value is not None and math.isfinite(value) else None


    def render_chunk(chunk, voice, folder):
        import numpy as np
        import soundfile as sf
        wav, tokens_file = os.path.join(folder, f"chunk-{chunk['id']}.wav"), os.path.join(folder, f"chunk-{chunk['id']}.json")
        audio, tokens, offset = [], [], 0.0
        for result in pipeline(voice)(chunk["text"], voice=voice, speed=1):
            samples = result.audio.cpu().numpy() if hasattr(result.audio, "cpu") else np.asarray(result.audio)
            audio.append(samples)
            for token in result.tokens or []:
                tokens.append({
                    "text": token.text,
                    "start": timestamp(token.start_ts, offset),
                    "end": timestamp(token.end_ts, offset),
                })
            offset += len(samples) / RATE
        if not audio:
            audio, tokens = [np.zeros(RATE // 10, dtype=np.float32)], []
        # Renamed into place, audio first, so a chunk only counts once both parts are whole.
        sf.write(wav + ".part.wav", np.concatenate(audio), RATE, subtype="PCM_16")
        os.replace(wav + ".part.wav", wav)
        with open(tokens_file + ".part", "w") as handle:
            json.dump(tokens, handle)
        os.replace(tokens_file + ".part", tokens_file)
        return chunk["id"]


    def is_done(chunk, folder):
        base = os.path.join(folder, f"chunk-{chunk['id']}")
        return os.path.exists(base + ".wav") and os.path.exists(base + ".json")


    def render(job_path):
        with open(job_path) as handle:
            job = json.load(handle)
        for chunk in job["chunks"]:
            if is_done(chunk, job["folder"]):
                print(json.dumps({"done": chunk["id"]}), flush=True)
        to_do = [chunk for chunk in job["chunks"] if not is_done(chunk, job["folder"])]
        if to_do:
            context = multiprocessing.get_context("spawn")
            with ProcessPoolExecutor(
                max_workers=min(job["workers"], len(to_do)),
                mp_context=context,
                initializer=start_worker,
                initargs=(job["threads"],),
            ) as pool:
                futures = [pool.submit(render_chunk, chunk, job["voice"], job["folder"]) for chunk in to_do]
                for future in as_completed(futures):
                    print(json.dumps({"done": future.result()}), flush=True)
        print(json.dumps({"finished": True}), flush=True)


    def prepare():
        """Downloads the model, the pronunciation data and every voice, by using them."""
        for index, voice in enumerate(VOICES):
            for _ in pipeline(voice)("Getting ready.", voice=voice):
                pass
            print((index + 1) / len(VOICES), flush=True)


    if __name__ == "__main__":
        lead_own_process_group()
        signal.signal(signal.SIGTERM, stop_everything)
        threading.Thread(target=watch_input, daemon=True).start()
        try:
            if sys.argv[1] == "prepare":
                prepare()
            elif sys.argv[1] == "render":
                render(sys.argv[2])
            else:
                sys.exit(f"unknown command {sys.argv[1]}")
        except Exception as error:
            print(f"failed: {type(error).__name__}: {error}", file=sys.stderr, flush=True)
            sys.stdout.flush()
            stop_everything()
        sys.stdout.flush()
        os._exit(0)
    """#
}
