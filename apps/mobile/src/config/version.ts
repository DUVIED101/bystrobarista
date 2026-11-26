import { NativeModules } from 'react-native';

type AppInfoConstants = { version?: unknown; build?: unknown };

const UNKNOWN_VERSION = 'unknown';

export const parseBuildNumber = (raw: unknown): number | null => {
  if (typeof raw === 'number') return Number.isInteger(raw) && raw > 0 ? raw : null;
  if (typeof raw !== 'string' || !/^\d+$/.test(raw.trim())) return null;
  const build = Number(raw.trim());
  return Number.isSafeInteger(build) && build > 0 ? build : null;
};

export const formatVersionLabel = (version: string, build: number | null): string =>
  build === null ? version : `${version} (${build})`;

const readAppInfo = (): AppInfoConstants | undefined =>
  (NativeModules as { AppInfo?: AppInfoConstants }).AppInfo;

export const getAppVersion = (): string => {
  const version = readAppInfo()?.version;
  return typeof version === 'string' && version.trim().length > 0
    ? version.trim()
    : UNKNOWN_VERSION;
};

export const getAppBuild = (): number | null => parseBuildNumber(readAppInfo()?.build);

export const getAppVersionLabel = (): string => formatVersionLabel(getAppVersion(), getAppBuild());
