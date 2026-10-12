# Optional TLS material

When `redis_tls_enabled: true`, create one directory per inventory host:

```text
files/tls/redis-1/{redis.crt,redis.key,ca.crt}
files/tls/redis-2/{redis.crt,redis.key,ca.crt}
files/tls/redis-3/{redis.crt,redis.key,ca.crt}
```

Certificates must contain the advertised IP or hostname in their SAN extension.
Because mutual TLS is enabled by default, the certificates must also be valid for
both server and client authentication. Set `redis_tls_auth_clients: "no"` only
when client-certificate authentication is intentionally not required.
Use a production PKI or secret-management system; private keys should not be
committed to source control.
