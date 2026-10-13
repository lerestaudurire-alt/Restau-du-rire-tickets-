// Copie le site (../site) vers www/ avant chaque synchronisation Capacitor.
const fs = require("fs"), path = require("path");
const src = path.join(__dirname, "..", "..", "site"), dst = path.join(__dirname, "..", "www");
fs.rmSync(dst, { recursive: true, force: true });
fs.mkdirSync(dst, { recursive: true });
for (const f of fs.readdirSync(src)) {
  if (["robots.txt", "sitemap.xml"].includes(f)) continue; // inutiles dans l'application
  fs.copyFileSync(path.join(src, f), path.join(dst, f));
}
console.log("Site copié dans www/ :", fs.readdirSync(dst).join(", "));
