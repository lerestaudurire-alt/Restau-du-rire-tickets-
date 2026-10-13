// Durcit le projet Android genere par "npx cap add android" : pas de sauvegarde cloud des donnees,
// pas de trafic non chiffre, permission camera (scan QR). Relancable sans risque.
const fs = require("fs"), path = require("path");
const f = path.join(__dirname, "..", "android", "app", "src", "main", "AndroidManifest.xml");
if (!fs.existsSync(f)) { console.log("Projet Android absent : lancez d'abord  npx cap add android"); process.exit(0); }
let x = fs.readFileSync(f, "utf8");
const set = (attr, val) => { x = new RegExp(attr + '="[^"]*"').test(x) ? x.replace(new RegExp(attr + '="[^"]*"'), attr + '="' + val + '"') : x.replace("<application", "<application " + attr + '="' + val + '"'); };
set("android:allowBackup", "false");
set("android:usesCleartextTraffic", "false");
if (!x.includes("android.permission.CAMERA")) x = x.replace("</manifest>", '    <uses-permission android:name="android.permission.CAMERA" />\n    <uses-feature android:name="android.hardware.camera" android:required="false" />\n</manifest>');
fs.writeFileSync(f, x);
console.log("AndroidManifest.xml durci.");
