# Autonomous SRE RCA Platform — Architecture

## High-Level Architecture

```text
Prometheus / Alertmanager ----+
                              |
Splunk -----------------------+--> n8n Orchestration
                              |          |
Dynatrace --------------------+          v
                                  Evidence / RCA Layer
                                          |
                         +----------------+----------------+
                         |                |                |
                       Linux             eBPF            Splunk
                         |                |                |
                         +----------------+----------------+
                                          |
                                          v
                                      Normalize
                                          |
                                          v
                                      Correlate
                                          |
                                          v
                                  Causal Analysis
                                          |
                                          v
                                   Incident Policy
                                          |
                    +---------------------+--------------------+
                    |                     |                    |
                    v                     v                    v
               ServiceNow            PagerDuty              Slack
                                          |
                                          v
                                     AWX / Ansible
                                          |
                                          v
                                      Remediation
                                          |
                                          v
                                      Verification
                                          |
                                          v
                                  SLI / SLO / MTTR
## Engineering Principle

The platform separates technical facts from operational decisions.

FACT -> CORRELATION -> CAUSAL CANDIDATE -> INCIDENT POLICY -> CONTROLLED ACTION

An alert does not directly authorize remediation.

## Evidence Domains

The evidence layer evaluates:

- CPU, memory, disk I/O and network
- Linux and eBPF host evidence
- Splunk infrastructure and cluster evidence
- Prometheus infrastructure signals
- Dynatrace application and service signals

## Incident Orchestration

n8n orchestrates the workflow between monitoring, evidence validation and operational response.

Alert -> Validate -> Evidence -> Correlate -> RCA -> Incident -> Notify -> Remediate -> Verify
## SRE Feedback Loop

Automation continues after remediation:

Detect -> Diagnose -> Remediate -> Verify -> Measure -> Improve

Recovery is validated through observable SLIs, SLOs and MTTR measurements.

## Safety Model

The architecture follows fail-closed principles:

- unavailable evidence remains unavailable
- malformed evidence is rejected
- correlation does not automatically imply causation
- causal candidates do not directly execute remediation
- automated actions require validated preconditions

## CI/CD Relationship

Code -> Pull Request -> Validate -> Test -> Release -> Deploy -> Observe -> SLO Gate

The SLO gate connects CI/CD with production reliability:

- PASS: promote the release
- FAIL: rollback or escalate
