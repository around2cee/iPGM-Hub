# iPGM Hub — Program Portfolio Sync Engine

The central hub of the iPGM Hub & Spoke model. Automatically aggregates all program repos
in the GitHub org into a single **iPGM Program Portfolio** board in GitHub Projects V2.

---

## How It Works

Each program repo (spoke) reports to this hub on every push. The hub runs a weekly sync
and on-demand, populating the portfolio board with program metadata and surfacing escalated issues.

```
Program Repos (Spokes)                      Hub
-----------------------                     ---
iPGM-Program-Alpha  --[push]--> repo-updated --> iPGM-hub --> iPGM Program Portfolio Board
iPGM-Program-Beta   --[push]--> repo-updated -->
Any new program     --[push]--> repo-updated -->
```

---

## Board Fields

| Field | Type | Updated By | Description |
|---|---|---|---|
| Status | Single Select | PGM (manual) | Todo / In Progress / Done |
| Phase | Single Select | PGM (manual) | Initiation / Planning / Execution / Go-Live / Monitoring / Closed |
| PEI Level | Single Select | PGM (manual) | High / Medium / Low engagement intensity |
| Program Manager | Text | PGM (manual) | Name of the assigned PGM |
| Language | Text | Auto-synced | GitHub-detected primary language |
| Visibility | Single Select | Auto-synced | Public or Private |
| Stars | Number | Auto-synced | Current stargazer count |
| Repo URL | Text | Auto-synced | Full GitHub URL |

> **Manual fields** (Status, Phase, PEI Level, Program Manager) are set to defaults on first sync
> and are never overwritten — PGMs update these directly on the board.

---

## Setup

### 1. PAT Requirements
Classic PAT (fine-grained PATs do not support Projects V2 mutations):

```
☑ repo        (read repo metadata)
☑ read:org    (list org repos)
☑ project     (create/update Projects V2)
☑ workflow    (push workflow files)
```

### 2. Org-Level Secret
Add `ORG_PORTFOLIO_TOKEN` at: `github.com/organizations/YOUR-ORG/settings/secrets/actions`
Set Repository access to **All repositories**.

### 3. Run First Sync
Go to `iPGM-hub` → Actions → **iPGM Portfolio Sync** → Run workflow

---

## Sync Triggers

| Trigger | Schedule | Purpose |
|---|---|---|
| Weekly cron | Every Monday 06:00 UTC | Baseline sync — catches any missed updates |
| workflow_dispatch | On demand | Manual runs, first-time setup |
| repository_dispatch | On every program repo push | Near-real-time updates |

---

## Flagging Issues to the Portfolio Board

Any open issue in any program repo tagged with the label **`portfolio-report`** is automatically
surfaced on the portfolio board as a linked item. The label is auto-created in every repo on first sync.

Use this for: blockers, escalations, key milestones, steering committee items.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| 401 Unauthorized | PAT expired or wrong scope | Regenerate PAT with all 4 scopes, update secret |
| INSUFFICIENT_SCOPES | Missing read:org | Edit PAT, add read:org |
| 403 Forbidden on repo creation | Missing repo scope | Add repo scope to PAT |
| Workflow push rejected | Missing workflow scope | Add workflow scope to PAT |
| Duplicate items | Repo renamed after first sync | Delete old item from board manually |
| Issue not appearing | Issue is closed or label is misspelled | Ensure issue is open + label is exactly portfolio-report |
