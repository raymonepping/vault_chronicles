# `vault_activity_counters.sh`

A smart, human-friendly wrapper around:

```
vault read sys/internal/counters/activity
```

Designed to turn Vault’s massive telemetry JSON into **clean, meaningful governance signals** — with shortcuts, icons, colors, and cross-platform date handling baked in.

Built for pipelines.
Built for humans.
Built for intelligence.

---

## ✨ Features

* **Automatic date shortening:**
  `--start 2025-10-01` → `2025-10-01T00:00:00Z`

* **Smart shortcuts:**
  `--last-24h` • `--last-7d` • `--last-month`

* **Default behavior:**
  No range flags? → previous full calendar month.

* **Multiple output formats:**
  `json` (default) • `csv` • `md`

* **Modes (data slices):**

  1. `total` — full `.data.total` block
  2. `non-entity` — `.non_entity_clients`
  3. `secret-syncs` — `.secret_syncs`
  4. `summary` — both fields
  5. `env` — KEY=value pairs

* **Dual-output:**
  `--output-file foo.json`
  → writes to disk *and* stdout

* **Clean separation:**
  Icons + colors only on **stderr**
  → JSON/CSV/MD output stays machine-pure.

* **macOS & Linux compatible**
  BSD/GNU `date` fully supported.

---

## 🔧 Requirements

* `vault` CLI
* `jq`

Your `.env` must define:

```bash
VAULT_ADDR="https://your-vault.example.com"
VAULT_TOKEN="s.xxxxx"
# Optional:
# VAULT_NAMESPACE="...your namespace..."
```

---

## 🚀 Usage Examples

### 1. Previous month, summary (default)

```bash
./vault_activity_counters.sh --mode summary
```

### 2. Explicit date range, total block (JSON)

```bash
./vault_activity_counters.sh --start 2025-10-01 --end 2025-11-01 --mode total
```

### 3. Last 7 days, CSV, and save it

```bash
./vault_activity_counters.sh \
  --last-7d \
  --mode summary \
  --format csv \
  --output-file activity_7d.csv
```

### 4. Markdown table output

```bash
./vault_activity_counters.sh --mode total --format md
```

### 5. Env-style output (for sourcing in scripts)

```bash
./vault_activity_counters.sh --mode env
```

Outputs:

```
non_entity_clients=43
secret_syncs=1
```

---

## 📦 Modes

| Mode name      | Shortcut | Output                               |
| -------------- | -------- | ------------------------------------ |
| `total`        | `1`      | Full `.data.total` object            |
| `non-entity`   | `2`      | Only `non_entity_clients`            |
| `secret-syncs` | `3`      | Only `secret_syncs`                  |
| `summary`      | `4`      | `{non_entity_clients, secret_syncs}` |
| `env`          | `5`      | KEY=value pairs (ignores `--format`) |

---

## 🗂 Output Formats

| Format | Description                    |
| ------ | ------------------------------ |
| `json` | Pretty JSON (default)          |
| `csv`  | Header + values                |
| `md`   | GitHub-friendly markdown table |

---

## 📝 Range Shortcuts

| Shortcut       | Meaning                      |
| -------------- | ---------------------------- |
| `--last-24h`   | From now minus 24h to now    |
| `--last-7d`    | Previous 7 days              |
| `--last-month` | Previous full calendar month |

If no range flags and no `--start/--end` are provided, the script defaults to **`--last-month`**.

---

## ✔️ Example Output

```
ℹ️  Using range: 2025-10-01T00:00:00Z -> 2025-11-01T00:00:00Z
{
  "non_entity_clients": 43,
  "secret_syncs": 1
}

✅ Wrote output to vault_activity_oct.json
```

Colorful, helpful messages → `stderr`
Data → `stdout`

Safe for pipes:

```bash
./vault_activity_counters.sh --mode summary | jq .
```

---

## 📄 License

MIT, Apache-2.0, or “Raymon License v1 — Don’t Be Stupid”.
Pick your favorite.
(If you want a real license file, I’ll generate it.)