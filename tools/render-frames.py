#!/usr/bin/env python3
"""
render-frames.py - generate the Plymouth theme PNG frame sequence.

Source of truth for the beating-heart animation in evo-device-boot.
Lifts the parameters from evoframework.org/static/css/site.css
(.hero-mark-glyph, @keyframes hero-heartbeat, @keyframes
hero-ring-ripple-1, @keyframes hero-ring-ripple-2) and produces:

    plymouth/assets/bg.png
    plymouth/assets/glyph-NN.png   (one per frame in the cycle)
    plymouth/assets/ring1-NN.png   (outer ripple, peaks early)
    plymouth/assets/ring2-NN.png   (inner ripple, phase-offset)

Usage:
    python3 tools/render-frames.py
    python3 tools/render-frames.py --out /tmp/preview

Requirements: Pillow (apt install python3-pil).

The parameter constants at the top of this file are the only place
the brand colours and animation curve are encoded. If site.css ever
changes, sync them here and re-render.
"""

import argparse
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.stderr.write(
        "Pillow not found. Install with: sudo apt install python3-pil\n"
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Parameters (lifted from evoframework.org/static/css/site.css)
# ---------------------------------------------------------------------------

# Canvas. Sized to hold the maximum-scale ripple ring (~2.6 x GLYPH_BOX)
# with a small margin. evo.script applies a single uniform Image.Scale
# at startup to fit the chosen target panel - we never blit a sprite
# larger than the screen.
#
# Memory budget: 640 * 640 * 4 bytes * 45 frames * 3 layers ~= 140 MB
# resident in plymouthd during early boot. Comfortable on Pi 5 / Pi 4
# (>= 2 GB RAM). If you ever target Pi Zero 2 W (512 MB), drop both
# CANVAS dimensions and FRAMES_PER_CYCLE proportionally.
CANVAS_W = 640
CANVAS_H = 640

# Glyph (the rounded square heart). 240 px at native gives a sharp
# downscale to the typical target glyph height (~17% of the smaller
# screen dimension) on every supported panel from 480p up to 1080p.
GLYPH_BOX          = 240
GLYPH_RADIUS_PCT   = 0.18
GLYPH_COLOR_TOP    = (0x00, 0xD4, 0xAA)
GLYPH_COLOR_BOTTOM = (0x00, 0xA0, 0x80)

# Brand primary, used by the ripple rings.
PRIMARY_RGB        = (0x00, 0xD4, 0xAA)

# Background, matches the site's --background dark base.
BG_RGB             = (0x0B, 0x0F, 0x12)

# Rhythm.
FPS              = 30
CYCLE_SECONDS    = 1.5
FRAMES_PER_CYCLE = int(FPS * CYCLE_SECONDS)   # 45

# Heartbeat scale curve: lub at 7%, dub at 21%, idle for the rest.
# (t_pct, scale)
HEARTBEAT_KEYFRAMES = [
    (0.00, 1.00),
    (0.07, 1.06),
    (0.14, 1.00),
    (0.21, 1.04),
    (0.28, 1.00),
    (1.00, 1.00),
]

# Outer ripple: scales 1.0 -> 2.6, opacity peaks at 0.55 around 7%.
RING1_MAX_SCALE   = 2.6
RING1_PEAK_OPAC   = 0.55
RING1_PEAK_AT_PCT = 0.07
RING1_STROKE      = 2

# Inner ripple: 1.0 -> 2.2, opacity peaks at 0.35 around 7%, delayed 0.21s.
RING2_MAX_SCALE   = 2.2
RING2_PEAK_OPAC   = 0.35
RING2_PEAK_AT_PCT = 0.07
RING2_DELAY_PCT   = 0.21 / CYCLE_SECONDS
RING2_STROKE      = 1


# ---------------------------------------------------------------------------
# Math helpers
# ---------------------------------------------------------------------------

def lerp(a, b, t):
    return a + (b - a) * t


def interpolate_scale(t):
    """Piecewise-linear interpolation of the heartbeat keyframes."""
    for i in range(len(HEARTBEAT_KEYFRAMES) - 1):
        t0, s0 = HEARTBEAT_KEYFRAMES[i]
        t1, s1 = HEARTBEAT_KEYFRAMES[i + 1]
        if t0 <= t <= t1:
            if t1 == t0:
                return s0
            return lerp(s0, s1, (t - t0) / (t1 - t0))
    return 1.0


def ring_state(t, max_scale, peak_opac, peak_at_pct, delay_pct=0.0):
    """Compute (scale, opacity) for a ripple ring at time t (0..1)."""
    t_eff = (t - delay_pct) % 1.0
    if t_eff <= peak_at_pct:
        if peak_at_pct > 0:
            opacity = lerp(0.0, peak_opac, t_eff / peak_at_pct)
        else:
            opacity = peak_opac
    else:
        opacity = lerp(peak_opac, 0.0, (t_eff - peak_at_pct) / (1.0 - peak_at_pct))
    scale = lerp(1.0, max_scale, t_eff)
    return scale, max(0.0, opacity)


# ---------------------------------------------------------------------------
# Drawing
# ---------------------------------------------------------------------------

def render_background():
    return Image.new("RGBA", (CANVAS_W, CANVAS_H), BG_RGB + (255,))


def render_glyph(scale):
    """One frame of the heart glyph at the given scale factor."""
    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))

    size   = max(1, int(round(GLYPH_BOX * scale)))
    radius = max(1, int(round(size * GLYPH_RADIUS_PCT)))

    glyph = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw  = ImageDraw.Draw(glyph)

    # Vertical gradient: top -> bottom of the box.
    for y in range(size):
        t = y / max(size - 1, 1)
        r = int(round(lerp(GLYPH_COLOR_TOP[0],    GLYPH_COLOR_BOTTOM[0],    t)))
        g = int(round(lerp(GLYPH_COLOR_TOP[1],    GLYPH_COLOR_BOTTOM[1],    t)))
        b = int(round(lerp(GLYPH_COLOR_TOP[2],    GLYPH_COLOR_BOTTOM[2],    t)))
        draw.line([(0, y), (size, y)], fill=(r, g, b, 255))

    # Mask to a rounded rectangle.
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius, fill=255
    )
    glyph.putalpha(mask)

    x = (CANVAS_W - size) // 2
    y = (CANVAS_H - size) // 2
    canvas.alpha_composite(glyph, dest=(x, y))
    return canvas


