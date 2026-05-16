#!/usr/bin/env python3
"""
Genera tutte le icone del progetto HRV Trainer:

1. Launcher Android (mipmap-mdpi..xxxhdpi) da 48 a 192 px
2. Adaptive icon foreground/background (Android 8+)
3. Launcher CIQ 40x40 per Instinct Solar 2X (e 28x28 fallback)

Design: cerchio petrolio con ring concentrico (simbolo respiro) + mini cuore
bianco al centro. Niente loghi esterni. Font: default sistema.

Eseguire dalla root del repo:
    python tools/generate_icons.py
"""

from __future__ import annotations

from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
FLUTTER_RES = ROOT / "hrv_trainer" / "android" / "app" / "src" / "main" / "res"
CIQ_DRAWABLES = ROOT / "hrv_watch_ciq" / "resources" / "drawables"

# Palette (match lib/core/theme/app_theme.dart)
PETROL = (15, 111, 122, 255)        # #0F6F7A primary
PETROL_DARK = (6, 70, 78, 255)
ACCENT = (79, 179, 191, 255)         # #4FB3BF inhale
MOSS = (107, 143, 90, 255)           # #6B8F5A secondary
WHITE = (255, 255, 255, 255)
BG_DARK = (14, 21, 21, 255)


def _draw_heart(draw: ImageDraw.ImageDraw, cx: float, cy: float,
                radius: float, fill) -> None:
    """Disegna un cuore classico centrato in (cx, cy).

    `radius` = raggio di ciascun lobo. L'altezza totale del cuore e' ~2.8*r,
    la larghezza ~4*r. I lobi sono centrati orizzontalmente a +/- r dal centro
    cosi' che la "fossetta" al top sia chiaramente visibile.
    """
    r = radius
    # Lobi (top): due dischi pieni
    lobe_cy = cy - r * 0.35
    left = (cx - 2 * r, lobe_cy - r, cx, lobe_cy + r)
    right = (cx, lobe_cy - r, cx + 2 * r, lobe_cy + r)
    draw.ellipse(left, fill=fill)
    draw.ellipse(right, fill=fill)
    # Punta inferiore: triangolo dai margini esterni dei lobi al punto basso
    tip_y = cy + r * 1.65
    draw.polygon(
        [
            (cx - 2 * r, lobe_cy),
            (cx + 2 * r, lobe_cy),
            (cx, tip_y),
        ],
        fill=fill,
    )


def _draw_mark(img: Image.Image, size: int, flat_bg: bool = False) -> None:
    """Disegna il "marchio" HRV al centro dell'immagine.

    Layout:
      - sfondo (se flat_bg) riempito di PETROL con leggero gradiente radiale simulato
      - due ring concentrici (rappresentano l'orb respiratorio)
      - cuore bianco stilizzato al centro
    """
    draw = ImageDraw.Draw(img)
    cx, cy = size / 2, size / 2

    if flat_bg:
        # Sfondo: cerchio pieno PETROL (per launcher square viene clippato dal sistema)
        for r in range(int(size / 2), 0, -1):
            t = r / (size / 2)
            color = (
                int(PETROL[0] + (PETROL_DARK[0] - PETROL[0]) * t),
                int(PETROL[1] + (PETROL_DARK[1] - PETROL[1]) * t),
                int(PETROL[2] + (PETROL_DARK[2] - PETROL[2]) * t),
                255,
            )
            draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color)

    # Ring esterno morbido (opaque per leggibilita' a piccole dimensioni)
    ring_out_r = size * 0.40
    ring_out_w = max(2, int(size * 0.05))
    draw.ellipse(
        (cx - ring_out_r, cy - ring_out_r, cx + ring_out_r, cy + ring_out_r),
        outline=ACCENT,
        width=ring_out_w,
    )

    # Ring interno
    ring_in_r = size * 0.28
    ring_in_w = max(1, int(size * 0.03))
    draw.ellipse(
        (cx - ring_in_r, cy - ring_in_r, cx + ring_in_r, cy + ring_in_r),
        outline=WHITE,
        width=ring_in_w,
    )

    _draw_heart(draw, cx, cy, radius=size * 0.10, fill=WHITE)


