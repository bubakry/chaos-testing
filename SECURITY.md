# Security Policy

## Reporting a Vulnerability

If you discover a security issue in this repository, please do **not** open a
public GitHub issue. Instead, open a [private security advisory](https://github.com/bubakry/chaos-testing/security/advisories/new)
on this repository.

Please include:

- A description of the issue and its impact
- Steps to reproduce, or a minimal proof of concept
- The commit SHA or release where the issue was observed
- Any relevant logs or scanner output

You will receive an initial acknowledgement within five business days. Coordinated
disclosure is appreciated; once a fix is merged we will credit reporters who
wish to be named.

## Supported Versions

This repository is a learning and demo project rather than a versioned
product. Only `main` is supported. Forks are encouraged to track upstream
`main` and rebase their customizations.

## Scope

In-scope findings include, but are not limited to:

- Vulnerabilities in the Terraform modules (privilege escalation, exposed
  network paths, IAM weaknesses, missing encryption)
- Issues in the Node.js sample application (dependency CVEs, injection,
  unsafe chaos endpoints exposed to untrusted networks)
- Defects in the deployment scripts that could affect the wrong account
  or destroy unintended resources

Out of scope:

- Findings that require modifying `aws/terraform.tfvars.example` to insecure
  values not used by the project itself
- Denial-of-service against the `chaos-api` service running locally — that
  is the sample's intended behavior under fault injection
- Social engineering or physical security
