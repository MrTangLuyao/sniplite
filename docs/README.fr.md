<div align="center">

<img src="../pics/icon.png" width="96" alt="icône de sniplite">

# sniplite

**Un outil de capture d'écran et d'épinglage minuscule et rapide, dont le cœur est écrit en assembleur**

[![English](https://img.shields.io/badge/English-eaeef2?style=flat-square)](../README.md) [![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-eaeef2?style=flat-square)](README.zh-CN.md) [![繁體中文](https://img.shields.io/badge/%E7%B9%81%E9%AB%94%E4%B8%AD%E6%96%87-eaeef2?style=flat-square)](README.zh-TW.md) [![日本語](https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-eaeef2?style=flat-square)](README.ja.md) [![한국어](https://img.shields.io/badge/%ED%95%9C%EA%B5%AD%EC%96%B4-eaeef2?style=flat-square)](README.ko.md) [![Français](https://img.shields.io/badge/Fran%C3%A7ais-1677e5?style=flat-square)](README.fr.md) [![Deutsch](https://img.shields.io/badge/Deutsch-eaeef2?style=flat-square)](README.de.md) [![Español](https://img.shields.io/badge/Espa%C3%B1ol-eaeef2?style=flat-square)](README.es.md)

[![version](https://img.shields.io/github/v/tag/MrTangLuyao/sniplite?sort=date&label=version&style=flat-square&color=1677e5)](https://github.com/MrTangLuyao/sniplite/releases) [![système](https://img.shields.io/badge/syst%C3%A8me-Windows%2010%20%2F%2011-3b82f6?style=flat-square)](#télécharger) [![licence](https://img.shields.io/badge/licence-MIT-3b82f6?style=flat-square)](../LICENSE)

[**Télécharger**](#télécharger) | [Raccourcis par défaut](#raccourcis-par-défaut) | [Questions fréquentes](#questions-fréquentes)

<img src="../pics/demo-edit.png" alt="Sélectionnez une zone et dessinez-y directement des cercles, des flèches, du texte et des numéros" width="66%">
<br>
<img src="../pics/demo-select.png" alt="Avant la capture, la fenêtre ou le contrôle sous la souris est repéré pour vous ; la loupe montre les pixels et les couleurs" width="32.5%"> <img src="../pics/demo-pin.png" alt="Épinglez une capture ou du texte à l'écran ; la molette zoome" width="32.5%">

</div>

## Points forts

- **Rapide** : appuyez sur F1 et la capture est là, plus vite qu'avec 99 % des outils de capture
- **Léger** : environ 220 Ko, rien d'autre à installer ; le cœur de la capture et du dessin est écrit en assembleur
- **Épingles** : épinglez une capture au-dessus de toutes les fenêtres pour la garder sous les yeux pendant que vous travaillez
- **Complet** : captures, épingles, flèches, texte, mosaïque : tout y est
- **Propre** : sans publicité, open source, sans journaux, sans collecte de données
- **Multilingue** : 8 langues ; suit celle de Windows, sauf si vous en choisissez une

## Télécharger

Récupérez le dernier installeur dans [Releases](https://github.com/MrTangLuyao/sniplite/releases/latest).

> [!TIP]
> L'icône se trouve à droite de la barre des tâches ; si vous ne la voyez pas, cliquez sur la petite flèche. Pour la garder visible, cherchez « Autres icônes de la barre d'état système » dans les paramètres de Windows et activez sniplite.

## Raccourcis par défaut

| Touche | Action |
| --- | --- |
| **F1** | Capturer |
| **F3** | Épingler à l'écran l'image ou le texte copié |
| **Shift+F3** | Masquer / afficher toutes les épingles |
| **Enter** | Copier la capture |
| **Ctrl+S** | Enregistrer la capture |
| **Ctrl+T** | Épingler la capture à l'écran |
| **Esc** | Annuler la capture |
| **Molette** | Pendant la capture : choisir une fenêtre plus grande ou plus petite ; sur une épingle : zoomer |
| **Double-clic** | Fermer une épingle |

## Questions fréquentes

**Quelle est sa taille ?**

Minuscule : moins de 1 Mo.

**Pourquoi est-il si rapide ?**

Les parties qui doivent aller vite (capture, composition, dessin, écran de capture et épingles) sont écrites en assembleur x86-64, le reste en C, sans bibliothèque d'exécution C. La capture est lue directement depuis la carte graphique et confiée à Windows pour être composée sur le GPU, ce qui est bien plus rapide que les méthodes de capture habituelles de Windows.

**Combien de mémoire utilise-t-il ?**

Environ 50 Mo la plupart du temps, presque entièrement pris par le pilote graphique, et un peu plus juste après une capture. Pour en utiliser moins, choisissez « Économe » dans l'onglet Capture des préférences : environ 2 Mo, avec des captures plus lentes.

**Que laisse-t-il sur mon ordinateur ?**

Il ne demande pas de droits d'administrateur et ne touche pas au registre. Modifier un réglage crée un fichier de réglages ; supprimez-le pour revenir aux valeurs par défaut.

**Comment changer de langue ?**

sniplite suit la langue de Windows. Pour en utiliser une autre, ouvrez les préférences depuis l'icône de la zone de notification et choisissez-la dans Langue.

**Comment le mettre à jour ?**

Une fois par jour, sniplite demande à GitHub s'il existe une version plus récente. Si oui, une notification apparaît en bas à droite, et un clic suffit pour mettre à jour. Seul le numéro de version est vérifié, rien n'est envoyé ; vous pouvez désactiver cela dans les préférences.

**Comment le désinstaller ?**

Cliquez sur « Désinstaller sniplite » dans le dossier sniplite du menu Démarrer. Le programme, ses réglages et ses raccourcis sont supprimés.

**Y a-t-il une ligne de commande ?**

Oui. Lancez `sniplite help` pour la découvrir.

## Préférences

<img src="../pics/ui/fr.png" alt="Les cinq onglets des préférences, la liste des raccourcis et l'installeur">

## Le compiler soi-même

Installez [w64devkit](https://github.com/skeeto/w64devkit) (ou un autre MinGW-w64), ajoutez son dossier `bin` au PATH et lancez `build.bat` ; les programmes apparaissent dans le dossier `build`. Les sources sont dans `src` : les parties rapides sont des fichiers assembleur (`.S`), assemblés par gcc avec l'assembleur GNU, le reste est en C (`.c`). Aucune bibliothèque d'exécution C n'est liée, seulement les bibliothèques système fournies avec Windows.

## Licence

[MIT](../LICENSE)
