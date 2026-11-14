<div align="center">

<img src="../pics/icon.png" width="96" alt="sniplite-Symbol">

# sniplite

**Ein winziges, schnelles Werkzeug für Screenshots und Pins, im Kern in Assembler geschrieben**

[![English](https://img.shields.io/badge/English-eaeef2?style=flat-square)](../README.md) [![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-eaeef2?style=flat-square)](README.zh-CN.md) [![繁體中文](https://img.shields.io/badge/%E7%B9%81%E9%AB%94%E4%B8%AD%E6%96%87-eaeef2?style=flat-square)](README.zh-TW.md) [![日本語](https://img.shields.io/badge/%E6%97%A5%E6%9C%AC%E8%AA%9E-eaeef2?style=flat-square)](README.ja.md) [![한국어](https://img.shields.io/badge/%ED%95%9C%EA%B5%AD%EC%96%B4-eaeef2?style=flat-square)](README.ko.md) [![Français](https://img.shields.io/badge/Fran%C3%A7ais-eaeef2?style=flat-square)](README.fr.md) [![Deutsch](https://img.shields.io/badge/Deutsch-1677e5?style=flat-square)](README.de.md) [![Español](https://img.shields.io/badge/Espa%C3%B1ol-eaeef2?style=flat-square)](README.es.md)

[![Version](https://img.shields.io/github/v/tag/MrTangLuyao/sniplite?sort=date&label=Version&style=flat-square&color=1677e5)](https://github.com/MrTangLuyao/sniplite/releases) [![System](https://img.shields.io/badge/System-Windows%2010%20%2F%2011-3b82f6?style=flat-square)](#download) [![Lizenz](https://img.shields.io/badge/Lizenz-MIT-3b82f6?style=flat-square)](../LICENSE)

[**Download**](#download) | [Standard-Tastenkürzel](#standard-tastenkürzel) | [Häufige Fragen](#häufige-fragen)

<img src="../pics/demo-edit.png" alt="Einen Bereich wählen und direkt darauf Kreise, Pfeile, Text und Nummern zeichnen" width="66%">
<br>
<img src="../pics/demo-select.png" alt="Vor der Aufnahme wird das Fenster oder Element unter der Maus erkannt; die Lupe zeigt Pixel und Farben" width="32.5%"> <img src="../pics/demo-pin.png" alt="Einen Screenshot oder Text über allen Fenstern anheften; das Mausrad zoomt" width="32.5%">

</div>

## Merkmale

- **Schnell**: F1 drücken, und der Screenshot ist da, schneller als bei 99 % der Screenshot-Programme
- **Schlank**: etwa 220 KB, nichts weiter zu installieren; der Kern für Aufnahme und Zeichnen ist in Assembler geschrieben
- **Pins**: einen Screenshot über allen Fenstern anheften, damit er beim Arbeiten im Blick bleibt
- **Komplett**: Screenshots, Pins, Pfeile, Text, Verpixeln, alles dabei
- **Sauber**: keine Werbung, Open Source, keine Protokolle, keine Datensammlung
- **Mehrsprachig**: 8 Sprachen; richtet sich nach Windows, solange Sie keine wählen

## Download

Den neuesten Installer gibt es unter [Releases](https://github.com/MrTangLuyao/sniplite/releases/latest).

> [!TIP]
> Das Symbol sitzt am rechten Ende der Taskleiste; ist es nicht zu sehen, klicken Sie dort auf den kleinen Pfeil. Damit es sichtbar bleibt, suchen Sie in den Windows-Einstellungen nach „Weitere Taskleistensymbole“ und schalten sniplite ein.

## Standard-Tastenkürzel

| Taste | Funktion |
| --- | --- |
| **F1** | Aufnehmen |
| **F3** | Kopiertes Bild oder kopierten Text anheften |
| **Shift+F3** | Alle Pins aus- / einblenden |
| **Enter** | Aufnahme kopieren |
| **Ctrl+S** | Aufnahme speichern |
| **Ctrl+T** | Aufnahme anheften |
| **Esc** | Aufnahme abbrechen |
| **Mausrad** | Bei der Aufnahme: größeres oder kleineres Fenster wählen; auf einem Pin: zoomen |
| **Doppelklick** | Pin schließen |

## Häufige Fragen

**Wie groß ist es?**

Winzig: unter 1 MB.

**Warum ist es so schnell?**

Die Teile, die schnell sein müssen (Aufnahme, Komposition, Zeichnen und Aufnahmeansicht), sind in x86-64-Assembler geschrieben, der Rest in C, ohne C-Laufzeitbibliothek. Ein Screenshot wird direkt von der Grafikkarte gelesen und Windows zur Komposition auf der GPU übergeben; das ist viel schneller als die üblichen Aufnahmewege unter Windows.

**Wie schneidet es im Vergleich ab?**

| Programm | Download | Speicher im Leerlauf | Vom Tastenkürzel bis bereit |
| --- | --- | --- | --- |
| **sniplite** | 0,3 MB | 11 MB | 12 ms |
| Snipaste 2.11.3 | 19 MB | 50 MB | 121 ms |
| PixPin 3.6.6 | 66 MB | 31 MB | 142 ms |
| Greenshot 1.3.328 | 4 MB | 16 MB | 252 ms |
| Flameshot 15.0.0 | 18 MB | 6 MB | nicht gemessen |
| ShareX 22.4.0 | 139 MB | 58 MB | nicht gemessen |

<sub>Das ist ein informeller Test, nur zur Orientierung.</sub>

**Wie viel Speicher braucht es?**

Meist etwa 50 MB, fast alles davon belegt der Grafiktreiber, direkt nach einer Aufnahme kurz etwas mehr. Wer weniger möchte, wählt in den Einstellungen auf der Seite Aufnahme den Modus Sparsam: etwa 2 MB, dafür langsamere Aufnahmen.

**Was bleibt auf meinem Rechner zurück?**

Es braucht keine Administratorrechte und fasst die Registrierung nicht an. Wer eine Einstellung ändert, bekommt eine Einstellungsdatei; wer sie löscht, hat wieder die Standardwerte.

**Wie ändere ich die Sprache?**

sniplite richtet sich nach der Sprache von Windows. Für eine andere öffnen Sie die Einstellungen über das Tray-Symbol und wählen sie unter Sprache.

**Wie aktualisiere ich es?**

Einmal am Tag fragt sniplite bei GitHub nach einer neueren Version. Gibt es eine, erscheint unten rechts ein Hinweis, und ein Klick aktualisiert. Geprüft wird nur die Versionsnummer, hochgeladen wird nichts; in den Einstellungen lässt sich das abschalten.

**Wie deinstalliere ich es?**

Klicken Sie im Startmenü im Ordner sniplite auf „sniplite deinstallieren“. Programm, Einstellungen und Verknüpfungen werden entfernt.

**Gibt es eine Befehlszeile?**

Ja. `sniplite help` zeigt alle Befehle.

## Einstellungen

<img src="../pics/ui/de.png" alt="Die fünf Seiten der Einstellungen, die Liste der Tastenkürzel und der Installer">

## Selbst bauen

[w64devkit](https://github.com/skeeto/w64devkit) (oder ein anderes MinGW-w64) installieren, dessen Ordner `bin` in den PATH aufnehmen und `build.bat` ausführen; die Programme entstehen im Ordner `build`. Der Quelltext liegt in `src`: Die schnellen Teile sind Assemblerdateien (`.S`), die gcc mit dem GNU-Assembler übersetzt, der Rest ist C (`.c`). Es wird keine C-Laufzeitbibliothek gelinkt, nur die Systembibliotheken, die Windows mitbringt.

## Lizenz

[MIT](../LICENSE)
