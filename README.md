# Redis Sentinel HA on Docker with Ansible

This project deploys a production-oriented Redis high-availability stack on
three servers:

- one initial Redis master and two replicas;
- one independent Redis Sentinel process on every server;
- automatic failover with a configurable Sentinel quorum;
- optional Redis ACL authentication, TLS, persistence, backups, and UFW rules;
- Node Exporter and Redis Exporter on every server;
- one Dockerized Prometheus instance, without a separate monitoring VM.

The roles are modular, configurable, and idempotent. After a failover, later
Ansible runs discover and preserve the Sentinel-selected master rather than
forcing the original inventory master back into that role. Alertmanager and
alert rules are intentionally outside the project scope.

## Architecture

```text
redis-1   Redis + Sentinel + Node/Redis exporters + Prometheus
redis-2   Redis + Sentinel + Node/Redis exporters
redis-3   Redis + Sentinel + Node/Redis exporters

Sentinel quorum: 2 of 3
```

`redis_master` in the inventory selects only the initial master. Sentinel owns
the active topology after deployment.

## Project layout

```text
inventories/production/hosts.yml               Server addresses and groups
inventories/production/group_vars/all/main.yml Deployment configuration
inventories/production/group_vars/all/vault.yml Encrypted secrets (not committed)
roles/                                         Modular Ansible roles
site.yml                                       Main deployment playbook
tests/failover.yml                             Opt-in failover test
files/tls/                                     Optional per-host certificates
```

The roles manage Docker, host tuning, firewall policy, Redis, Sentinel,
exporters, Prometheus, backups, and post-deployment verification.

## Requirements

- Ansible controller with Python 3 and `ansible-core`.
- Three reachable Debian/Ubuntu hosts with Python 3.
- SSH key access and passwordless `sudo` for `ansible_user`.
- Network connectivity between the three hosts.

Install the required Ansible collections:

```bash
ansible-galaxy collection install -r requirements.yml
```

## Configure the deployment

Set host IP addresses only in `inventories/production/hosts.yml`:

```yaml
redis-1:
  ansible_host: 192.168.122.188
redis-2:
  ansible_host: 192.168.122.237
redis-3:
  ansible_host: 192.168.122.219
```

Set the SSH user, component switches, ports, image versions, storage, resource
limits, and timeouts in `inventories/production/group_vars/all/main.yml`.
Every component section starts with its enable variable:

```yaml
docker_enabled: true
redis_enabled: true
redis_auth_enabled: true
redis_acl_enabled: true
redis_persistence_enabled: true
redis_tls_enabled: false
redis_sentinel_enabled: true
redis_host_tuning_enabled: true
redis_firewall_enabled: false
redis_exporters_enabled: true
prometheus_enabled: true
redis_backup_enabled: true
redis_verify_enabled: true
```

TLS and firewall management are disabled by default. Review network allowlists
before enabling UFW. For TLS file placement, see `files/tls/README.md`.

## Create the encrypted Vault

Create the Vault file directly in encrypted form:

```bash
ansible-vault create inventories/production/group_vars/all/vault.yml
```

Enter these variables in the editor with unique production passwords:

```yaml
vault_redis_password: "change-me"
vault_redis_admin_password: "change-me"
vault_redis_application_password: "change-me"
vault_redis_replication_password: "change-me"
vault_redis_sentinel_redis_password: "change-me"
vault_redis_exporter_password: "change-me"
vault_redis_sentinel_password: "change-me"
```

Useful Vault commands:

```bash
ansible-vault edit inventories/production/group_vars/all/vault.yml
ansible-vault view inventories/production/group_vars/all/vault.yml
ansible-vault rekey inventories/production/group_vars/all/vault.yml
```

`redis_sentinel_redis_password` authenticates Sentinel to Redis. The separate
`redis_sentinel_password` protects the Sentinel service when
`redis_sentinel_auth_enabled` is enabled.

## Validate and deploy

Confirm inventory and SSH connectivity:

```bash
ansible-inventory --graph --ask-vault-pass
ansible all -m ping --ask-vault-pass
```

Validate the playbook syntax:

```bash
ansible-playbook site.yml --syntax-check --ask-vault-pass
```

Deploy the complete stack:

```bash
ansible-playbook site.yml --ask-vault-pass
```

Run the same command again to confirm idempotence; the recap should report no
unexpected changes.

After the initial deployment, preview planned configuration changes with:

```bash
ansible-playbook site.yml --check --diff --ask-vault-pass
```

## Common Ansible operations

List available tags or tasks:

```bash
ansible-playbook site.yml --list-tags --ask-vault-pass
ansible-playbook site.yml --list-tasks --ask-vault-pass
```

Run selected components after the initial full deployment:

```bash
ansible-playbook site.yml --tags redis,sentinel --ask-vault-pass
ansible-playbook site.yml --tags exporters,prometheus --ask-vault-pass
ansible-playbook site.yml --tags verify --ask-vault-pass
```

Check running containers on all Redis hosts:

```bash
ansible redis_cluster -b -a "docker ps" --ask-vault-pass
```

## Authentication and ACLs

When ACL mode is enabled, Ansible creates dedicated `admin`, `application`,
`replication`, `sentinel`, and `exporter` users and disables the Redis
`default` user. ACL permissions are configurable through variables such as
`redis_admin_acl_rules` and `redis_sentinel_acl_rules` in the Redis role
defaults; override them in the production `main.yml` when required.

Set `redis_auth_enabled: false` to disable Redis authentication completely. Set
`redis_acl_enabled: false` to use legacy `requirepass` authentication instead.

## Verification and failover

The normal deployment verifies Redis roles, replica count, Sentinel agreement,
quorum, exporter health, and Prometheus target status.

Run verification again without redeploying services:

```bash
ansible-playbook site.yml --tags verify --ask-vault-pass
```

Run the disruptive automatic failover test only in an approved maintenance
window:

```bash
ansible-playbook tests/failover.yml \
  -e failover_test_confirm=true \
  --ask-vault-pass
```

The test discovers and stops the current master, waits for promotion, verifies
data before and after failover, restarts the former master, and confirms that it
rejoins as a replica.

## Persistence and recovery

Redis uses AOF and RDB persistence by default. Backups are stored under
`/opt/redis/backups` with configurable scheduling and retention. For disaster
recovery, place this directory on off-host storage.

If persistence is disabled, backups are disabled automatically and the default
container restart policy prevents an empty node from automatically rejoining
after reboot.
