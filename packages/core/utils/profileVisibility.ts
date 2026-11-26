import type { BaristaProfile } from '@bystrobarista/core/types/baristaProfile';
import { MIN_PROFILE_COMPLETENESS } from '../config/profile';
import { computeMedicalBookStatus } from './medicalBook';

export type ProfileField =
  | 'name'
  | 'experience'
  | 'metroStations'
  | 'bio'
  | 'workHistory'
  | 'hourlyRate'
  | 'portfolioPhotos'
  | 'medicalBook';

export type ProfileHiddenReason = 'not_looking' | 'below_threshold';

export type ProfileVisibility = {
  visible: boolean;
  reasons: ProfileHiddenReason[];
  missing: ProfileField[];
};

export type ProfileVisibilityInput = Pick<
  BaristaProfile,
  | 'firstName'
  | 'lastName'
  | 'city'
  | 'bio'
  | 'yearsOfExperience'
  | 'equipmentExperience'
  | 'workExperiences'
  | 'preferredMetroStations'
  | 'preferredShiftTimes'
  | 'hourlyRateMin'
  | 'hourlyRateMax'
  | 'portfolioPhotos'
  | 'medicalBookExpiresOn'
  | 'isActivelyLooking'
  | 'profileCompleteness'
>;

const BIO_MIN_LENGTH = 20;

const isFilledText = (value: string | undefined): boolean =>
  typeof value === 'string' && value.trim().length > 0;

const isNonEmptyArray = (value: readonly unknown[] | undefined): boolean =>
  Array.isArray(value) && value.length > 0;

// Mirrors trigger_update_profile_completeness (migration 103); ordered by weight desc.
const FIELD_CHECKS: [ProfileField, (profile: ProfileVisibilityInput, now: Date) => boolean][] = [
  ['name', p => isFilledText(p.firstName) && isFilledText(p.lastName) && isFilledText(p.city)],
  [
    'experience',
    p => typeof p.yearsOfExperience === 'number' && isNonEmptyArray(p.equipmentExperience),
  ],
  [
    'metroStations',
    p => isNonEmptyArray(p.preferredMetroStations) && isNonEmptyArray(p.preferredShiftTimes),
  ],
  ['bio', p => typeof p.bio === 'string' && p.bio.trim().length >= BIO_MIN_LENGTH],
  ['workHistory', p => isNonEmptyArray(p.workExperiences)],
  ['hourlyRate', p => typeof p.hourlyRateMin === 'number' || typeof p.hourlyRateMax === 'number'],
  ['portfolioPhotos', p => isNonEmptyArray(p.portfolioPhotos)],
  [
    'medicalBook',
    (p, now) => {
      const status = computeMedicalBookStatus(p.medicalBookExpiresOn, now);
      return status === 'valid' || status === 'expiringSoon';
    },
  ],
];

export const getProfileVisibility = (
  profile: ProfileVisibilityInput,
  now: Date = new Date()
): ProfileVisibility => {
  const reasons: ProfileHiddenReason[] = [];
  if (!profile.isActivelyLooking) reasons.push('not_looking');
  if (profile.profileCompleteness < MIN_PROFILE_COMPLETENESS) reasons.push('below_threshold');
  const missing = FIELD_CHECKS.filter(([, isFilled]) => !isFilled(profile, now)).map(
    ([field]) => field
  );
  return { visible: reasons.length === 0, reasons, missing };
};

export const formatMissingFields = (
  missing: ProfileField[],
  t: (key: string) => string,
  limit = 2
): string =>
  missing
    .slice(0, limit)
    .map(field => t(`profileVisibility.fields.${field}`))
    .join(t('profileVisibility.and'));
