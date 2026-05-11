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
```

Ensure `~/.local/bin` is on your `$PATH`.

## Use

```sh
# Grab an AutoEQ ParametricEQ.txt for your headphones from
# https://github.com/jaakkopasanen/AutoEq (or use the bundled snapshot
# from this repo at Resources/headphones.json - the rawTxtURL field of
# each entry points at the file). For example:

curl -L -o ~/Downloads/HD600.txt \
  'https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/oratory1990/over-ear/Sennheiser%20HD%20600/Sennheiser%20HD%20600%20ParametricEQ.txt'

earshot-linux install ~/Downloads/HD600.txt
```

Then set your output to "Earshot EQ" via your sound settings, or:

```sh
pactl set-default-sink earshot.eq
```

To remove and restore normal audio:

```sh
earshot-linux remove
```

To dump the generated config without installing (useful for diffing
or hand-tweaking):

```sh
earshot-linux print ~/Downloads/HD600.txt > /tmp/eq.conf
```

## Browsing the AutoEQ catalog

The same `Resources/headphones.json` that the macOS app uses is in this
repo. Each entry has a `rawTxtURL` pointing at the live ParametricEQ.txt
in the AutoEQ GitHub repo. You can grep that file for your headphone
and `curl` the URL.

If you find yourself doing this often, `Tools/refresh-headphones.sh`
regenerates the catalog from the live AutoEQ tree.

## Limitations

- Single configurable EQ at a time. The PipeWire approach doesn't
  multiplex multiple EQs side-by-side; if you want to switch presets,
  re-run `install`.
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
