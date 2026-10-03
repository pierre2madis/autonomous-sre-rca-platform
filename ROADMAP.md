# Autonomous SRE RCA Platform — Roadmap

## v1.0.0 — Initial Public Release

The first public release focuses on demonstrating an end-to-end SRE automation architecture.

### SRE and Observability

- SLI / SLO engineering
- Error-budget and burn-rate concepts
- MTTR measurement
- p50 / p90 / p95 / p99 analysis
- Prometheus / Alertmanager integration
- Splunk observability and administration
- Dynatrace integration
- Linux and eBPF evidence

### Incident Engineering

- Evidence collection
- Evidence normalization
- Cross-domain correlation
- Temporal correlation
- Causal evidence
- Incident lifecycle
- Parent / child event correlation
- Fail-closed decision principles

### Automation

- n8n orchestration
- ServiceNow incident workflow
- PagerDuty escalation
- Slack notification
- AWX / Ansible remediation
- Post-remediation verification

### CI/CD

- GitHub Actions
- Bash syntax validation
- ShellCheck
- JSON contract validation
- Golden tests
- Integration tests
- Adversarial tests
- SHA-256 artifact integrity
- Controlled deployment
- Post-deployment SLO gates

## Planned v1.x Evolution

- Transactional incident graph persistence
- Persistence authority finalization
- Cross-process idempotency
- Runtime producer provenance
- Expanded automated remediation
- Automated rollback verification
- Additional Dynatrace workflows
- OpenTelemetry correlation
- Additional Splunk SLOs

## Future Research

- Kubernetes evidence collectors
- Distributed tracing correlation
- Advanced eBPF diagnostics
- Automated dependency discovery
- ML-assisted RCA candidate ranking
