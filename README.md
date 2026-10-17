# homelab-komodo

All the services in my homelab are declared here as Docker Compose stacks. This includes databases (Postgres and Redis), SSO (Authentik), observability (Prometheus, Grafana, Loki and Tempo), and other service apps. Komodo Resource Sync is configured to poll the main branch of this repo, and Renovate upgrades images periodically.
