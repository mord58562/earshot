# Earshot for Linux

A CLI that applies any AutoEQ `ParametricEQ.txt` system-wide on Linux,
via a PipeWire virtual sink.

This is intentionally just a CLI - if you want a GUI for PipeWire
effects, install [EasyEffects](https://github.com/wwmm/easyeffects) and
import the same `ParametricEQ.txt` manually. The gap on Linux wasn't
"there's no parametric EQ", it was "no focused workflow that takes an
AutoEQ-format preset and applies it system-wide in one command."

## What you get

- A virtual sink called `Earshot EQ`. Anything routed to it gets the EQ
  applied and forwards to your real default output.
- Zero ongoing runtime cost beyond what the PipeWire filter-chain
  module uses (negligible - biquads are very cheap).
- No daemon. The script writes one config file under
  `~/.config/pipewire/pipewire.conf.d/` and reloads PipeWire.

## Requirements

- PipeWire >= 0.3.60 (filter-chain module is stable from there).
- Python 3.8+.

That's it. No build step.

## Install

```sh
cp linux/earshot-linux ~/.local/bin/
chmod +x ~/.local/bin/earshot-linux

# Optional but recommended: drop the bundled headphone catalog into a
# location the script checks, so `earshot-linux headphone <query>` and
# `earshot-linux list` work without internet roundtrips per call.
mkdir -p ~/.local/share/earshot
cp Resources/headphones.json ~/.local/share/earshot/
```

Ensure `~/.local/bin` is on your `$PATH`.

## Subcommands

```
earshot-linux doctor
  Check PipeWire / wireplumber / pactl presence and the filter-chain
  module. Prints a status table; exits non-zero if anything's missing.

earshot-linux install <ParametricEQ.txt>
  Generate the filter-chain config and reload PipeWire.

earshot-linux headphone <query>
  Search the bundled AutoEQ catalog (oratory1990 + Crinacle, ~2000
  entries) by name, download the matching ParametricEQ.txt from
  GitHub, and install it.

earshot-linux list [query]
  Search/list bundled catalog entries.

earshot-linux print <ParametricEQ.txt>
  Dump the generated config to stdout without installing it.

earshot-linux status
  Report whether the Earshot sink is loaded and the current default
  output sink.

earshot-linux default
  Set the Earshot sink as the system default output.

earshot-linux remove
  Remove the config and reload PipeWire. Restores normal audio.
```

## Typical workflow

```sh
# Sanity-check the environment first:
earshot-linux doctor

# Pick a headphone from the bundled catalog and apply it:
earshot-linux headphone 'HD 600'
earshot-linux default

# ... or, if you already have a ParametricEQ.txt:
earshot-linux install ~/Downloads/HD600.txt
earshot-linux default

# Verify:
earshot-linux status

# Restore normal audio:
earshot-linux remove
```

You can also set the output to "Earshot EQ" via your DE's sound
settings instead of running `earshot-linux default`.

## Browsing the AutoEQ catalog

The same `Resources/headphones.json` that the macOS app uses ships
with this repo. The `list` and `headphone` subcommands read it from
(in order):

1. `headphones.json` next to the `earshot-linux` script.
2. `../Resources/headphones.json` (the repo layout).
3. `~/.local/share/earshot/headphones.json`.

If you want to refresh the catalog from the live AutoEQ tree,
`Tools/refresh-headphones.sh` regenerates it.

## Limitations

- Single configurable EQ at a time. The PipeWire approach doesn't
  multiplex multiple EQs side-by-side; if you want to switch presets,
  re-run `install` (or `headphone <other>`).
- No live UI for editing bands. Edit the `ParametricEQ.txt` file with
  any text editor and re-run `install`. Or use EasyEffects.
- No Auto-preamp / clipping protection. You're trusting the AutoEQ
  preamp value baked into the file (which is generally conservative).
  If you hear clipping, edit the `Preamp:` line in the .txt down a
  couple of dB and re-install.

## Why not port the macOS app directly?

Swift on Linux runs, but AVAudioEngine doesn't exist there, and the
whole macOS engine layer (BlackHole loopback + AUHAL capture + ring
buffer + Varispeed drift comp + AVAudioUnitEQ) is Apple-specific. The
Linux audio stack already has all the equivalent pieces - it just
needs the workflow glue, which is what this script is.
