# Hub Apple

Applications Apple JP2 Création branchees au HUB.

Ce depot contient le developpement iPhone, iPad et macOS de l'app JP2 Création. Le code metier reste dans le HUB Laravel et l'app charge l'adresse configuree localement via WebView.

L'URL du HUB ne doit pas etre publiee dans le depot. Pour brancher l'app sur une installation, copier `.env.example` vers `.env`, puis renseigner `VITE_CRM_URL` avec l'adresse de l'installation HUB. Le build macOS lit aussi `JP2_HUB_URL`; s'il n'est pas defini, il reutilise `VITE_CRM_URL`.

## Contenu

- `src/` : ecran d'ouverture et handoff vers le HUB.
- `ios/App/App/` : app iPhone/iPad Capacitor avec pont natif JP2 Création.
- `ios/App/MacApp/` : app macOS native WebKit avec pont natif JP2 Création.
- `releases/jp2-creation-update.json` : manifest de mise a jour Apple.
- `scripts/` : scripts de build iPhone/iPad et paquet macOS.

## Installation dev

```bash
npm install
cp .env.example .env
```

Dans `.env`, renseigner l'URL HTTPS du HUB installe, sans ajouter de chemin special. L'app ajoutera automatiquement les parametres mobiles necessaires.

## iPhone / iPad

```bash
npm run ios:prepare
npm run cap:open:ios
```

La cible iOS universelle prend en charge iPhone et iPad.

## macOS

Construire l'app macOS :

```bash
npm run mac:build
```

Generer le paquet installable dans `/Applications` :

```bash
npm run mac:pkg
```

Le paquet est genere dans `build/JP2-Creation-Mac-Installer-<version>.pkg`.

## Releases

Les apps Apple lisent le manifest suivant :

```text
https://raw.githubusercontent.com/jp2creation/hub_apple/main/releases/jp2-creation-update.json
```

Le tag recommande pour un paquet Mac est :

```text
jp2-creation-mac-v<version>
```

## Licence

Cette application fait partie de JP2 Création et suit la licence du depot. Toute compilation, distribution, installation client, exploitation professionnelle, revente ou publication d'un paquet iOS/macOS demande l'accord ecrit prealable de JP2 Création.
