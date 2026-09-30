# Odoo Auto-Installer für Windows 11

PowerShell-Skript, das **Odoo 20 (Community)** mit Docker Desktop auf einem Windows-11-Rechner einrichtet – inklusive WSL 2, Docker Desktop, PostgreSQL und einer fertigen Konfiguration.

Aktuelle Version: **2.1 (29.09.2026)**

## Voraussetzungen

| Anforderung | Minimum |
| --- | --- |
| Betriebssystem | Windows 11 64-bit, Version 23H2 oder neuer (Home oder Pro) |
| Prozessor | x64 (Intel/AMD) oder ARM64 mit aktivierter Hardware-Virtualisierung |
| Arbeitsspeicher | 8 GB empfohlen |
| Speicherplatz | 30 GB frei |
| Rechte | Lokale Administratorrechte |

## Schnellstart

1. `install-odoo20.ps1` herunterladen (Datei öffnen → **Download raw file**).
2. Rechtsklick auf die Datei → **Eigenschaften** → unten **Zulassen** anhaken → OK.
   (Alternativ in PowerShell: `Unblock-File .\install-odoo20.ps1`)
3. PowerShell im Download-Ordner öffnen und starten:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install-odoo20.ps1
   ```

4. Die Administrator-Abfrage bestätigen, die Zusammenfassung lesen und mit **J** fortfahren.
5. Am Ende öffnet sich `http://localhost:8069`. Dort mit dem angezeigten Master-Passwort die erste Datenbank anlegen.
   Beim Feld „Email“ genügt ein beliebiger Login (z. B. `admin`), es muss keine echte Adresse sein.

Ist ein Neustart nötig (WSL), läuft das Skript nach der nächsten Anmeldung automatisch weiter.

## Was das Skript macht

1. Voraussetzungen prüfen (Windows-Version, Prozessor, Virtualisierung, Speicher, RAM)
2. WSL 2 aktivieren und aktualisieren
3. Eine laufende Docker-Engine nutzen – oder Docker Desktop laden, **Signatur von Docker Inc. prüfen** und still installieren
4. Docker starten, bei Bedarf auf Linux-Container umschalten
5. `C:\odoo20` mit `compose.yaml` und `odoo.conf` anlegen (zufällige Passwörter)
6. Odoo 20 + PostgreSQL 16 laden und starten

Das Skript kann gefahrlos mehrfach laufen; Erledigtes wird übersprungen, bestehende Dateien bleiben erhalten.

## Optionen

| Parameter | Standard | Zweck |
| --- | --- | --- |
| `-OdooVersion` | `20.0` | Image-Tag, z. B. `19.0` |
| `-Port` | `8069` | Port auf dem Rechner |
| `-InstallDir` | `C:\odoo20` | Projektordner |
| `-PostgresVersion` | `16` | PostgreSQL-Version |
| `-WslMemoryGB` | `8` | RAM-Grenze für WSL; `0` = keine `.wslconfig` anlegen |
| `-AllowNetworkAccess` | aus | Odoo auch für andere Geräte im Netzwerk freigeben (nicht empfohlen) |
| `-IgnoreOtherEngines` | aus | Docker Desktop auch installieren, wenn Rancher Desktop/Podman vorhanden ist |
| `-Force` | aus | `compose.yaml` und `odoo.conf` neu schreiben |
| `-Yes` | aus | Bestätigungsabfragen überspringen |

## Sicherheit

- Odoo ist standardmäßig **nur auf dem eigenen Rechner** erreichbar (`127.0.0.1`).
- Das Skript läuft mit Administratorrechten. Nur aus diesem Repository verwenden.
- Datenbank- und Master-Passwort werden bei jeder Installation neu erzeugt und stehen in `C:\odoo20\config\odoo.conf`.

## Lizenz von Docker Desktop

Mit der Installation wird die Docker-Desktop-Lizenz akzeptiert. Docker Desktop ist kostenlos für Privatnutzung, Ausbildung und Unternehmen mit **weniger als 250 Mitarbeitenden und weniger als 10 Mio. USD Jahresumsatz** – sonst ist ein kostenpflichtiges Docker-Abo nötig.
Details: https://www.docker.com/legal/docker-subscription-service-agreement/

## Nach der Installation

| Aufgabe | Befehl (in `C:\odoo20`) |
| --- | --- |
| Starten | `docker compose up -d` |
| Stoppen | `docker compose stop` |
| Log ansehen | `docker compose logs --tail 20 web` |
| Update auf neuesten 20.0-Build | `docker compose pull` und `docker compose up -d` |
| Master-Passwort anzeigen | `Get-Content config\odoo.conf` |

Nach einem Neustart des PCs startet Odoo automatisch mit Docker Desktop (ca. 1 Minute warten).

## Teststand

Version 1 lief erfolgreich auf einem Lenovo ThinkPad L14 (Windows 11 Pro). Die Versionen 2.0 und 2.1 sind syntaktisch geprüft, aber noch nicht auf weiteren Rechnern getestet. Fehler und Rückmeldungen bitte als Issue melden.

## Lizenz

Dieses Projekt steht unter der [MIT-Lizenz](LICENSE). Du darfst das Skript frei verwenden, verändern und weitergeben, solange der Copyright-Hinweis erhalten bleibt. Es wird ohne jede Gewährleistung bereitgestellt; die Nutzung erfolgt auf eigene Verantwortung.

Die Lizenz gilt nur für dieses Skript. Docker Desktop, Odoo und PostgreSQL haben ihre eigenen Lizenzen (siehe oben zu Docker Desktop; Odoo Community: LGPL-3.0).
