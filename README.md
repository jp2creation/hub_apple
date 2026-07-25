# Hub Apple

Applications Apple Martin Sols branchees au HUB JP2.

Ce depot contient le developpement iPhone, iPad et macOS de l'app Martin Sols. Le code metier reste dans le HUB Laravel et l'app charge le HUB via WebView :

```text
https://crm.jp2.fr
```

## Contenu

- `src/` : ecran d'ouverture et handoff vers le HUB.
- `ios/App/App/` : app iPhone/iPad Capacitor avec pont natif Martin Sols.
- `ios/App/MacApp/` : app macOS native WebKit avec pont natif Martin Sols.
- `releases/martin-sols-update.json` : manifest de mise a jour Apple.
- `scripts/` : scripts de build iPhone/iPad et paquet macOS.

## Installation dev

```bash
npm install
```

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

Le paquet est genere dans `build/Martin-Sols-Mac-Installer-<version>.pkg`.

## Releases

Les apps Apple lisent le manifest suivant :

```text
https://raw.githubusercontent.com/jp2creation/hub_apple/main/releases/martin-sols-update.json
```

Le tag recommande pour un paquet Mac est :

```text
martin-sols-mac-v<version>
```

## Licence

Cette application fait partie de JP2 Hub et suit la licence du depot. Toute compilation, distribution, installation client, exploitation professionnelle, revente ou publication d'un paquet iOS/macOS demande l'accord ecrit prealable de Jean-Philippe DEGERT / JP2 Creation.
