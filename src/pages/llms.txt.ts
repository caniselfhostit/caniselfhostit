/* /llms.txt — the whole catalogue as one plain-text file an agent can read in a
 * single fetch, per llmstxt.org: an H1, a one-paragraph description, then
 * sections of links with a short note each.
 *
 * Generated from getAllProjects(), the same call the HTML directory makes. It is
 * never hand-maintained: a hand-written index of a growing catalogue is a list
 * of pages that used to exist, and an agent that trusts it gets 404s. Add a
 * project to data/projects/ and it appears here on the next build or not at all.
 *
 * Every project link points at the `.md` mirror rather than the HTML page —
 * that file is the same facts with the chrome removed, and it is what the copy
 * block on the page deeplinks to (PRD §4.5).
 */
import type { APIRoute } from 'astro';
import { SITE } from '../lib/site.js';
import { getAllProjects } from '../lib/projects.js';

/** Hand-listed because these are the two pages that explain the rest. */
const CORE_LINKS = [
  {
    title: 'Prompt Zero',
    path: '/prompt-zero/',
    note: 'The one-time server setup every install prompt on this site assumes: a fresh VPS to a hardened box with Docker, a firewall, and SSH that works. Run this first.',
  },
  {
    title: 'Methodology',
    path: '/methodology/',
    note: 'How the setup tier is derived from seven countable factors, how prompts are tested on a clean machine, where prices come from, and what the labels do and do not claim.',
  },
];

export const GET: APIRoute = () => {
  const projects = getAllProjects();

  const lines = [
    `# ${SITE.name}`,
    '',
    SITE.description,
    '',
    '## Projects',
    '',
    ...projects.map(
      (p) => `- [${p.name}](${SITE.origin}/self-host/${p.slug}.md): ${p.tagline}`
    ),
    '',
    '## Core',
    '',
    ...CORE_LINKS.map((l) => `- [${l.title}](${SITE.origin}${l.path}): ${l.note}`),
    '',
    '## Optional',
    '',
    `- [About](${SITE.origin}/about/): Who maintains this and why it is free.`,
    `- [Contribute](${SITE.origin}/contribute/): How to correct a price, a prompt, or a verdict.`,
    `- [Source](${SITE.repoUrl}): The data, the prompts, and this site's code — all of it.`,
    '',
  ];

  return new Response(lines.join('\n'), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