def make_square(size: int, *, flat_bg: bool) -> Image.Image:
    img = Image.new("RGBA", (size, size), BG_DARK if flat_bg else (0, 0, 0, 0))
    if flat_bg:
        # Fill whole square with PETROL (launcher legacy)
        ImageDraw.Draw(img).rectangle((0, 0, size, size), fill=PETROL)
    _draw_mark(img, size, flat_bg=False)
    return img


def make_adaptive_background(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), PETROL)
    return img


def make_adaptive_foreground(size: int) -> Image.Image:
    # Adaptive foreground must sit inside safe zone (inner 66% of canvas).
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    inner = int(size * 0.66)
    temp = Image.new("RGBA", (inner, inner), (0, 0, 0, 0))
    _draw_mark(temp, inner, flat_bg=False)
    img.paste(temp, ((size - inner) // 2, (size - inner) // 2), temp)
    return img


def make_ciq_launcher(size: int) -> Image.Image:
    """Icona per Instinct Solar 2X: deve essere visibile su sfondo nero.

    Il watch ha display MIP monocromatico-ish con palette limitata; un'icona
    troppo sottile sparisce. Usiamo forme piene e contrasto alto.
    """
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    cx, cy = size / 2, size / 2

    # Cerchio pieno di sfondo
    r = size * 0.48
    draw.ellipse((cx - r, cy - r, cx + r, cy + r), fill=PETROL)

    # Ring sottile interno per richiamare l'orb respiratorio
    inner_r = size * 0.38
    draw.ellipse(
        (cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r),
        outline=ACCENT,
        width=max(1, int(size * 0.04)),
    )

    # Cuore bianco grande e leggibile anche a 28px (Instinct MIP)
    _draw_heart(draw, cx, cy, radius=size * 0.14, fill=WHITE)

    return img


def save_android_launchers() -> None:
    sizes = {
        "mipmap-mdpi": 48,
        "mipmap-hdpi": 72,
        "mipmap-xhdpi": 96,
        "mipmap-xxhdpi": 144,
        "mipmap-xxxhdpi": 192,
    }
    for folder, sz in sizes.items():
        out_dir = FLUTTER_RES / folder
        out_dir.mkdir(parents=True, exist_ok=True)
        img = make_square(sz, flat_bg=True)
        img.save(out_dir / "ic_launcher.png")

        # Adaptive icon pieces (same mipmap folder)
        bg = make_adaptive_background(sz)
        fg = make_adaptive_foreground(sz)
        bg.save(out_dir / "ic_launcher_background.png")
        fg.save(out_dir / "ic_launcher_foreground.png")

    # Adaptive icon descriptor
    mipmap_anydpi = FLUTTER_RES / "mipmap-anydpi-v26"
    mipmap_anydpi.mkdir(parents=True, exist_ok=True)
    (mipmap_anydpi / "ic_launcher.xml").write_text(
        """<?xml version=\"1.0\" encoding=\"utf-8\"?>
<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">
    <background android:drawable=\"@mipmap/ic_launcher_background\"/>
    <foreground android:drawable=\"@mipmap/ic_launcher_foreground\"/>
</adaptive-icon>
""",
        encoding="utf-8",
    )


def save_ciq_launcher() -> None:
    CIQ_DRAWABLES.mkdir(parents=True, exist_ok=True)
    # Instinct Solar 2X richiede launcher 62x62 secondo compiler.json.
    make_ciq_launcher(62).save(CIQ_DRAWABLES / "launcher_icon.png")


def main() -> None:
    print("Generando launcher Android...")
    save_android_launchers()
    print("Generando launcher CIQ...")
    save_ciq_launcher()
    print("Fatto.")


if __name__ == "__main__":
    main()
