# KDE Piper TTS — give KWrite/Kate (and every speech-dispatcher client) a real neural voice on CachyOS

Replace the robotic espeak-ng default that KDE's text-to-speech uses with [Piper](https://github.com/rhasspy/piper), a modern neural TTS — piped through [speech-dispatcher](https://github.com/brailcom/speechd)'s generic output module. No root required, no Orca installation needed, nothing else replaced.

```
KWrite / Kate "Speak Text" ─┐
Orca ───────────────────────┤→ speech-dispatcher → sd_generic → piper → pacat (PipeWire)
spd-say ─────────────────── ┘
```

Everything that talks to speech-dispatcher follows the new default voice.

Tested on: CachyOS (Arch-based), KDE Plasma 6, `speech-dispatcher 0.12.1`, `kate 26.08.3`, Piper C++ v1.2, PipeWire/PulseAudio.

## Quick start

```sh
git clone https://github.com/eonicman/kde-piper-tts
cd kde-piper-tts
./setup.sh                    # en_US-lessac-medium, spoken slightly slower (length_scale 1.1)
./VOICE=en_US-ryan-high ./setup.sh   # different voice instead
```

Then restart any running speech-dispatcher (`pkill -f speech-dispatcher` — it re-spawns on the next client call) and try
Tools → **Speak Text** in KWrite/Kate, or `spd-say "It works"`.

## What `setup.sh` does

1. Checks `piper`, `pacat`, and the output-module binary are on hand; downloads the Piper voice model into `~/.local/share/piper/voices/` if it isn't already there (~60 MB from the official `rhasspy/piper-voices` repo).
2. Writes `~/.config/speech-dispatcher/piper-generic.conf` — the generic-module wrapper (piper → raw PCM → `pacat`). The sample rate is read from the voice model's `.onnx.json` so it is correct for any voice.
3. Copies the system `/etc/speech-dispatcher/speechd.conf` to `~/.config/speech-dispatcher/speechd.conf` (only if that file doesn't exist yet — it never touches an existing one) and appends a clearly marked block at the end:
   - `AddModule "piper" ... "/path/to/module/conf"` with **absolute** paths,
   - `AddModule "espeak-ng" ...` kept as an explicit fallback,
   - `DefaultModule piper`, `LanguageDefaultModule "en" "piper"`.
4. Prints the verify/test commands.

## Manual setup

The script is short; here's everything it changes by hand.

1. Install piper (any method that gives you a `piper` CLI) and a voice model:

   ```sh
   pipx install piper-tts   # or a manual binary in ~/.local/bin
   mkdir -p ~/.local/share/piper/voices
   curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx
   curl -LO https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json
   ```

2. Copy `piper-generic.conf` from this repo to `~/.config/speech-dispatcher/piper-generic.conf` and fix the two paths inside it (where piper lives, where the voice model lives) for your machine.

3. If it doesn't exist yet, copy the system config and add a block at the end:

   ```sh
   mkdir -p ~/.config/speech-dispatcher
   cp /etc/speech-dispatcher/speechd.conf ~/.config/speech-dispatcher/speechd.conf
   cat >> ~/.config/speech-dispatcher/speechd.conf <<'EOF'
   # >>> kde-piper-tts >>>
   AddModule "piper"     "/usr/lib/speech-dispatcher/speech-dispatcher-modules/sd_generic"   "/home/YOU/.config/speech-dispatcher/piper-generic.conf" "piper.log"
   AddModule "espeak-ng" "/usr/lib/speech-dispatcher/speech-dispatcher-modules/sd_espeak-ng" "/etc/speech-dispatcher/modules/espeak-ng.conf"          "espeak-ng.log"
   DefaultModule piper
   LanguageDefaultModule "en"  "piper"
   # <<< kde-piper-tts <<<
   EOF
   ```

   A user `speechd.conf` **replaces** (not merges with) the system one — that's why the fallback module is explicitly registered again.

4. Restart and verify.

## Verify

```sh
spd-say -O              # must list: piper  (and espeak-ng)
spd-say -L              # must list only the piper voice(s), not hundreds of espeak names
spd-say -w "Now with a neural voice."
```

Watch out: the list-flags are **case-sensitive.** `-o module` *sets* a module, `-O` *lists* modules; `-L` lists voices. (`spd-say -o` with no argument errors out without spawning anything.)

If a speech-dispatcher client silently speaks with the old voice: your module failed to load and speech-dispatcher fell back to espeak-ng with **no visible error**. Diagnose in the foreground:

```sh
pkill -f speech-dispatcher
mkdir -p /tmp/sd-diag
timeout 12 /usr/bin/speech-dispatcher -s -l 5 -L /tmp/sd-diag
grep -i error /tmp/sd-diag/*.log
```

## Troubleshooting — the traps this recipe hit for real

- **Module config path is resolved against `/etc`, not your home — even in a user config.** The `AddModule` docs *claim* relative paths can resolve to `~/.config/speech-dispatcher/`; in 0.12.1 they don't. A missing/relative conf means the module never loads and clients silently fall back to espeak. Use **absolute paths** for both the module binary and its conf file. This is the single biggest gotcha in the whole setup.
- **`piper --output_raw` sends headerless PCM**, not WAV. Don't pipe it into `paplay` (dies with *"Failed to open audio file."*). Use `pacat --raw --format=s16le --rate=<model sample rate> --channels=1`.
- **The raw ALSA route can hang.** On some PipeWire systems `aplay` blocks forever at device-open (even a file argument), and `timeout` can't reliably reap it. The Pulse route (`pacat` / `paplay` against PipeWire-Pulse) is the reliable path here. If playback doesn't finish within a couple of seconds of the audio being done, suspect the ALSA route and switch.
- **If `piper` errors with `libpiper_phonemize.so.1: cannot open shared object file`**, its library directory isn't on the loader path (common with manually installed/pip-style trees). Prefix the command with `LD_LIBRARY_PATH=/path/to/piper/libs` — the generated conf does this automatically when it detects the problem.
- **Audio plays on whatever your default sink is.** Check with `pactl get-default-sink`; switch with `pactl set-default-sink <name>` or your Desktop audio settings.

## Swapping voices

Any voice from [rhasspy/piper-voices](https://huggingface.co/rhasspy/piper-voices) works — put `name.onnx` + `name.onnx.json` in `~/.local/share/piper/voices/`, then re-run `VOICE=<name> ./setup.sh` (or hand-edit the `--model` path and `AddVoice`/`DefaultVoice` lines in `piper-generic.conf`). The sample rate in the execute command is re-derived from the model config each run, so mixed-rate voices are safe. `length_scale > 1.0` slows the voice down; remove the flag for the model default.

## Files

- `setup.sh` — end-to-end setup (idempotent; refuses to touch an existing `speechd.conf`)
- `piper-generic.conf` — the `sd_generic` wrapper it installs

## License

MIT — see [LICENSE](LICENSE).
