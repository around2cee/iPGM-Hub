/**
 * iPGM-hub/sync.js
 *
 * Hub & Spoke portfolio sync for the iPGM framework.
 * Syncs all org repos into an org-level GitHub Projects V2 board with
 * iPGM-specific fields: Phase, PEI Level, Program Manager, Status.
 * Also surfaces any issue labelled `portfolio-report` as a linked item.
 *
 * Requirements:
 *   - Node >= 18 (native fetch)
 *   - Env: ORG_PORTFOLIO_TOKEN  (classic PAT: repo, read:org, project, workflow)
 *   - Env: ORG_NAME             (e.g. Chas-Test-Org)
 */

const TOKEN   = process.env.ORG_PORTFOLIO_TOKEN;
const ORG     = process.env.ORG_NAME;
const PROJECT_TITLE     = 'iPGM Program Portfolio';
const LABEL_NAME        = 'portfolio-report';
const LABEL_COLOR       = '0075ca';
const LABEL_DESCRIPTION = 'Surface this issue in the iPGM portfolio board';

if (!TOKEN || !ORG) {
  console.error('ERROR: ORG_PORTFOLIO_TOKEN and ORG_NAME must be set.');
  process.exit(1);
}

// ---------------------------------------------------------------------------
// GraphQL HTTP helper
// ---------------------------------------------------------------------------