def render_ring(scale, opacity, stroke):
    """One frame of a ripple ring at the given scale and opacity."""
    canvas = Image.new("RGBA", (CANVAS_W, CANVAS_H), (0, 0, 0, 0))
    if opacity <= 0.0:
        return canvas

    size   = max(stroke * 4, int(round(GLYPH_BOX * scale)))
    radius = max(1, int(round(size * GLYPH_RADIUS_PCT)))

    ring = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(ring).rounded_rectangle(
        (stroke, stroke, size - stroke - 1, size - stroke - 1),
        radius=radius,
        outline=PRIMARY_RGB + (int(round(opacity * 255)),),
        width=stroke,
    )

    x = (CANVAS_W - size) // 2
    y = (CANVAS_H - size) // 2
    canvas.alpha_composite(ring, dest=(x, y))
    return canvas


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def parse_args():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.normpath(os.path.join(here, "..", "plymouth", "assets"))
    p.add_argument(
        "--out",
        default=default_out,
        help="output directory (default: %(default)s)",
    )
    p.add_argument(
        "--frames",
        type=int,
        default=FRAMES_PER_CYCLE,
        help="frames per cycle (default: %(default)s)",
    )
    return p.parse_args()


def main():
    args = parse_args()
    os.makedirs(args.out, exist_ok=True)

    print("rendering background -> bg.png", flush=True)
    render_background().save(os.path.join(args.out, "bg.png"))

    n = args.frames
    width = max(2, len(str(n - 1)))
    for i in range(n):
        t = i / n
        name = str(i).zfill(width)

        scale_g = interpolate_scale(t)
        render_glyph(scale_g).save(
            os.path.join(args.out, "glyph-" + name + ".png")
        )

        s1, o1 = ring_state(t, RING1_MAX_SCALE, RING1_PEAK_OPAC, RING1_PEAK_AT_PCT)
        render_ring(s1, o1, RING1_STROKE).save(
            os.path.join(args.out, "ring1-" + name + ".png")
        )

        s2, o2 = ring_state(
            t, RING2_MAX_SCALE, RING2_PEAK_OPAC, RING2_PEAK_AT_PCT, RING2_DELAY_PCT
        )
        render_ring(s2, o2, RING2_STROKE).save(
            os.path.join(args.out, "ring2-" + name + ".png")
        )

        print("frame " + name + "/" + str(n - 1), flush=True)

    print("done: " + str(n) + " frames x 3 layers + bg -> " + args.out)


if __name__ == "__main__":
    main()
