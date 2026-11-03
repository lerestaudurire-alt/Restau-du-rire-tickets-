#!/usr/bin/env python3
"""Génère une page d'aperçu par événement : e/<slug>/index.html + og.jpg (affiche).
Les réseaux (WhatsApp, Facebook…) ne lisent jamais ce qui suit le « # » d'un lien :
ils lisent donc cette page, puis les visiteurs sont renvoyés vers l'application."""
import os, re, json, html, shutil, hashlib, unicodedata, urllib.request, urllib.parse, io
from datetime import datetime
from zoneinfo import ZoneInfo
from PIL import Image, ImageFilter, ImageOps

SB   = os.environ.get("SB_URL", "https://ebzctmnlriumujgygnby.supabase.co")
KEY  = os.environ.get("SB_KEY", "sb_publishable_53s1YfsfLt3tLHZFKpqd4g_RrWQUlkb")  # clé publique (déjà dans index.html)
SITE = os.environ.get("SITE", "https://lerestaudurire-alt.github.io/Restau-du-rire-tickets-/").rstrip("/") + "/"
OUT  = os.environ.get("OUT_DIR", "e")
MFN  = os.path.join(OUT, ".manifest.json")

def slugify(t):
    t = unicodedata.normalize("NFD", str(t or ""))
    t = "".join(c for c in t if not unicodedata.combining(c)).lower()
    t = re.sub(r"['’`]", "", t)
    t = re.sub(r"[^a-z0-9]+", "-", t).strip("-")[:80]
    return t or "evenement"

def slugs(events):  # même règle que evSlug() dans index.html
    res = {}
    for e in events:
        b = slugify(e["title"])
        same = sorted([x for x in events if slugify(x["title"]) == b],
                      key=lambda x: str(x.get("created_at") or x["id"]))
        i = next(k for k, x in enumerate(same) if x["id"] == e["id"])
        res[e["id"]] = b + "-" + str(i + 1) if i > 0 else b
    return res

def get(url, binary=False):
    r = urllib.request.Request(url, headers={"apikey": KEY, "Authorization": "Bearer " + KEY, "User-Agent": "lrr-pages"})
    with urllib.request.urlopen(r, timeout=40) as f:
        d = f.read()
    return d if binary else json.loads(d)

def load_events():
    return get(SB + "/rest/v1/events?select=id,title,description,starts_at,venue,city,poster_path,created_at"
                    "&status=eq.published&order=created_at")

MOIS = "janvier février mars avril mai juin juillet août septembre octobre novembre décembre".split()
JOURS = "lundi mardi mercredi jeudi vendredi samedi dimanche".split()
def fdate(iso):
    try:
        d = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(ZoneInfo("Africa/Lubumbashi"))
        return f"{JOURS[d.weekday()]} {d.day} {MOIS[d.month-1]} {d.year}"
    except Exception:
        return ""

def og_image(raw, dest):
    """Affiche → 1200×630 JPEG léger (< 300 Ko), affiche entière visible sur fond flouté."""
    im = ImageOps.exif_transpose(Image.open(io.BytesIO(raw))).convert("RGB")
    W, H = 1200, 630
    bg = ImageOps.fit(im, (W, H), Image.LANCZOS).filter(ImageFilter.GaussianBlur(28))
    bg = Image.eval(bg, lambda v: int(v * 0.55))
    fg = ImageOps.contain(im, (W, H), Image.LANCZOS)
    bg.paste(fg, ((W - fg.width) // 2, (H - fg.height) // 2))
    q = 86
    while True:
        buf = io.BytesIO(); bg.save(buf, "JPEG", quality=q, optimize=True, progressive=True)
        if buf.tell() < 300_000 or q <= 55: break
        q -= 8
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest, "wb").write(buf.getvalue())

PAGE = """<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{t}</title><meta name="description" content="{d}">
<link rel="canonical" href="{u}">
<meta property="og:type" content="website"><meta property="og:locale" content="fr_FR">
<meta property="og:site_name" content="Le Restau du Rire Tickets">
<meta property="og:title" content="{t}"><meta property="og:description" content="{d}">
<meta property="og:url" content="{u}"><meta property="og:image" content="{img}">
<meta property="og:image:width" content="{w}"><meta property="og:image:height" content="{h}">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="{t}">
<meta name="twitter:description" content="{d}"><meta name="twitter:image" content="{img}">
<meta name="robots" content="index,follow,max-image-preview:large">
<meta name="theme-color" content="#0e2f2b">
<noscript><meta http-equiv="refresh" content="0;url=../../#event/{s}"></noscript>
<script>var b=location.pathname.replace(/e\\/[^\\/]*\\/?$/,"");location.replace(b+location.search+"#event/{s}")</script>
</head><body style="font-family:system-ui,sans-serif;text-align:center;padding:40px;background:#0e2f2b;color:#fff">
<p>Ouverture de l’événement…</p><p><a style="color:#ffc83d" href="../../#event/{s}">Ouvrir {t_h}</a></p></body></html>"""

def build(events, fetch=lambda u: get(u, True), root="."):
    sl = slugs(events)
    man = {}
    try: man = json.load(open(MFN))
    except Exception: pass
    new = {}
    os.makedirs(OUT, exist_ok=True)
    for e in events:
        s = sl[e["id"]]; d = os.path.join(OUT, s)
        title = e["title"].strip()
        src = None
        if e.get("poster_path"):
            src = SB + "/storage/v1/object/public/affiches/" + urllib.parse.quote(e["poster_path"])
        elif re.search(r"restau\s+du\s+rire", title, re.I) and os.path.exists(os.path.join(root, "affiche.jpg")):
            src = "file:affiche.jpg"
        key = hashlib.md5(json.dumps([src, title, e.get("description"), e.get("starts_at"), e.get("venue"), e.get("city")]).encode()).hexdigest()
        has_img = os.path.exists(os.path.join(d, "og.jpg"))
        if man.get(s, {}).get("k") == key and os.path.exists(os.path.join(d, "index.html")):
            new[s] = man[s]; continue
        ver = key[:8]; img = SITE + "icon-512.png"; w = h = 512
        if src:
            try:
                raw = open(os.path.join(root, "affiche.jpg"), "rb").read() if src == "file:affiche.jpg" else fetch(src)
                og_image(raw, os.path.join(d, "og.jpg"))
                img = f"{SITE}e/{s}/og.jpg?v={ver}"; w, h = 1200, 630
            except Exception as ex:
                print("affiche KO", s, ex)
        when = fdate(e.get("starts_at") or ""); where = ", ".join(x for x in [e.get("venue"), e.get("city")] if x)
        desc = " · ".join(x for x in [when, where] if x)
        desc = (desc + " — " if desc else "") + "Réservez votre place en ligne."
        extra = re.sub(r"\s+", " ", e.get("description") or "").strip()
        if extra: desc = (desc + " " + extra)[:200]
        os.makedirs(d, exist_ok=True)
        q = lambda v: html.escape(v, quote=True)
        open(os.path.join(d, "index.html"), "w", encoding="utf-8").write(PAGE.format(
            t=q(title), t_h=q(title), d=q(desc), u=f"{SITE}e/{s}/", img=q(img), w=w, h=h, s=s))
        new[s] = {"k": key}; print("page", s, "(affiche)" if w == 1200 else "(logo)")
    for n in os.listdir(OUT):  # événements dépubliés
        if n not in new and os.path.isdir(os.path.join(OUT, n)):
            shutil.rmtree(os.path.join(OUT, n)); print("supprimé", n)
    json.dump(new, open(MFN, "w"), indent=0)

if __name__ == "__main__":
    build(load_events())
