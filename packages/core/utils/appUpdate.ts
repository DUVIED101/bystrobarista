export const SOFT_UPDATE_PROMPT_INTERVAL_MS = 3 * 24 * 60 * 60 * 1000;

export type AppUpdatePrompt = 'none' | 'soft' | 'blocked';

export const resolveAppUpdatePrompt = (input: {
  currentBuild: number | null;
  latestBuild: number | null;
  minBuild: number | null;
  lastSoftPromptAt: Date | null;
  now: Date;
}): AppUpdatePrompt => {
  const { currentBuild, latestBuild, minBuild, lastSoftPromptAt, now } = input;
  if (currentBuild === null) return 'none';
  if (minBuild !== null && currentBuild < minBuild) return 'blocked';
  const softPromptDue =
    lastSoftPromptAt === null ||
    now.getTime() - lastSoftPromptAt.getTime() >= SOFT_UPDATE_PROMPT_INTERVAL_MS;
  if (latestBuild !== null && currentBuild < latestBuild && softPromptDue) return 'soft';
  return 'none';
};