async function graphql(query, variables = {}) {
  const res = await fetch('https://api.github.com/graphql', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${TOKEN}`,
      'Content-Type': 'application/json',
      'User-Agent': 'ipgm-hub-sync/2.0',
    },
    body: JSON.stringify({ query, variables }),
  });

  const json = await res.json();
  if (json.errors) {
    throw new Error(`GraphQL errors:\n${JSON.stringify(json.errors, null, 2)}`);
  }
  return json.data;
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

async function getOrgId(org) {
  const data = await graphql(`
    query GetOrgId($org: String!) {
      organization(login: $org) { id }
    }
  `, { org });
  return data.organization.id;
}

async function getAllRepos(org) {
  const repos = [];
  let cursor = null;

  do {
    const data = await graphql(`
      query ListOrgRepos($org: String!, $cursor: String) {
        organization(login: $org) {
          repositories(first: 100, after: $cursor, orderBy: { field: NAME, direction: ASC }) {
            pageInfo { hasNextPage endCursor }
            nodes {
              id
              name
              description
              url
              primaryLanguage { name }
              isPrivate
              stargazerCount
            }
          }
        }
      }
    `, { org, cursor });

    const page = data.organization.repositories;
    repos.push(...page.nodes);
    cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (cursor);

  return repos;
}

async function findOrCreateProject(org, orgId) {
  const data = await graphql(`
    query FindProject($org: String!) {
      organization(login: $org) {
        projectsV2(first: 20) {
          nodes { id title }
        }
      }
    }
  `, { org });

  const existing = data.organization.projectsV2.nodes.find(
    p => p.title === PROJECT_TITLE
  );
  if (existing) {
    console.log(`  Found existing project: "${PROJECT_TITLE}" (${existing.id})`);
    return existing.id;
  }

  const created = await graphql(`
    mutation CreateProject($ownerId: ID!, $title: String!) {
      createProjectV2(input: { ownerId: $ownerId, title: $title }) {
        projectV2 { id title }
      }
    }
  `, { ownerId: orgId, title: PROJECT_TITLE });

  const projectId = created.createProjectV2.projectV2.id;
  console.log(`  Created project: "${PROJECT_TITLE}" (${projectId})`);
  return projectId;
}

async function getProjectFields(projectId) {
  const data = await graphql(`
    query GetProjectFields($projectId: ID!) {
      node(id: $projectId) {
        ... on ProjectV2 {
          fields(first: 25) {
            nodes {
              ... on ProjectV2Field {
                id name dataType
              }
              ... on ProjectV2SingleSelectField {
                id name dataType
                options { id name }
              }
            }
          }
        }
      }
    }
  `, { projectId });

  return data.node.fields.nodes;
}

// ---------------------------------------------------------------------------
// iPGM Field Definitions
//
// Manual fields (set on creation only — never auto-overwritten):
//   Status, Phase, PEI Level, Program Manager
//
// Auto-sync fields (always updated from GitHub metadata):
//   Language, Visibility, Stars, Repo URL
// ---------------------------------------------------------------------------

const DESIRED_FIELDS = [
  { name: 'Status', dataType: 'SINGLE_SELECT', manual: true, options: [
    { name: 'Todo',        color: 'GRAY'   },
    { name: 'In Progress', color: 'YELLOW' },
    { name: 'Done',        color: 'GREEN'  },
  ]},
  { name: 'Phase', dataType: 'SINGLE_SELECT', manual: true, options: [
    { name: 'Initiation', color: 'BLUE'   },
    { name: 'Planning',   color: 'PURPLE' },
    { name: 'Execution',  color: 'YELLOW' },
    { name: 'Go-Live',    color: 'ORANGE' },
    { name: 'Monitoring', color: 'GREEN'  },
    { name: 'Closed',     color: 'GRAY'   },
  ]},
  { name: 'PEI Level', dataType: 'SINGLE_SELECT', manual: true, options: [
    { name: 'High',   color: 'RED'    },
    { name: 'Medium', color: 'YELLOW' },
    { name: 'Low',    color: 'GREEN'  },
  ]},
  { name: 'Program Manager', dataType: 'TEXT',   manual: true  },
  { name: 'Language',        dataType: 'TEXT',   manual: false },
  { name: 'Visibility', dataType: 'SINGLE_SELECT', manual: false, options: [
    { name: 'Public',  color: 'GREEN' },
    { name: 'Private', color: 'GRAY'  },
  ]},
  { name: 'Stars',    dataType: 'NUMBER', manual: false },
  { name: 'Repo URL', dataType: 'TEXT',   manual: false },
];

async function ensureFields(projectId) {
  const existing = await getProjectFields(projectId);
  const existingByName = Object.fromEntries(existing.map(f => [f.name, f]));
  const fieldMap = {};

  for (const desired of DESIRED_FIELDS) {
    let field = existingByName[desired.name];

    if (!field) {
      const isSingleSelect = desired.dataType === 'SINGLE_SELECT';
      const variables = {
        projectId,
        name: desired.name,
        dataType: desired.dataType,
        ...(isSingleSelect && {
          options: desired.options.map(o => ({ name: o.name, color: o.color, description: '' })),
        }),
      };

      const result = await graphql(`
        mutation CreateField(
          $projectId: ID!
          $name: String!
          $dataType: ProjectV2CustomFieldType!
          $options: [ProjectV2SingleSelectFieldOptionInput!]
        ) {
          createProjectV2Field(input: {
            projectId: $projectId
            name: $name
            dataType: $dataType
            singleSelectOptions: $options
          }) {
            projectV2Field {
              ... on ProjectV2Field { id name dataType }
              ... on ProjectV2SingleSelectField { id name dataType options { id name } }
            }
          }
        }
      `, variables);

      field = result.createProjectV2Field.projectV2Field;
      console.log(`  Created field: "${desired.name}"`);
    }

    if (desired.dataType === 'SINGLE_SELECT' && desired.options) {
      const existingOptionNames = new Set((field.options ?? []).map(o => o.name));
      const needsUpdate = desired.options.some(o => !existingOptionNames.has(o.name));

      if (needsUpdate) {
        const updated = await graphql(`
          mutation SetSelectOptions($projectId: ID!, $fieldId: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]!) {
            updateProjectV2Field(input: {
              projectId: $projectId
              fieldId: $fieldId
              singleSelectOptions: $options
            }) {
              projectV2Field {
                ... on ProjectV2SingleSelectField { id options { id name } }
              }
            }
          }
        `, {
          projectId,
          fieldId: field.id,
          options: desired.options.map(o => ({
            name: o.name,
            color: o.color,
            description: '',
          })),
        });
        field = updated.updateProjectV2Field.projectV2Field;
        console.log(`  Updated options on "${desired.name}"`);
      }
    }

    const entry = { id: field.id, dataType: desired.dataType, manual: desired.manual };
    if (desired.dataType === 'SINGLE_SELECT') {
      entry.options = Object.fromEntries((field.options ?? []).map(o => [o.name, o.id]));
    }
    fieldMap[desired.name] = entry;
  }

  return fieldMap;
}

async function getAllItems(projectId) {
  const itemMap = new Map();
  let cursor = null;

  do {
    const data = await graphql(`
      query GetProjectItems($projectId: ID!, $cursor: String) {
        node(id: $projectId) {
          ... on ProjectV2 {
            items(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                id
                content {
                  ... on DraftIssue { title }
                  ... on Issue { url }
                }
              }
            }
          }
        }
      }
    `, { projectId, cursor });

    const page = data.node.items;
    for (const item of page.nodes) {
      const key = item.content?.title ?? item.content?.url;
      if (key) itemMap.set(key, item.id);
    }
    cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (cursor);

  return itemMap;
}

// ---------------------------------------------------------------------------
// Mutations
// ---------------------------------------------------------------------------

async function setFieldValue(projectId, itemId, field, value) {
  let valueInput;
  if (field.dataType === 'TEXT')               valueInput = { text: String(value) };
  else if (field.dataType === 'NUMBER')        valueInput = { number: Number(value) };
  else if (field.dataType === 'SINGLE_SELECT') {
    const optionId = field.options[value];
    if (!optionId) return;
    valueInput = { singleSelectOptionId: optionId };
  } else {
    return;
  }

  await graphql(`
    mutation UpdateFieldValue($projectId: ID!, $itemId: ID!, $fieldId: ID!, $value: ProjectV2FieldValue!) {
      updateProjectV2ItemFieldValue(input: {
        projectId: $projectId
        itemId: $itemId
        fieldId: $fieldId
        value: $value
      }) {
        projectV2Item { id }
      }
    }
  `, { projectId, itemId, fieldId: field.id, value: valueInput });
}

async function upsertRepo(projectId, fieldMap, itemMap, repo) {
  const isNew = !itemMap.has(repo.name);
  let itemId;

  if (isNew) {
    const result = await graphql(`
      mutation AddDraftIssue($projectId: ID!, $title: String!, $body: String!) {
        addProjectV2DraftIssue(input: { projectId: $projectId, title: $title, body: $body }) {
          projectItem { id }
        }
      }
    `, {
      projectId,
      title: repo.name,
      body: repo.description ?? '',
    });
    itemId = result.addProjectV2DraftIssue.projectItem.id;
    itemMap.set(repo.name, itemId);
  } else {
    itemId = itemMap.get(repo.name);
  }

  // Auto-sync metadata fields (always updated)
  await setFieldValue(projectId, itemId, fieldMap['Language'],   repo.primaryLanguage?.name ?? '');
  await setFieldValue(projectId, itemId, fieldMap['Repo URL'],   repo.url);
  await setFieldValue(projectId, itemId, fieldMap['Stars'],      repo.stargazerCount);
  await setFieldValue(projectId, itemId, fieldMap['Visibility'], repo.isPrivate ? 'Private' : 'Public');

  // Manual fields — set defaults on new items only, never overwrite on existing
  if (isNew) {
    await setFieldValue(projectId, itemId, fieldMap['Status'], 'Todo');
    await setFieldValue(projectId, itemId, fieldMap['Phase'],  'Initiation');
    // PEI Level and Program Manager are left blank — PGM fills these in on the board
  }

  return isNew;
}

// ---------------------------------------------------------------------------
// Label management
// ---------------------------------------------------------------------------

async function ensurePortfolioLabel(org, repos) {
  for (const repo of repos) {
    const res = await fetch(
      `https://api.github.com/repos/${org}/${repo.name}/labels`,
      {
        headers: {
          Authorization: `Bearer ${TOKEN}`,
          'User-Agent': 'ipgm-hub-sync/2.0',
          Accept: 'application/vnd.github+json',
        },
      }
    );

    if (!res.ok) continue;

    const labels = await res.json();
    const exists = labels.some(l => l.name === LABEL_NAME);
    if (exists) continue;

    await fetch(`https://api.github.com/repos/${org}/${repo.name}/labels`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${TOKEN}`,
        'User-Agent': 'ipgm-hub-sync/2.0',
        Accept: 'application/vnd.github+json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        name: LABEL_NAME,
        color: LABEL_COLOR,
        description: LABEL_DESCRIPTION,
      }),
    });

    console.log(`  Created label "${LABEL_NAME}" in ${repo.name}`);
  }
}

// ---------------------------------------------------------------------------
// Flagged issue sync
// ---------------------------------------------------------------------------

async function getFlaggedIssues(org) {
  const issues = [];
  let cursor = null;

  do {
    const data = await graphql(`
      query GetFlaggedIssues($query: String!, $cursor: String) {
        search(query: $query, type: ISSUE, first: 100, after: $cursor) {
          pageInfo { hasNextPage endCursor }
          nodes {
            ... on Issue {
              id
              title
              url
              number
              repository { name }
            }
          }
        }
      }
    `, {
      query: `org:${org} label:${LABEL_NAME} is:issue is:open`,
      cursor,
    });

    const page = data.search;
    issues.push(...page.nodes.filter(n => n.id));
    cursor = page.pageInfo.hasNextPage ? page.pageInfo.endCursor : null;
  } while (cursor);

  return issues;
}

async function syncFlaggedIssues(projectId, itemMap, issues) {
  let added = 0;

  for (const issue of issues) {
    if (itemMap.has(issue.url)) continue;

    const result = await graphql(`
      mutation AddIssueToProject($projectId: ID!, $contentId: ID!) {
        addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
          item { id }
        }
      }
    `, { projectId, contentId: issue.id });

    itemMap.set(issue.url, result.addProjectV2ItemById.item.id);
    console.log(`  + Issue added: [${issue.repository.name}#${issue.number}] ${issue.title}`);
    added++;
  }

  return added;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  console.log(`\niPGM Hub & Spoke Portfolio Sync\nOrg: ${ORG}\nProject: "${PROJECT_TITLE}"\n`);

  console.log('Fetching org ID...');
  const orgId = await getOrgId(ORG);

  console.log('Fetching all repos...');
  const repos = await getAllRepos(ORG);
  console.log(`  Found ${repos.length} repos`);

  console.log('Finding or creating iPGM portfolio project...');
  const projectId = await findOrCreateProject(ORG, orgId);

  console.log('Ensuring iPGM custom fields...');
  const fieldMap = await ensureFields(projectId);

  console.log('Ensuring portfolio-report label in all repos...');
  await ensurePortfolioLabel(ORG, repos);

  console.log('Loading existing project items...');
  const itemMap = await getAllItems(projectId);

  console.log('Syncing program repos...');
  let created = 0;
  let updated = 0;
  for (const repo of repos) {
    const isNew = await upsertRepo(projectId, fieldMap, itemMap, repo);
    if (isNew) { created++; console.log(`  + Program added: ${repo.name}`); }
    else        { updated++; }
  }

  console.log('Fetching flagged issues...');
  const issues = await getFlaggedIssues(ORG);
  console.log(`  Found ${issues.length} issue(s) labelled "${LABEL_NAME}"`);

  console.log('Syncing flagged issues...');
  const issuesAdded = await syncFlaggedIssues(projectId, itemMap, issues);

  console.log(`
Done.
  Programs  -- created: ${created}, updated: ${updated}
  Issues    -- added:   ${issuesAdded}

Board fields:
  Auto-synced : Language, Visibility, Stars, Repo URL
  Manual (PGM): Status, Phase, PEI Level, Program Manager
`);
}

main().catch(err => {
  console.error(err.message);
  process.exit(1);
});
