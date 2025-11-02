# Pulse-Flow

Sammle GitLab-Aktivitäten für eine Gruppe und speichere sie als JSON-Snapshot, den Crush später zusammenfassen kann.

## Voraussetzungen
- `curl`
- `jq`
- GNU `date` (unterstützt `-d`; z. B. `gdate` aus den coreutils auf macOS sollte als `date` verlinkt sein)
- `GITLAB_TOKEN`, exportiert mit API-Zugriff auf die GitLab-Instanz

Optionale Umgebungsvariablen:
- `GITLAB_BASE_URL` (Standard: `https://gitlab.com`)
- `PULSE_DAYS` (Standard: `7`)

## Verwendung
```bash
./flows/pulse/pulse.sh gitlab-gruppenpfad [ausgabedatei]
```
Beispiele:
```bash
export GITLAB_TOKEN=xxx
./flows/pulse/pulse.sh platform
./flows/pulse/pulse.sh apps /tmp/apps-pulse.json
```

Das Skript ermittelt die Gruppen-ID, lädt erstellte Issues, gemergte Merge-Requests und Push-Ereignisse der vergangenen `PULSE_DAYS` Tage und speichert sie mitsamt praktischen Zählwerten:
```json
{
  "group": {"id": 42, "full_path": "platform"},
  "timeframe": {"since": "2024-05-01", "until": "2024-05-08T12:00:00Z"},
  "stats": {"issues": 5, "merge_requests": 12, "commits": 48},
  "issues": [...],
  "merge_requests": [...],
  "commits": [...]
}
```

## Zentrale Ideen aus der Weekly-Pulse-Diskussion
- Sammle wöchentliche GitLab-Aktivitäten (Issues, gemergte MRs, Commit-Pushes) pro Gruppe über die REST-API.
- Aggregiere die JSON-Daten lokal, damit Crush sie analysieren kann, ohne GitLab erneut abzufragen.
- Lass Crush jeden Snapshot in eine führungstaugliche Zusammenfassung verwandeln (Markdown eignet sich hervorragend).
- Ergänze die Zusammenfassung bei Bedarf um leichte Statistiken und veröffentliche sie dort, wo dein Team liest (Mattermost, GitLab-Wiki usw.).
- Bewahre die Snapshots auf, damit ihr Trends über mehrere Wochen vergleichen könnt.
