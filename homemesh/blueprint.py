"""Blueprint upload: image or PDF to normalised PNG pages (design section 11).

Every upload is decoded and re-encoded as PNG, which drops EXIF/GPS and any
other embedded metadata, and bounds the size. PDFs are rasterised one page per
image. Uploads are the owner's own files, but they are still parsed with
bounded limits: pixel count, page count, byte count.
"""

from __future__ import annotations

import io
from dataclasses import dataclass

from PIL import Image, UnidentifiedImageError

MAX_BYTES = 40 * 1024 * 1024
MAX_SIDE = 6000  # px, after downscaling
MAX_PAGES = 20
PDF_DPI = 150

Image.MAX_IMAGE_PIXELS = 120_000_000  # decompression-bomb guard (Pillow raises above 2x)


class BlueprintError(ValueError):
    pass


@dataclass(frozen=True)
class Page:
    png: bytes
    width: int
    height: int


def _png(img: Image.Image) -> Page:
    img = img.convert("RGB") if img.mode not in ("RGB", "L") else img
    if max(img.size) > MAX_SIDE:
        img.thumbnail((MAX_SIDE, MAX_SIDE), Image.LANCZOS)
    out = io.BytesIO()
    img.save(out, format="PNG")  # no exif, no text chunks
    return Page(out.getvalue(), img.width, img.height)


def pages(data: bytes) -> list[Page]:
    if len(data) > MAX_BYTES:
        raise BlueprintError("file too large")
    if data[:5] == b"%PDF-":
        return _pdf(data)
    try:
        with Image.open(io.BytesIO(data)) as im:
            if im.format not in ("PNG", "JPEG", "TIFF", "BMP", "WEBP", "MPO"):
                raise BlueprintError("unsupported image type")
            im.load()
            return [_png(im)]
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError) as e:
        raise BlueprintError("not a readable image") from e


def _pdf(data: bytes) -> list[Page]:
    import pypdfium2 as pdfium

    try:
        doc = pdfium.PdfDocument(data)
    except Exception as e:  # pdfium raises its own PdfiumError
        raise BlueprintError("not a readable PDF") from e
    try:
        n = len(doc)
        if n == 0 or n > MAX_PAGES:
            raise BlueprintError(f"PDF must have 1 to {MAX_PAGES} pages")
        out = []
        for i in range(n):
            page = doc[i]
            w, h = page.get_size()  # points
            scale = PDF_DPI / 72.0
            if max(w, h) * scale > MAX_SIDE:
                scale = MAX_SIDE / max(w, h)
            out.append(_png(page.render(scale=scale).to_pil()))
        return out
    finally:
        doc.close()
