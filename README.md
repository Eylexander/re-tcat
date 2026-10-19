# Re-TCAT

Les bus [TCAT](https://www.tcat.fr/) de Troyes en temps réel, sur Android et iPhone.

- **Carte** : tous les bus en service, à la couleur de leur ligne, avec leur direction. Filtre par ligne.
- **Suivre un bus** : la carte le suit et ses arrêts affichent l'heure de passage prévue, le retard, les arrêts non desservis.
- **Arrêts** : recherche, arrêts autour de vous, favoris avec leurs prochains bus (en direct quand le bus est suivi).
- **Lignes** : tracé, arrêts dans chaque sens, bus en service, perturbations.
- **Widget** : les prochains bus d'un arrêt sur l'écran d'accueil (Android et iOS).

## Installation

Android : depuis [mon dépôt F-Droid](https://eylexander.github.io/fdroid/), ou l'APK des
[releases](https://github.com/Eylexander/re-tcat/releases).

iPhone : l'`.ipa` des releases, à installer avec [xtool](https://github.com/xtool-org/xtool) (même depuis Linux :
`xtool install re-tcat-vX-unsigned.ipa`), AltStore, SideStore ou Sideloadly, qui le signent avec votre identifiant
Apple. Le widget a besoin d'un compte développeur Apple payant (App Groups) ; l'application, non.

## Fonctionnement

Comme [ha-tcat](https://github.com/Eylexander/ha-tcat) : les horaires viennent du GTFS de TCAT sur
[transport.data.gouv.fr](https://transport.data.gouv.fr/datasets/donnees-tcat-troyes-champagne-metropole-1),
téléchargé par l'application et remis à jour quand TCAT en publie un nouveau ; le temps réel, des flux GTFS-RT de TCAT
(positions des bus, prévisions de passage, perturbations), interrogés toutes les 15 secondes quand l'application est
ouverte. Aucun serveur intermédiaire.

Données : TCAT / Troyes Champagne Métropole (ODbL). Carte : © les contributeurs d'OpenStreetMap.
Application non officielle, sans lien avec TCAT ni Troyes Champagne Métropole.

## Développement

```sh
flutter test
flutter build apk --release --target-platform android-arm64
```

Une release : poussez un tag `v*` (voir `CLAUDE.md`).
