import {
  resolveAppUpdatePrompt,
  SOFT_UPDATE_PROMPT_INTERVAL_MS,
  type AppUpdatePrompt,
} from './appUpdate';

const NOW = new Date('2026-11-26T12:00:00.000Z');
const CURRENT = 86;
const NEWER = 87;
const OLDER = 85;
const ago = (ms: number): Date => new Date(NOW.getTime() - ms);

type Input = Parameters<typeof resolveAppUpdatePrompt>[0];

const BASE: Input = {
  currentBuild: CURRENT,
  latestBuild: null,
  minBuild: null,
  lastSoftPromptAt: null,
  now: NOW,
};

describe('resolveAppUpdatePrompt', () => {
  it.each<[string, Partial<Input>, AppUpdatePrompt]>([
    ['unknown current build', { currentBuild: null, latestBuild: NEWER, minBuild: NEWER }, 'none'],
    ['all flags null', {}, 'none'],
    ['latest equals current', { latestBuild: CURRENT }, 'none'],
    ['latest older than current', { latestBuild: OLDER }, 'none'],
    ['newer latest, never prompted', { latestBuild: NEWER }, 'soft'],
    [
      'newer latest, prompted exactly the interval ago',
      { latestBuild: NEWER, lastSoftPromptAt: ago(SOFT_UPDATE_PROMPT_INTERVAL_MS) },
      'soft',
    ],
    [
      'newer latest, prompted 1 ms short of the interval',
      { latestBuild: NEWER, lastSoftPromptAt: ago(SOFT_UPDATE_PROMPT_INTERVAL_MS - 1) },
      'none',
    ],
    ['min equals current', { minBuild: CURRENT }, 'none'],
    ['min above current', { minBuild: NEWER }, 'blocked'],
    [
      'min above current wins over a due soft prompt',
      { minBuild: NEWER, latestBuild: NEWER },
      'blocked',
    ],
    [
      'min above current even when soft prompt was recently dismissed',
      { minBuild: NEWER, latestBuild: NEWER, lastSoftPromptAt: ago(1) },
      'blocked',
    ],
  ])('returns the expected prompt for %s', (_label, override, expected) => {
    expect(resolveAppUpdatePrompt({ ...BASE, ...override })).toEqual(expected);
  });

  it('uses a three-day soft prompt interval', () => {
    const THREE_DAYS_MS = 259_200_000;
    expect(SOFT_UPDATE_PROMPT_INTERVAL_MS).toEqual(THREE_DAYS_MS);
  });
});
