[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](../LICENSE.md)

# `vault_activity_counters.sh`

A smart, human-friendly wrapper around:

```
vault read sys/internal/counters/activity
```

Designed to turn Vault’s massive telemetry JSON into **clean, meaningful governance signals** — with shortcuts, icons, colors, and cross-platform time handling baked in.

Built for pipelines.
Built for humans.
Built for intelligence.

---

## ✨ Features

* **Full date simplification:**

  * `--start 2025-10-01` → `2025-10-01T00:00:00Z`
  * Handles RFC3339 and date-only seamlessly.

* **Rich set of time shortcuts:**

  * `--last-24h`
  * `--last-7d`
  * `--last-14d`
  * `--last-30d`
  * `--last-month`
  * `--last-year`
  * `--last-days N` (rolling)
  * `--last-months N` (rolling)

* **Default behavior:**
  No flags? → previous full calendar month.

* **Modes (data slices):**

  1. `total` → full `.data.total` block
  2. `non-entity` → `.non_entity_clients`
  3. `secret-syncs` → `.secret_syncs`
  4. `summary` → two key values
  5. `env` → KEY=value pairs

* **Output formats:**

  * `json`  (default)
  * `csv`   (delimited-text)
  * `md`    (Markdown table)

* **Dual output:**
  `--output-file foo.json` → writes to disk and stdout.

* **Noise-free data:**
  Icons + colors appear **only on stderr**,
  so CSV/JSON/Markdown remain machine-pure.

* **macOS & Linux**
  BSD/GNU `date` logic fully supported.

---

## 🔧 Requirements

* `vault`
* `jq`

`.env` in the same folder should contain:

```bash
VAULT_ADDR="https://your-vault.example.com"
VAULT_TOKEN="s.xxxxx"
# Optional: VAULT_NAMESPACE="finance/"
```

---

## 📝 Range Shortcuts

These replace messy RFC3339 timestamps with something you can actually remember:

| Shortcut          | Meaning                      |
| ----------------- | ---------------------------- |
| `--last-24h`      | Last 24 hours (rolling)      |
| `--last-7d`       | Last 7 days                  |
| `--last-14d`      | Last 14 days                 |
| `--last-30d`      | Last 30 days                 |
| `--last-month`    | Previous full calendar month |
| `--last-year`     | Last 12 months (rolling)     |
| `--last-days N`   | Last N days (rolling)        |
| `--last-months N` | Last N months (rolling)      |

If *no* `--start/--end` or shortcut is given, the script defaults to **`--last-month`**.

---

## 🚀 Usage Examples

### 1. Previous month (default)

```bash
./vault_activity_counters.sh --mode summary
```

### 2. Exact date range → full total block (JSON)

```bash
./vault_activity_counters.sh --start 2025-10-01 --end 2025-11-01 --mode total
```

### 3. Last 7 days → CSV → save to file

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

### 6. Large rolling windows (new)

```bash
./vault_activity_counters.sh --last-30d --mode summary
./vault_activity_counters.sh --last-14d --mode total
./vault_activity_counters.sh --last-year --format md
./vault_activity_counters.sh --last-days 90 --format csv
./vault_activity_counters.sh --last-months 24
```

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

* Colorful, friendly messages → `stderr`
* Machine-clean data → `stdout`

Perfect for pipes:

```bash
./vault_activity_counters.sh --mode summary | jq .
```

---

## 📦 Modes

| Mode name      | Shortcut | Output                               |
| -------------- | -------- | ------------------------------------ |
| `total`        | `1`      | Full `.data.total`                   |
| `non-entity`   | `2`      | Only `non_entity_clients`            |
| `secret-syncs` | `3`      | Only `secret_syncs`                  |
| `summary`      | `4`      | `{non_entity_clients, secret_syncs}` |
| `env`          | `5`      | KEY=value pairs (format ignored)     |

---

## 📄 License

This script is licensed under the **MIT License**.
See [`LICENSE.md`](./LICENSE.md) for details.
