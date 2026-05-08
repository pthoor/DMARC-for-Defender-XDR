# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-05-08

### Added
- Added a repository audit deliverable at `docs/OPEN_SOURCE_READINESS_AUDIT.md` covering DMARC detection gaps, KQL correctness checks, release-readiness roadmap, and Graph query feasibility guidance.
- Added a root `VERSION` file for tenant-deployment-safe artifact version tracking.
- Added `tests/Versioning.Tests.ps1` to validate version metadata consistency and KQL safety guards.

### Changed
- Hardened workbook metric queries against null and divide-by-zero edge cases.
- Updated workbook header to include release metadata (`v1.1.0`).
- Bumped Sentinel detection rule versions to `1.1.0`.

### Fixed
- Corrected policy override detection entity mapping to use a scalar IP field.
- Corrected pass-rate logic in Azure Monitor pass-rate alert to use DMARC semantics (SPF **or** DKIM pass).
- Corrected alert and workbook query calculations for null handling, zero denominators, and safer join-key usage.
