# Vault Enterprise Raft Cluster (3-Node)

This project runs a **3-node Vault Enterprise cluster** using Docker Compose.
It uses **Raft integrated storage** and demonstrates **clustering, unseal flow, and audit logging**.

---

## 📂 Project Layout

```
ops/vault/
  ├── node-1/
  │   ├── config/config.hcl
  │   └── data/
  ├── node-2/
  │   ├── config/config.hcl
  │   └── data/
  ├── node-3/
  │   ├── config/config.hcl
  │   └── data/
  └── vault.hclic      # Vault Enterprise license file
docker-compose.yml     # Multi-node Vault cluster
unseal_cluster.sh      # Script to unseal + bootstrap cluster
verify_cluster.sh      # Script to check cluster status
```

---

## 🚀 Quickstart

### 1. Start the cluster

```bash
docker compose up -d
```

This runs 3 Vault containers:

* Node 1 (leader) → [http://127.0.0.1:18200](http://127.0.0.1:18200)
* Node 2 (standby) → [http://127.0.0.1:18210](http://127.0.0.1:18210)
* Node 3 (standby) → [http://127.0.0.1:18220](http://127.0.0.1:18220)

---

### 2. Initialize Vault (only once, on leader)

```bash
VAULT_ADDR=http://127.0.0.1:18200 vault operator init -key-shares=3 -key-threshold=2 | tee ops/INIT.out
```

This generates:

* 3 unseal keys (any 2 are needed)
* Initial root token

---

### 3. Unseal the cluster

Run the helper script (will read `ops/INIT.out`):

```bash
./unseal_cluster.sh
```

This unseals all nodes, logs into the leader, and bootstraps secrets engines (KV v2, Transit, Database) and audit logging.

---

### 4. Verify cluster state

```bash
./verify_cluster.sh
```

Or manually:

```bash
VAULT_ADDR=http://127.0.0.1:18200 vault operator raft list-peers
```

Expected:

```
Node    Address        State     Voter
node-1  vault-1:8201   leader    true
node-2  vault-2:8201   follower  true
node-3  vault-3:8201   follower  true
```

---

## 🔑 Unseal Keys & Root Token

* Unseal keys and root token are stored in `ops/INIT.out`.
* Protect this file (add it to `.gitignore`).
* To re-unseal after restart, use the same keys.

---

## 🛑 Clean up

Stop and remove everything:

```bash
docker compose down -v
```

---

## ⚠️ Notes

* TLS is disabled for simplicity (`tls_disable=1`). Do **not** use this in production.
* Each node persists Raft data in its own `ops/vault/node-*/data` folder.
* Enterprise license must be placed at `ops/vault/vault.hclic`.