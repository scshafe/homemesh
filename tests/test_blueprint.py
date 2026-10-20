import io
import os
import tempfile
import unittest

from fastapi.testclient import TestClient
from PIL import Image

from homemesh import api, blueprint, fixtures, seed, store
from homemesh.model import Underlay


def png_bytes(size=(200, 100), color=(255, 255, 255)) -> bytes:
    out = io.BytesIO()
    Image.new("RGB", size, color).save(out, format="PNG")
    return out.getvalue()


def jpeg_with_exif() -> bytes:
    im = Image.new("RGB", (64, 48), (200, 10, 10))
    exif = Image.Exif()
    exif[0x010E] = "SECRET DESCRIPTION"  # ImageDescription
    out = io.BytesIO()
    im.save(out, format="JPEG", exif=exif)
    return out.getvalue()


def pdf_bytes(pages=2) -> bytes:
    ims = [Image.new("RGB", (300, 400), (255, 255, 255)) for _ in range(pages)]
    out = io.BytesIO()
    ims[0].save(out, format="PDF", save_all=True, append_images=ims[1:])
    return out.getvalue()


class PagesTest(unittest.TestCase):
    def test_png_roundtrip(self):
        (p,) = blueprint.pages(png_bytes())
        self.assertEqual((p.width, p.height), (200, 100))
        self.assertEqual(p.png[:4], b"\x89PNG")

    def test_metadata_stripped(self):
        raw = jpeg_with_exif()
        self.assertIn(b"SECRET DESCRIPTION", raw)
        (p,) = blueprint.pages(raw)
        self.assertNotIn(b"SECRET DESCRIPTION", p.png)
        self.assertEqual(len(Image.open(io.BytesIO(p.png)).getexif()), 0)

    def test_large_image_downscaled(self):
        (p,) = blueprint.pages(png_bytes((7000, 100)))
        self.assertEqual(p.width, blueprint.MAX_SIDE)

    def test_pdf_pages(self):
        ps = blueprint.pages(pdf_bytes(2))
        self.assertEqual(len(ps), 2)
        self.assertGreater(ps[0].height, ps[0].width)

    def test_garbage_rejected(self):
        for bad in (b"", b"hello", b"%PDF-1.4 not really", b"\x89PNG\r\n\x1a\n" + b"x" * 20):
            with self.assertRaises(blueprint.BlueprintError):
                blueprint.pages(bad)

    def test_too_large(self):
        with self.assertRaises(blueprint.BlueprintError):
            blueprint.pages(b"0" * (blueprint.MAX_BYTES + 1))


class UnderlayModelTest(unittest.TestCase):
    def test_validation(self):
        good = dict(id="u1", level="L0", blob="a" * 64, width_px=10, height_px=10, scale=0.01)
        Underlay(**good)
        for patch in ({"blob": "../x"}, {"scale": 0}, {"opacity": 2}, {"width_px": 0}):
            with self.assertRaises(ValueError):
                Underlay(**{**good, **patch})

    def test_unknown_level_reported(self):
        h = fixtures.long_thin()
        h.underlays.append(Underlay(id="u1", level="nope", blob="a" * 64, width_px=1, height_px=1, scale=1))
        self.assertTrue(any("underlay u1: unknown level" in e for e in h.validate_refs()))


class ApiBlueprintTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self._env = {k: os.environ.get(k) for k in (store.ENV, api.AUTH_HEADER, api.DEV, api.WEB_DIST)}
        os.environ[store.ENV] = self._tmp.name
        os.environ[api.AUTH_HEADER] = "X-Door-User"
        os.environ.pop(api.DEV, None)
        os.environ[api.WEB_DIST] = os.path.join(self._tmp.name, "none")
        seed.main()
        self.c = TestClient(api.create_app())
        self.ok = {"X-Door-User": "o"}

    def tearDown(self):
        for k, v in self._env.items():
            os.environ.pop(k, None) if v is None else os.environ.__setitem__(k, v)
        self._tmp.cleanup()

    def test_upload_and_fetch(self):
        r = self.c.post("/api/houses/synthetic-box/blueprints", content=png_bytes(), headers=self.ok)
        self.assertEqual(r.status_code, 200)
        (page,) = r.json()
        g = self.c.get(f"/api/houses/synthetic-box/blobs/{page['blob']}", headers=self.ok)
        self.assertEqual((g.status_code, g.headers["content-type"], g.headers["x-content-type-options"]), (200, "image/png", "nosniff"))

    def test_pdf_returns_pages(self):
        r = self.c.post("/api/houses/synthetic-box/blueprints", content=pdf_bytes(2), headers=self.ok)
        self.assertEqual(len(r.json()), 2)

    def test_errors_and_auth(self):
        u = "/api/houses/synthetic-box/blueprints"
        self.assertEqual(self.c.post(u, content=b"junk", headers=self.ok).status_code, 422)
        self.assertEqual(self.c.post(u, content=png_bytes()).status_code, 401)
        self.assertEqual(self.c.post("/api/houses/nope/blueprints", content=png_bytes(), headers=self.ok).status_code, 404)
        self.assertEqual(self.c.get("/api/houses/synthetic-box/blobs/" + "0" * 64, headers=self.ok).status_code, 404)
        self.assertEqual(self.c.get("/api/houses/synthetic-box/blobs/..%2Fhouse.json", headers=self.ok).status_code, 404)

    def test_non_png_blob_served_as_attachment(self):
        d = store.put_blob("synthetic-box", b"<html>hi</html>")
        g = self.c.get(f"/api/houses/synthetic-box/blobs/{d}", headers=self.ok)
        self.assertEqual(g.headers["content-type"], "application/octet-stream")
        self.assertIn("attachment", g.headers["content-disposition"])


if __name__ == "__main__":
    unittest.main()
