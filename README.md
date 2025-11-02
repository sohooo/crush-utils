# Crush-Dienstprogramme

Dieses Repository enthält Crush-Flows für GitLab-orientierte Arbeitsabläufe.

## Verfügbare Flows

### Merge-Request-Review
Nutze das Hilfsskript, um einen GitLab-Merge-Request mit Crush zu prüfen. Stelle sicher, dass [`crush`](https://github.com/crush-org/crush), `curl` und `jq` vorhanden sind, und exportiere einen `GITLAB_TOKEN` mit Zugriff auf das Zielprojekt:

```bash
export GITLAB_TOKEN=xxx
./flows/review_mr/review_mr.sh "https://gitlab.com/dein/projekt/-/merge_requests/123"
```
Das Skript lädt Umgebungsstandardwerte, ruft Metadaten, Diskussionen, Diffs und Commit-Details direkt über die GitLab-API ab, bereitet sie als Kontext auf und startet anschließend die Crush-Pipeline `flows/review_mr`.

### Wöchentlicher Pulse-Snapshot
Erzeuge einen JSON-Snapshot der aktuellen GitLab-Aktivität für eine Gruppe (benötigt `curl`, `jq` und GNU `date`):

```bash
export GITLAB_TOKEN=xxx
./flows/pulse/pulse.sh deine-gruppe
```
Das Skript fragt erstellte Issues, gemergte Merge-Requests und Push-Ereignisse der letzten sieben Tage ab (konfigurierbar über `PULSE_DAYS`) und schreibt eine JSON-Datei, die sofort zusammengefasst werden kann.

Ausführliche Informationen findest du in den jeweiligen READMEs unter `flows/<flow-name>/`.

### Überblick über Nutzeraktivitäten
Sammle aktuelle GitLab-Ereignisse für eine bestimmte Person und starte Crush, um die Highlights zu zusammenzufassen:

```bash
./flows/user_activity/user_activity.sh nutzername [tage]
```

Das Skript ermittelt den Nutzenden, sammelt Aktivitäten der vergangenen `tage` (Standard `7`), legt die Rohantworten der GitLab-API als Kontext ab und öffnet anschließend die Crush-Pipeline `flows/user_activity`, um einen kompakten Aktivitätsbericht zu erzeugen.
