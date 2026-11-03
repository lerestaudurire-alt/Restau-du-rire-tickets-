// Génère une page par événement + sitemap.xml + robots.txt (pour Google et pour les aperçus de partage).
// Lancé par GitHub Actions : node scripts/build-seo.mjs
import { writeFileSync, mkdirSync, readFileSync, rmSync, existsSync } from "node:fs";
import { createHash } from "node:crypto";

const BASE = process.env.SITE_URL || "https://lerestaudurire-alt.github.io/Restau-du-rire-tickets-/";
const SB = "https://ebzctmnlriumujgygnby.supabase.co";
const KEY = "sb_publishable_53s1YfsfLt3tLHZFKpqd4g_RrWQUlkb";
const NAME = "Le Restau du Rire";
const POSTERS = process.env.POSTERS_URL || `${SB}/storage/v1/object/public/affiches/`;

let sharp = null;
try { sharp = (await import("sharp")).default; } catch { console.log("sharp absent : affiches non redimensionnées"); }

const slugify = t => String(t || "").normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
  .replace(/['’`]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80) || "evenement";
const esc = t => String(t ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const dates = e => (Array.isArray(e.dates) && e.dates.length ? e.dates : [e.starts_at]).filter(Boolean)
  .map(x => new Date(x)).filter(d => !isNaN(d)).sort((a, b) => a - b);

async function load() {
  if (process.env.EVENTS_JSON) return JSON.parse(readFileSync(process.env.EVENTS_JSON, "utf8"));
  const r = await fetch(`${SB}/rest/v1/events?select=*&status=eq.published&order=created_at.asc`,
    { headers: { apikey: KEY, Authorization: "Bearer " + KEY } });
  if (!r.ok) throw new Error("Lecture des événements impossible : HTTP " + r.status);
  return r.json();
}

// Affiche -> image 1200x630 de moins de 300 Ko (WhatsApp ignore les images trop lourdes), affiche entière sur fond flouté.
async function makeOg(e, dest) {
  if (!sharp) return false;
  let buf = null;
  try {
    if (e.poster_path) {
      const u = POSTERS + String(e.poster_path).split("/").map(encodeURIComponent).join("/");
      const r = await fetch(u);
      if (!r.ok) throw new Error("HTTP " + r.status);
      buf = Buffer.from(await r.arrayBuffer());
    } else if (/restau\s+du\s+rire/i.test(e.title || "") && existsSync("affiche.jpg")) {
      buf = readFileSync("affiche.jpg");
    }
    if (!buf) return false;
    const W = 1200, H = 630;
    const bg = await sharp(buf).rotate().resize(W, H, { fit: "cover" }).blur(28).modulate({ brightness: 0.55 }).toBuffer();
    const fg = await sharp(buf).rotate().resize(W, H, { fit: "inside" }).toBuffer();
    let q = 85, out;
    for (;;) {
      out = await sharp(bg).composite([{ input: fg, gravity: "centre" }]).jpeg({ quality: q, mozjpeg: true }).toBuffer();
      if (out.length < 300000 || q <= 55) break; q -= 10;
    }
    writeFileSync(dest, out); return true;
  } catch (x) { console.log("affiche KO :", e.title, "-", x.message); return false; }
}

const events = await load();
const used = {}, list = [];
for (const e of events) {
  const b = slugify(e.title); used[b] = (used[b] || 0) + 1;
  list.push({ e, slug: used[b] > 1 ? `${b}-${used[b]}` : b });   // même règle que l'application
}

if (existsSync("evenement")) rmSync("evenement", { recursive: true });
const urls = [{ loc: BASE, pr: "1.0" }];
const fr = new Intl.DateTimeFormat("fr-FR", { dateStyle: "full", timeStyle: "short", timeZone: "Africa/Lubumbashi" });

for (const { e, slug } of list) {
  const ds = dates(e); if (!ds.length) continue;
  const city = e.city || "Bukavu", venue = e.venue || "", country = e.country || "CD";
  const when = fr.format(ds[0]);
  const title = `${e.title} – Billets | ${new Intl.DateTimeFormat("fr-FR", { day: "numeric", month: "short", year: "numeric", timeZone: "Africa/Lubumbashi" }).format(ds[0])}, ${venue ? venue + " " : ""}${city}`;
  const desc = (`${e.title} : ${when}${venue ? ", " + venue : ""}, ${city}. ` + (e.description || "Réservez vos places en ligne et recevez votre billet numérique avec QR code.")).replace(/\s+/g, " ").slice(0, 158);
  const url = `${BASE}evenement/${slug}/`, app = `${BASE}#event/${slug}`;
  mkdirSync(`evenement/${slug}`, { recursive: true });
  const hasImg = await makeOg(e, `evenement/${slug}/og.jpg`);
  const ver = createHash("md5").update(String(e.poster_path || e.title)).digest("hex").slice(0, 8);
  const img = hasImg ? `${url}og.jpg?v=${ver}` : BASE + "icon-512.png";
  const ld = {
    "@context": "https://schema.org", "@type": "Event", name: e.title, description: desc,
    startDate: ds[0].toISOString(), endDate: ds[ds.length - 1].toISOString(),
    eventStatus: "https://schema.org/EventScheduled",
    eventAttendanceMode: "https://schema.org/OfflineEventAttendanceMode",
    location: { "@type": "Place", name: venue || city, address: { "@type": "PostalAddress", addressLocality: city, addressCountry: country } },
    image: [img], url,
    organizer: { "@type": "Organization", name: e.organizer_name || NAME, url: BASE },
    offers: { "@type": "Offer", url: app, availability: "https://schema.org/InStock", priceCurrency: "CDF" }
  };
  writeFileSync(`evenement/${slug}/index.html`, `<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(title)}</title><meta name="description" content="${esc(desc)}">
<link rel="canonical" href="${url}"><meta name="robots" content="index,follow,max-image-preview:large">
<meta property="og:type" content="website"><meta property="og:site_name" content="${NAME}"><meta property="og:title" content="${esc(e.title)}"><meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${url}"><meta property="og:image" content="${img}">${hasImg ? '<meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">' : ""}<meta property="og:locale" content="fr_FR">
<meta name="twitter:card" content="${hasImg ? "summary_large_image" : "summary"}"><meta name="twitter:title" content="${esc(e.title)}"><meta name="twitter:description" content="${esc(desc)}"><meta name="twitter:image" content="${img}">
<meta name="theme-color" content="#0e2f2b"><link rel="icon" href="${BASE}icon-512.png">
<script type="application/ld+json">${JSON.stringify(ld)}</script>
<style>body{margin:0;font:17px/1.5 system-ui,sans-serif;background:#0e2f2b;color:#f2f7f5;display:grid;place-items:center;min-height:100vh;padding:20px;box-sizing:border-box}
main{max-width:560px}h1{font:900 30px Georgia,serif}.p{width:100%;border-radius:16px;display:block;margin:0 0 14px}a.b{display:inline-block;background:#f4c24d;color:#10201d;font-weight:800;padding:14px 22px;border-radius:14px;text-decoration:none;margin:14px 0}a{color:#7fe0cf}</style></head>
<body><main>${hasImg ? `<img class="p" src="${img}" alt="${esc(e.title)}">` : ""}<p>🎭 ${NAME}</p><h1>${esc(e.title)}</h1>
<p>📅 ${esc(when)}<br>📍 ${esc(venue)}${venue ? ", " : ""}${esc(city)}</p>
${e.description ? `<p>${esc(e.description)}</p>` : ""}
<a class="b" href="${app}">🎟️ Réserver mes places</a>
<p><a href="${BASE}">← Tous les événements</a></p></main></body></html>`);
  urls.push({ loc: url, pr: "0.9", last: (e.updated_at || e.created_at || "").slice(0, 10) });
}

writeFileSync("sitemap.xml", `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n` +
  urls.map(u => `<url><loc>${u.loc}</loc>${u.last ? `<lastmod>${u.last}</lastmod>` : ""}<priority>${u.pr}</priority></url>`).join("\n") + `\n</urlset>\n`);
writeFileSync("robots.txt", `User-agent: *\nAllow: /\nSitemap: ${BASE}sitemap.xml\n`);
console.log(`OK : ${urls.length - 1} page(s) événement + sitemap.xml`);
