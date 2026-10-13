# Restau du Rire Tickets — Web, Play Store et App Store

Trois versions, UN SEUL code (le dossier `../site`) :
1. **Application web (PWA)** : publiez le dossier `site/` sur GitHub / Netlify. Rien d'autre.
2. **Android (Play Store)** : ce dossier, avec Capacitor.
3. **iPhone (App Store)** : ce dossier, avec Capacitor + un Mac (Xcode).

## 0. Une seule fois
Installez Node.js 18+ (nodejs.org). Pour Android : Android Studio. Pour iPhone : un Mac avec Xcode.

## 1. Android — dans le Terminal (dans le dossier capacitor-app)
```
npm install
npm run web
npx cap add android
npx cap sync android
node scripts/harden-android.js
npx cap open android
```
(`npx cap add android` crée le dossier android/ ; `npx cap sync android` y copie le site.)

Dans Android Studio : **Build > Generate Signed App Bundle > Android App Bundle (.aab)**.
Créez une clé de signature (fichier .jks) et SAUVEGARDEZ-LA avec son mot de passe : sans elle, vous ne pourrez plus mettre l'application à jour.
Envoyez le fichier .aab dans la Google Play Console (compte développeur : 25 $ une seule fois).

Avant chaque nouvelle version : augmentez `versionCode` et `versionName` dans `android/app/build.gradle`, puis `npm run android`.

## 2. iPhone / iPad
```
npm install
npm run web
npx cap add ios
npx cap sync ios
npx cap open ios
```
Dans Xcode : choisissez votre équipe (compte Apple Developer : 99 $/an), puis **Product > Archive > Distribute App > App Store Connect**.
Dans `ios/App/App/Info.plist`, ajoutez : `NSCameraUsageDescription` = « La caméra sert à scanner les billets (QR code). »

## 3. Icône et écran de démarrage
Icône source : `../site/icon-512.png`. Générez toutes les tailles avec :
```
npm install -D @capacitor/assets
npx capacitor-assets generate
```
(placez icon-only.png 1024x1024 et splash.png 2732x2732 dans un dossier `assets/`).

## 4. Fiche Play Store / App Store (à préparer)
- Nom : Restau du Rire — Tickets · Identifiant : com.restaudurire.tickets
- Politique de confidentialité : une page publique est OBLIGATOIRE (reprenez le texte « Vos données personnelles » de l'app et publiez-le sur une adresse web).
- Captures d'écran (téléphone), icône 512x512, bannière 1024x500, description courte et longue.
- Questionnaire « Sécurité des données » : nom, téléphone, e-mail, photos de paiement, collectés pour la billetterie.
- Apple exige un mode d'achat conforme : les billets d'événements réels peuvent être réglés hors App Store (Mobile Money / carte), mais vérifiez la règle 3.1.3(e) au moment du dépôt.

## Taille de l'application
L'application complète pèse environ 3 à 5 Mo. C'est normal et c'est un avantage (téléchargement rapide, même en 3G). Il n'est ni utile ni recommandé de la gonfler à 50 Mo : Google et Apple n'exigent aucune taille minimale.

## Sécurité incluse
- HTTPS uniquement (pas de trafic non chiffré), sauvegarde cloud Android désactivée, débogage web désactivé.
- Politique CSP dans index.html : seuls Supabase, cdnjs et SimplyPaye sont autorisés.
- Fonction serveur : origines autorisées limitées (site + application), limitation de débit, taille de requête plafonnée.
- Base : RLS active, noms de vendeurs nettoyés côté base, rapport par vendeur réservé à l'admin et au propriétaire.
