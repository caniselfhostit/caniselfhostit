// Every brand and domain string on the site lives here — nowhere else.
// (The sibling project hardcodes its domain across ~22 files; that fork tax
// gets paid exactly once, by this module existing.)

export const SITE = {
  domain: 'caniselfhostit.com',
  origin: 'https://caniselfhostit.com',
  name: 'Can I Self-Host It?',
  shortName: 'caniselfhostit',
  tagline: 'One prompt to get ready. One prompt per app.',
  promise: 'Every prompt assumes nothing is installed. Not even git.',
  description:
    'For every SaaS you pay for: a mature open-source replacement, and the exact AI-agent prompts that install it on your own server — starting from a machine with nothing on it.',
  // Campaign domain; 301s to the canonical origin (configured at the zone, Phase 3).
  redirectDomains: ['dontvibecodeit.com'],
  repoUrl: 'https://github.com/caniselfhostit/caniselfhostit',
  author: {
    name: 'Jashanpreet Singh',
    url: '/about/',
  },
  // Independent, credited sibling — a different operator, not a network.
  // Credit appears on /about and /methodology only (never sitewide footers).
  inspiredBy: { name: 'canivibecodeit.com', url: 'https://canivibecodeit.com' },
};

// Title verdict word is DERIVED from the setup tier (PRD §0) — never hand-written.
export const TIER_VERDICTS = {
  'one-command': 'YES',
  'one-evening': 'YES',
  'one-weekend': 'YES, BUT',
  'ongoing-ops': 'YES, IF',
};

/**
 * The question is asked about the PAID app; the answer names the replacement:
 * "Can I self-host Miro? YES — it's called Excalidraw (2026)".
 * The narrative protagonist is the thing you're paying for.
 */
export function pageTitle(saasName, tier, replacementName) {
  const year = new Date().getFullYear();
  const verdict = TIER_VERDICTS[tier] ?? 'YES';
  const called = replacementName ? ` — it's called ${replacementName}` : '';
  return `Can I self-host ${saasName}? ${verdict}${called} (${year})`;
}
