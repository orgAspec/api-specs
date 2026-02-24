# OpenAPI Dependabot System

A comprehensive automation system for monitoring OpenAPI specifications, generating Ballerina connectors, and managing version updates across multiple repositories.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Components](#components)
- [Workflows](#workflows)
- [Setup](#setup)
- [Configuration](#configuration)
- [Versioning Strategies](#versioning-strategies)
- [How It Works](#how-it-works)
- [Troubleshooting](#troubleshooting)

---

## Overview

This system automatically:
1. **Monitors** OpenAPI specifications from multiple vendor repositories
2. **Detects** version changes and content updates
3. **Downloads** updated specifications to the api-specs repository
4. **Triggers** connector regeneration in individual connector repositories
5. **Analyzes** changes using Claude AI to determine semantic version bumps
6. **Creates** pull requests with detailed change summaries
7. **Sends** daily email reports summarizing all updates

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    api-specs Repository                          │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  OpenAPI Dependabot (Daily Cron)                           │ │
│  │  - Monitors vendor repos for spec updates                  │ │
│  │  - Downloads new/updated specs                             │ │
│  │  - Creates PR with changes                                 │ │
│  │  - Auto-merges via Auto Review & Merge workflow            │ │
│  └────────────────────────────────────────────────────────────┘ │
│                           │                                       │
│                           ▼                                       │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  After Auto-Merge: Trigger Connector Regeneration          │ │
│  │  - Sends repository_dispatch to connector repos            │ │
│  │  - Waits for connector PRs to be created                   │ │
│  │  - Collects PR information                                 │ │
│  │  - Sends consolidated email report                         │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                           │
                           │ repository_dispatch (openapi-update)
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│              Individual Connector Repositories                   │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Auto-Generate Connector                                    │ │
│  │  - Receives openapi_url from api-specs                     │ │
│  │  - Downloads spec and generates connector                  │ │
│  │  - Creates auto-generate-connector branch                  │ │
│  │  - Triggers version analysis                               │ │
│  └────────────────────────────────────────────────────────────┘ │
│                           │                                       │
│                           ▼                                       │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │  Analyze Version Change                                     │ │
│  │  - Compares main vs auto-generate-connector branch         │ │
│  │  - Uses Claude AI to analyze git diff                      │ │
│  │  - Determines MAJOR/MINOR/PATCH version bump               │ │
│  │  - Updates gradle.properties                               │ │
│  │  - Runs Gradle build to regenerate Ballerina files         │ │
│  │  - Creates PR with detailed change analysis                │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Dependabot Monitor (`main.bal`)

**Location:** `dependabot/main.bal`

**Purpose:** Core monitoring script that checks vendor repositories for OpenAPI specification updates.

**Key Features:**
- Supports multiple versioning strategies (release-tag, file-based)
- Downloads specs and calculates content hashes
- Maintains version history in `repos.json`
- Creates structured output for downstream workflows

**Configuration File:** `repos.json` (root directory)

### 2. Repository Configuration (`repos.json`)

**Location:** `../repos.json`

**Structure:**
```json
[
  {
    "vendor": "twilio",
    "api": "twilio",
    "owner": "twilio",
    "repo": "twilio-oai",
    "name": "Twilio API",
    "lastVersion": "v2024-10-07",
    "specPath": "spec/json/twilio_api_v2010.json",
    "releaseAssetName": "twilio_api_v2010.json",
    "baseUrl": "https://api.twilio.com",
    "documentationUrl": "https://www.twilio.com/docs/usage/api",
    "description": "Twilio REST API for voice, SMS, video and more",
    "tags": ["communication", "sms", "voice", "video"],
    "versioningStrategy": "release-tag",
    "connectorRepo": "orgBBalLib/module-ballerinax-twilio",
    "lastContentHash": "abc123..."
  }
]
```

### 3. Sorting Scripts

**Location:** `each connector repo/scripts/`

#### `sort_ballerina_client.bal`
Sorts resource methods in `client.bal` files by path and HTTP method while preserving all comments, whitespace, and non-method content.

#### `sort_ballerina_types.bal`
Sorts type definitions in `types.bal` files alphabetically while preserving all comments and structure.

#### `analyze_version_change.bal`
Uses Claude AI (Anthropic API) to analyze git diffs and determine semantic version changes.

**Features:**
- Analyzes changes in `client.bal` and `types.bal`
- Classifies changes as MAJOR, MINOR, or PATCH
- Identifies breaking changes, new features, and improvements
- Generates detailed analysis report

## Workflows

### 1. OpenAPI Dependabot (`openapi-dependabot.yml`)

**Location:** `.github/workflows/openapi-dependabot.yml` (in api-specs repo)

**Schedule:** Daily at 2:00 AM UTC (`cron: "0 2 * * *"`)

**Trigger:** Also supports manual dispatch

**Steps:**
1. Checkout api-specs repository
2. Set up Ballerina runtime
3. Run dependabot monitor with retries
4. Check for updates in `UPDATE_SUMMARY.txt`
5. Create branch and commit changes
6. Create pull request with update details
7. Wait for auto-merge to complete
8. Trigger connector regeneration for updated specs
9. Wait for connector PRs to be created
10. Collect PR information from all connectors
11. Generate HTML email with summary
12. Send consolidated daily email report

**Output Files:**
- `UPDATE_SUMMARY.txt`: List of updated specs (format: `vendor/api:version`)
- `repos.json`: Updated with new versions and content hashes
- `openapi/{vendor}/{api}/{version}/openapi.{json|yaml}`: Downloaded specs
- `connector_prs.json`: Summary of all connector PRs created

### 2. Auto Review & Merge (`auto-review-merge.yml`)

**Location:** `.github/workflows/auto-review-merge.yml` (in api-specs repo)

**Trigger:** On PR opened with label `openapi-update`

**Steps:**
1. Validate PR structure (only expected files changed)
2. Validate OpenAPI specifications (valid JSON, required fields)
3. Approve PR if all validations pass
4. Auto-merge using squash method
5. Comment on validation failures

**Validation Checks:**
- Only `openapi/`, `repos.json`, and `UPDATE_SUMMARY.txt` modified
- OpenAPI files are valid JSON/YAML
- Metadata files exist and are valid JSON
- All specs have required `openapi` and `info` fields

### 3. Auto-Generate Connector (`auto-generate-connector.yml`)

**Location:** `.github/workflows/auto-generate-connector.yml` (in connector repos)

**Trigger:** `repository_dispatch` event with type `openapi-update`

**Payload:**
```json
{
  "sender": "orgAspec/api-specs",
  "openapi_url": "https://raw.githubusercontent.com/orgAspec/api-specs/main/openapi/vendor/api/version/openapi.json",
  "spec_version": "1.0.0"
}
```

**Steps:**
1. Uses reusable workflow from `ballerina-library`
2. Downloads OpenAPI spec from provided URL
3. Generates Ballerina connector code
4. Creates `auto-generate-connector-{timestamp}` branch
5. Commits generated code
6. Triggers version analysis workflow

### 4. Analyze Version Change (`analyze-version-change.yml`)

**Location:** `.github/workflows/analyze-version-change.yml` (in connector repos)

**Trigger:** Dispatched by auto-generate-connector workflow

**Steps:**
1. Find latest `auto-generate-connector` branch
2. Generate git diff for `client.bal` and `types.bal`
3. Run Claude AI analysis on diff
4. Determine MAJOR/MINOR/PATCH version bump
5. Update `gradle.properties` with new version
6. Run Gradle build to regenerate `Ballerina.toml` and `Dependencies.toml`
7. Commit version changes
8. Create PR with detailed analysis

**AI Analysis Output:**
```json
{
  "changeType": "MINOR",
  "breakingChanges": [],
  "newFeatures": ["Added new endpoint for user management"],
  "bugFixes": ["Fixed type inconsistency in Response record"],
  "summary": "Added new features without breaking changes",
  "confidence": 0.95
}
```

## Setup

### Prerequisites

1. **GitHub Tokens:**
   - `GH_TOKEN` or `BALLERINA_BOT_TOKEN`: For api-specs operations
   - `REVIEWER_BOT_TOKEN`: For auto-review and merge
   - `CROSS_REPO_PAT`: For triggering connector workflows
   - `PAT_TOKEN`: For connector repository operations

2. **Email Configuration (Optional):**
   - `GMAIL_USERNAME`: Gmail address for sending reports
   - `GMAIL_APP_PASSWORD`: Gmail app password

3. **API Keys:**
   - `ANTHROPIC_API_KEY`: For Claude AI version analysis

### Installation

1. **Clone the api-specs repository:**
```bash
git clone https://github.com/orgAspec/api-specs.git
cd api-specs
```

2. **Install Ballerina:**
```bash
# Follow instructions at https://ballerina.io/downloads/
# Or use the GitHub Action in workflows
```

3. **Configure GitHub Secrets:**

In api-specs repository:
- `GH_TOKEN`
- `REVIEWER_BOT_TOKEN`
- `CROSS_REPO_PAT`
- `GMAIL_USERNAME` (optional)
- `GMAIL_APP_PASSWORD` (optional)

In each connector repository:
- `ANTHROPIC_API_KEY`
- `PAT_TOKEN`
- `BALLERINA_BOT_TOKEN`

4. **Enable GitHub Actions:**
- Ensure Actions are enabled in repository settings
- Set workflow permissions to read/write

## Configuration

### Adding a New Repository to Monitor

Edit `repos.json` and add a new entry:

```json
{
  "vendor": "vendor-name",
  "api": "api-name",
  "owner": "github-owner",
  "repo": "github-repo",
  "name": "Display Name",
  "lastVersion": "",
  "specPath": "path/to/openapi.json",
  "releaseAssetName": "openapi.json",
  "baseUrl": "https://api.example.com",
  "documentationUrl": "https://docs.example.com",
  "description": "Brief description",
  "tags": ["tag1", "tag2"],
  "versioningStrategy": "release-tag",
  "branch": "main",
  "connectorRepo": "orgBBalLib/module-ballerinax-example",
  "lastContentHash": ""
}
```

### Versioning Strategy Selection

Choose based on how the vendor manages their OpenAPI spec:

- **`release-tag`**: Vendor publishes specs as GitHub release assets
- **`file-based`**: Spec version is embedded in the file's `info.version` field
- **`rollout-based`**: Vendor uses rollout directories (e.g., HubSpot)

## Versioning Strategies

### 1. Release-Tag Strategy

**When to use:** Vendor publishes OpenAPI specs as GitHub release assets.

**Example:** Twilio, Stripe

**Configuration:**
```json
{
  "versioningStrategy": "release-tag",
  "releaseAssetName": "openapi.json",
  "specPath": "spec/openapi.json"
}
```

**Behavior:**
- Monitors latest GitHub release
- Downloads spec from release assets
- Falls back to raw GitHub URL if asset not found
- Version is determined by release tag

### 2. File-Based Strategy

**When to use:** Vendor maintains spec in a branch with version in `info.version`.

**Example:** Many APIs with stable specs

**Configuration:**
```json
{
  "versioningStrategy": "file-based",
  "branch": "main",
  "specPath": "openapi/spec.yaml"
}
```

**Behavior:**
- Downloads spec directly from specified branch
- Extracts version from `info.version` field in spec
- Detects both version changes and content changes
- Creates new version folder only when version changes

### 3. Rollout-Based Strategy

**When to use:** Vendor uses rollout directories (e.g., `Rollouts/148901/v4/spec.json`).

**Example:** HubSpot

**Configuration:**
```json
{
  "versioningStrategy": "rollout-based",
  "branch": "main",
  "specPath": "api-specs/Rollouts/148901/v4/crm.json"
}
```

**Behavior:**
- Finds latest rollout number dynamically
- Downloads spec from latest rollout directory
- Uses actual API version from spec (not rollout number)
- Replaces existing spec files when rollout changes

## How It Works

### Daily Monitoring Flow

```
02:00 UTC Daily
    ↓
OpenAPI Dependabot runs
    ↓
For each repo in repos.json:
    ↓
Download spec based on strategy
    ↓
Calculate content hash
    ↓
Compare version + hash with lastVersion + lastContentHash
    ↓
If changed:
    - Save spec to openapi/{vendor}/{api}/{version}/
    - Create .metadata.json
    - Update repos.json
    - Add to UPDATE_SUMMARY.txt
    ↓
Create PR with all changes
    ↓
Auto Review & Merge validates and merges
    ↓
Trigger connector regeneration for each updated spec
    ↓
Wait for connector PRs
    ↓
Collect PR information
    ↓
Send consolidated email report
```

### Connector Regeneration Flow

```
repository_dispatch received
    ↓
Auto-Generate Connector workflow starts
    ↓
Download OpenAPI spec from provided URL
    ↓
Generate Ballerina connector code
    ↓
Create auto-generate-connector branch
    ↓
Trigger Analyze Version Change workflow
    ↓
Generate git diff (client.bal + types.bal)
    ↓
Send diff to Claude AI for analysis
    ↓
Receive analysis:
    - changeType (MAJOR/MINOR/PATCH)
    - breakingChanges[]
    - newFeatures[]
    - bugFixes[]
    - summary
    ↓
Update gradle.properties version
    ↓
Run Gradle build
    ↓
Commit changes
    ↓
Create PR with analysis details
    ↓
Information sent back to api-specs for email report
```

### Version Analysis Rules

The Claude AI analysis follows these rules:

**MAJOR:** Breaking changes
- Removed or renamed methods
- Removed or renamed types
- Changed method signatures
- Changed field types
- Removed required fields

**MINOR:** Backward-compatible additions
- New methods
- New types
- New optional fields
- New optional parameters

**PATCH:** Internal changes
- Documentation updates
- Internal refactoring
- Bug fixes with no API surface changes

## Troubleshooting

### Monitor Script Issues

**Problem:** Monitor script fails to download specs

**Solution:**
- Check GitHub token is valid and has correct permissions
- Verify repository owner/name are correct
- Check if spec path exists in target repository
- Review network connectivity

**Problem:** Content hash keeps changing but content looks the same

**Solution:**
- Check for invisible characters or formatting differences
- Verify the spec format is stable (JSON vs YAML)
- Look for dynamic timestamps in the spec

### Workflow Issues

**Problem:** Auto-merge workflow doesn't trigger

**Solution:**
- Ensure PR has `openapi-update` label
- Check `REVIEWER_BOT_TOKEN` has required permissions
- Verify workflow is enabled in repository settings

**Problem:** Connector regeneration not triggered

**Solution:**
- Check `CROSS_REPO_PAT` is valid and has workflow dispatch permissions
- Verify `connectorRepo` field is correctly set in repos.json
- Check if connector repository has the workflow file
- Ensure spec URL is accessible (returns HTTP 200)

**Problem:** Version analysis creates wrong version bump

**Solution:**
- Review the git diff manually
- Check if Claude AI analysis is reasonable
- Update the prompt in `analyze_version_change.bal` if needed
- Consider edge cases in your API changes

### Email Issues

**Problem:** Email not received

**Solution:**
- Verify `GMAIL_USERNAME` and `GMAIL_APP_PASSWORD` secrets are set
- Check Gmail app password is correct (not regular password)
- Review spam folder
- Check workflow logs for email sending errors

**Problem:** Email contains incomplete information

**Solution:**
- Increase wait time in "Wait for connector updates" step
- Check if all connector repositories created PRs
- Review `connector_prs.json` artifact for data completeness

## File Structure

```
api-specs/
├── .github/
│   └── workflows/
│       ├── openapi-dependabot.yml
│       └── auto-review-merge.yml
├── dependabot/
│   ├── monitor.bal
│   ├── Ballerina.toml
│   ├── Dependencies.toml
│   ├── README.md (this file)
│   └── scripts/
│       ├── sort_ballerina_client.bal
│       ├── sort_ballerina_types.bal
│       └── analyze_version_change.bal
├── openapi/
│   └── {vendor}/
│       └── {api}/
│           └── {version}/
│               ├── openapi.json (or .yaml)
│               └── .metadata.json
├── repos.json
└── UPDATE_SUMMARY.txt (generated)

connector-repo/
├── .github/
│   └── workflows/
│       ├── auto-generate-connector.yml
│       └── analyze-version-change.yml
├── ballerina/
│   ├── client.bal (generated)
│   ├── types.bal (generated)
│   ├── Ballerina.toml (generated)
│   └── Dependencies.toml (generated)
├── gradle.properties
└── build.gradle
```

## Environment Variables

### api-specs Repository
- `GH_TOKEN`: Main GitHub token for operations
- `BALLERINA_BOT_TOKEN`: Alternative token name
- `GITHUB_TOKEN`: Alternative token name
- `REVIEWER_BOT_TOKEN`: Token for auto-review bot
- `CROSS_REPO_PAT`: Token for cross-repository operations
- `GMAIL_USERNAME`: Email sender address
- `GMAIL_APP_PASSWORD`: Gmail app-specific password

### Connector Repositories
- `ANTHROPIC_API_KEY`: Claude AI API key for analysis
- `PAT_TOKEN`: Personal access token for operations
- `BALLERINA_BOT_TOKEN`: Token for bot operations

## Best Practices

1. **Monitor logs regularly:** Review workflow runs for errors or warnings
2. **Test new repositories:** Add new repos one at a time to ensure proper configuration
3. **Keep tokens secure:** Rotate tokens periodically and use repository secrets
4. **Review auto-generated PRs:** Although automated, review PRs for accuracy
5. **Update documentation:** Keep repos.json comments and this README current
6. **Handle failures gracefully:** System continues even if individual operations fail

## Support

For issues or questions:
1. Check workflow logs in GitHub Actions tab
2. Review this README for common solutions
3. Check `connector_prs.json` artifact for debugging data
4. Contact the Ballerina team for assistance

---

**Last Updated:** 2026-02-24

**Maintained by:** Ballerina Team
