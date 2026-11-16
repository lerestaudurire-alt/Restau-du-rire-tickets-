// Génère une vraie page de partage par événement : evenement/<nom>/index.html
// -> Facebook, WhatsApp, Telegram, X… lisent ces pages (ils n'exécutent pas le JavaScript de l'app).
// Chaque page contient : titre, description (date · lieu · prix) et une image 1200x630 avec l'affiche.
// Les personnes qui cliquent sont aussitôt renvoyées vers l'app : <site>#event/<nom>
import fs from "node:fs/promises";
import fsSync from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import sharp from "sharp";

const SITE = (process.env.SITE_URL || "https://lerestaudurire-alt.github.io/Restau-du-rire-tickets-/").replace(/\/?$/, "/");
const SB = process.env.SUPABASE_URL || "https://ebzctmnlriumujgygnby.supabase.co";
const KEY = process.env.SUPABASE_KEY || "sb_publishable_53s1YfsfLt3tLHZFKpqd4g_RrWQUlkb"; // clé publique, déjà présente dans index.html
const BRAND = "Le Restau du Rire";
const OUT = "evenement";
const TZ = { CD: "Africa/Lubumbashi", CI: "Africa/Abidjan", FR: "Europe/Paris", SN: "Africa/Dakar", BJ: "Africa/Porto-Novo" };
const FONT = "DejaVu Sans, Liberation Sans, Arial, sans-serif";

// Carte du site entier (lien de la page d'accueil)
const SITE_CARD = {
  title: "Le Restau du Rire",
  line1: "Édition 1.5 — En attendant 2",
  line2: "27 décembre 2026 · Salle Concordia, Bukavu",
  line3: "Billets en ligne · QR code · Mobile Money",
};

/* --- mêmes règles que l'app (index.html) pour que les liens correspondent --- */
const slugify = t => String(t || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().replace(/['’`]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "evenement";
function evSlug(e, list) {
  const b = slugify(e.title);
  const same = list.filter(x => slugify(x.title) === b).sort((a, c) => String(a.created_at || a.id).localeCompare(String(c.created_at || c.id)));
  const i = same.findIndex(x => x.id === e.id);
  return i > 0 ? b + "-" + (i + 1) : b;
}

const xml = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const cut = (s, n) => { s = String(s || "").replace(/\s+/g, " ").trim(); return s.length > n ? s.slice(0, n - 1).trimEnd() + "…" : s; };
const nf = n => new Intl.NumberFormat("fr-FR").format(n).replace(/\u202f|\u00a0/g, " ");

function evDates(e) {
  let l = Array.isArray(e.dates) ? e.dates.filter(Boolean) : [];
  if (!l.length && e.starts_at) l = [e.starts_at];
  return l.map(x => new Date(x)).filter(d => !isNaN(d)).sort((a, b) => a - b);
}
function whenText(e) {
  const L = evDates(e); if (!L.length) return { day: "", time: "", more: 0 };
  const tz = e.timezone || TZ[e.country] || "Africa/Lubumbashi", d = L[0];
  let day = d.toLocaleDateString("fr-FR", { weekday: "long", day: "numeric", month: "long", year: "numeric", timeZone: tz });
  day = day.charAt(0).toUpperCase() + day.slice(1);
  const time = d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit", timeZone: tz }).replace(":", "h");
  return { day, time, more: L.length - 1 };
}
function priceText(e) {
  const T = (Array.isArray(e.tickets) ? e.tickets : []).filter(t => +t.price >= 0);
  if (!T.length) return "";
  const m = T.slice().sort((a, b) => a.price - b.price)[0];
  return m.price > 0 ? "Dès " + nf(m.price) + (m.currency === "USD" ? " $" : m.currency && !/^(FC|CDF)$/i.test(m.currency) ? " " + m.currency : " FC") : "Gratuit";
}
const placeText = e => [e.venue, e.city].filter(Boolean).join(", ");

/* --- image 1200x630 --- */
function wrap(text, size, maxW, maxLines) {
  const cw = size * 0.6, per = Math.max(6, Math.floor(maxW / cw)), words = String(text).split(/\s+/), lines = [];
  let cur = "";
  for (const w of words) {
    if ((cur + " " + w).trim().length <= per) cur = (cur + " " + w).trim();
    else { if (cur) lines.push(cur); cur = w.length > per ? w.slice(0, per - 1) + "…" : w; }
  }
  if (cur) lines.push(cur);
  if (lines.length > maxLines) { lines.length = maxLines; lines[maxLines - 1] = lines[maxLines - 1].replace(/\s*\S{0,3}$/, "") + "…"; }
  return lines;
}
async function getBuf(url) {
  const r = await fetch(url); if (!r.ok) throw new Error("HTTP " + r.status + " " + url);
  return Buffer.from(await r.arrayBuffer());
}
async function makeOg({ poster, title, l1, l2, l3, file }) {
  const W = 1200, H = 630;
  let base, layers = [], px = 60, pw = 0;
  const bgSolid = { create: { width: W, height: H, channels: 3, background: "#0e2f2b" } };
  let meta = null;
  if (poster) { try { meta = await sharp(poster).metadata(); } catch { poster = null; } }
  if (poster) {
    base = await sharp(poster).resize(W, H, { fit: "cover" }).blur(38).modulate({ brightness: 0.42 }).jpeg().toBuffer();
  } else base = await sharp(bgSolid).jpeg().toBuffer();
  const ratio = meta ? meta.width / meta.height : 0;
  if (poster && ratio >= 1.45) {
    // affiche en paysage : elle occupe toute l'image, texte en bandeau bas
    const full = await sharp(poster).resize(W, H, { fit: "cover" }).jpeg().toBuffer();
    const band = `<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset=".55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".82"/></linearGradient></defs><rect width="${W}" height="${H}" fill="url(#g)"/>
      <text x="48" y="540" font-family="${FONT}" font-weight="700" font-size="46" fill="#fff">${xml(cut(title, 48))}</text>
      <text x="48" y="590" font-family="${FONT}" font-size="30" fill="#ffd9c2">${xml(cut([l1, l2].filter(Boolean).join("  ·  "), 70))}</text></svg>`;
    await sharp(full).composite([{ input: Buffer.from(band) }]).jpeg({ quality: 86 }).toFile(file);
    return;
  }
  if (poster) {
    const bh = 570, bw = Math.min(470, Math.round(bh * Math.max(ratio, 0.5)));
    const img = await sharp(poster).resize(bw, bh, { fit: "inside" }).toBuffer();
    const m2 = await sharp(img).metadata(); pw = m2.width;
    const mask = Buffer.from(`<svg width="${m2.width}" height="${m2.height}"><rect width="${m2.width}" height="${m2.height}" rx="22" fill="#fff"/></svg>`);
    const rounded = await sharp(img).composite([{ input: mask, blend: "dest-in" }]).png().toBuffer();
    const shadow = Buffer.from(`<svg width="${m2.width + 40}" height="${m2.height + 40}"><rect x="20" y="26" width="${m2.width}" height="${m2.height}" rx="22" fill="#000" opacity=".55"/></svg>`);
    const shadowB = await sharp(shadow).blur(14).png().toBuffer();
    const top = Math.round((H - m2.height) / 2);
    layers.push({ input: shadowB, left: px - 20, top: top - 20 }, { input: rounded, left: px, top });
  }
  const tx = poster ? px + pw + 56 : 90, tw = W - tx - 60;
  const tl = wrap(title, 50, tw, 3);
  let y = 130; const out = [];
  out.push(`<text x="${tx}" y="${y - 52}" font-family="${FONT}" font-weight="700" font-size="22" letter-spacing="3" fill="#ffc83d">${xml(BRAND.toUpperCase())}</text>`);
  tl.forEach((t, i) => out.push(`<text x="${tx}" y="${y + 20 + i * 60}" font-family="${FONT}" font-weight="700" font-size="50" fill="#fff">${xml(t)}</text>`));
  y = y + 20 + tl.length * 60 + 14;
  const per = Math.max(10, Math.floor(tw / (28 * 0.6)));
  [l1, l2, l3].filter(Boolean).forEach((t, i) => {
    out.push(`<text x="${tx}" y="${y}" font-family="${FONT}" font-size="28" fill="${i === 0 ? "#ffffff" : "#d9ece8"}">${xml(cut(t, per))}</text>`); y += 42;
  });
  const by = H - 92;
  out.push(`<rect x="${tx}" y="${by}" width="330" height="58" rx="29" fill="#ff6b1a"/><text x="${tx + 165}" y="${by + 38}" text-anchor="middle" font-family="${FONT}" font-weight="700" font-size="26" fill="#fff">Réserver mon billet</text>`);
  layers.push({ input: Buffer.from(`<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">${out.join("")}</svg>`) });
  await sharp(base).composite(layers).jpeg({ quality: 86 }).toFile(file);
}

/* --- page HTML de partage --- */
function pageHtml(e, info) {
  const url = SITE + OUT + "/" + info.slug + "/", app = SITE + "#event/" + info.slug, img = url + "og.jpg?v=" + info.sig;
  const ttl = cut(e.title, 90), ogTitle = cut(e.title + (info.when.day ? " — " + info.when.day : ""), 100);
  const L = evDates(e);
  const ld = {
    "@context": "https://schema.org", "@type": "Event", name: e.title, description: info.desc,
    startDate: L[0] ? L[0].toISOString() : undefined, eventStatus: "https://schema.org/EventScheduled",
    eventAttendanceMode: "https://schema.org/OfflineEventAttendanceMode",
    location: { "@type": "Place", name: e.venue || e.city || "", address: { "@type": "PostalAddress", addressLocality: e.city || "", addressCountry: e.country || "" } },
    image: [img], url, organizer: { "@type": "Organization", name: e.organizer_name || BRAND, url: SITE },
  };
  return `<!DOCTYPE html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${xml(ttl)} — ${BRAND}</title>
<meta name="description" content="${xml(info.desc)}">
<link rel="canonical" href="${url}">
<meta property="og:type" content="website"><meta property="og:locale" content="fr_FR"><meta property="og:site_name" content="${BRAND}">
<meta property="og:title" content="${xml(ogTitle)}"><meta property="og:description" content="${xml(info.desc)}">
<meta property="og:url" content="${url}"><meta property="og:image" content="${img}"><meta property="og:image:secure_url" content="${img}">
<meta property="og:image:type" content="image/jpeg"><meta property="og:image:width" content="1200"><meta property="og:image:height" content="630"><meta property="og:image:alt" content="${xml(ttl)}">
<meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${xml(ogTitle)}"><meta name="twitter:description" content="${xml(info.desc)}"><meta name="twitter:image" content="${img}">
<meta name="theme-color" content="#0e2f2b"><link rel="icon" href="../../icon-192.png">
<script type="application/ld+json">${JSON.stringify(ld).replace(/</g, "\\u003c")}</script>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#0e2f2b;color:#fff;font-family:Arial,sans-serif;text-align:center;padding:20px}
.c{max-width:420px}img{width:100%;border-radius:18px;display:block;margin:0 auto 16px}h1{font-size:22px;margin:0 0 8px}p{margin:4px 0;color:#d9ece8}
a{display:inline-block;margin-top:16px;background:#ff6b1a;color:#fff;text-decoration:none;font-weight:700;padding:14px 26px;border-radius:30px}</style>
<script>location.replace(${JSON.stringify(app)})</script></head>
<body><div class="c"><img src="og.jpg?v=${info.sig}" alt="${xml(ttl)}"><h1>${xml(e.title)}</h1>
${info.when.day ? `<p>${xml(info.when.day)}${info.when.time ? " · " + xml(info.when.time) : ""}</p>` : ""}${placeText(e) ? `<p>${xml(placeText(e))}</p>` : ""}${info.price ? `<p>${xml(info.price)}</p>` : ""}
<a href="${app}">Réserver mon billet</a><noscript><p>Ouvrez ${xml(app)}</p></noscript></div></body></html>
`;
}

/* --- principal --- */
async function main() {
  const r = await fetch(SB + "/rest/v1/events?select=*&status=eq.published&order=created_at", { headers: { apikey: KEY, Authorization: "Bearer " + KEY } });
  if (!r.ok) throw new Error("Supabase HTTP " + r.status);
  const list = await r.json();
  if (!Array.isArray(list)) throw new Error("Réponse inattendue");

  await fs.mkdir(OUT, { recursive: true });
  const mf = path.join(OUT, "manifest.json");
  let old = {}; try { old = JSON.parse(await fs.readFile(mf, "utf8")); } catch {}
  const now = {}; let made = 0;

  for (const e of list) {
    if (!e || !e.title) continue;
    const slug = evSlug(e, list), dir = path.join(OUT, slug);
    const when = whenText(e), price = priceText(e);
    const desc = cut([[when.day, when.time ? "à " + when.time : ""].filter(Boolean).join(" "), placeText(e), price].filter(Boolean).join(" · ") + " — Réservez votre billet en ligne.", 200);
    const posterUrl = e.poster_path ? SB + "/storage/v1/object/public/affiches/" + e.poster_path : (/restau\s+du\s+rire/i.test(e.title) && fsSync.existsSync("affiche.jpg") ? "affiche.jpg" : "");
    const sig = crypto.createHash("sha1").update(JSON.stringify([e.title, e.poster_path, when, price, placeText(e), e.updated_at || ""])).digest("hex").slice(0, 10);
    now[slug] = sig;
    await fs.mkdir(dir, { recursive: true });
    const og = path.join(dir, "og.jpg");
    if (old[slug] !== sig || !fsSync.existsSync(og)) {
      let poster = null;
      try { poster = posterUrl ? (/^https?:/.test(posterUrl) ? await getBuf(posterUrl) : await fs.readFile(posterUrl)) : null; } catch (x) { console.warn("Affiche indisponible pour", slug, x.message); }
      if (!poster && fsSync.existsSync("icon-512.png")) poster = await fs.readFile("icon-512.png");
      await makeOg({ poster, title: e.title, l1: [when.day, when.time].filter(Boolean).join(" · "), l2: placeText(e), l3: price, file: og });
      made++;
    }
    await fs.writeFile(path.join(dir, "index.html"), pageHtml(e, { slug, sig, when, price, desc }));
  }

  if (list.length) for (const s of Object.keys(old)) if (!now[s]) await fs.rm(path.join(OUT, s), { recursive: true, force: true });
  if (list.length) await fs.writeFile(mf, JSON.stringify(now, null, 1));
  await fs.writeFile(path.join(OUT, "index.html"), `<!DOCTYPE html><meta charset="utf-8"><script>location.replace(${JSON.stringify(SITE)})</script><a href="${SITE}">${BRAND}</a>`);

  // image de la page d'accueil
  const siteSrc = ["affiche.jpg", "icon-512.png"].find(f => fsSync.existsSync(f));
  const sig = crypto.createHash("sha1").update(JSON.stringify([SITE_CARD, siteSrc, siteSrc ? fsSync.statSync(siteSrc).size : 0])).digest("hex").slice(0, 10);
  let osig = ""; try { osig = fsSync.readFileSync("og-site.sig", "utf8"); } catch {}
  if (osig !== sig || !fsSync.existsSync("og-site.jpg")) {
    await makeOg({ poster: siteSrc ? await fs.readFile(siteSrc) : null, title: SITE_CARD.title, l1: SITE_CARD.line1, l2: SITE_CARD.line2, l3: SITE_CARD.line3, file: "og-site.jpg" });
    await fs.writeFile("og-site.sig", sig); made++;
  }
  console.log(`OK — ${list.length} événement(s), ${made} image(s) (re)générée(s).`);
}
main().catch(e => { console.error("ÉCHEC :", e.message); process.exit(1); });
