import type { WorkExperience } from '@bystrobarista/core/types/workExperience';
import type { BaristaProfileId, WorkExperienceId } from '@bystrobarista/core/types/ids';
import { MIN_PROFILE_COMPLETENESS } from '../config/profile';
import { METRO_ANY } from '../config/metroFilter';
import {
  formatMissingFields,
  getProfileVisibility,
  type ProfileField,
  type ProfileVisibilityInput,
} from './profileVisibility';

const NOW = new Date(2026, 10, 26, 12, 0, 0);
const MEDICAL_BOOK_VALID_UNTIL = '2027-05-01';
const MEDICAL_BOOK_EXPIRED_ON = '2026-11-25';
const BIO_MIN_LENGTH = 20;

const WORK_EXPERIENCE: WorkExperience = {
  id: 'we-1' as WorkExperienceId,
  baristaProfileId: 'bp-1' as BaristaProfileId,
  employer: 'Surf Coffee',
  position: 'Barista',
  startYear: 2023,
  startMonth: 3,
  endYear: null,
  endMonth: null,
  isCurrent: true,
  description: null,
  sortOrder: 0,
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt: '2026-01-01T00:00:00.000Z',
};

const COMPLETE_PROFILE: ProfileVisibilityInput = {
  firstName: 'Анна',
  lastName: 'Петрова',
  city: 'moscow',
  bio: 'Люблю альтернативу и латте-арт',
  yearsOfExperience: 3,
  equipmentExperience: ['La Marzocco'],
  workExperiences: [WORK_EXPERIENCE],
  preferredMetroStations: ['Чистые пруды'],
  preferredShiftTimes: ['morning'],
  hourlyRateMin: 350,
  hourlyRateMax: undefined,
  portfolioPhotos: ['photos/1.jpg'],
  medicalBookExpiresOn: MEDICAL_BOOK_VALID_UNTIL,
  isActivelyLooking: true,
  profileCompleteness: 100,
};

const EMPTY_PROFILE: ProfileVisibilityInput = {
  firstName: '',
  lastName: '',
  city: '' as ProfileVisibilityInput['city'],
  bio: undefined,
  yearsOfExperience: undefined,
  equipmentExperience: [],
  workExperiences: undefined,
  preferredMetroStations: [],
  preferredShiftTimes: [],
  hourlyRateMin: undefined,
  hourlyRateMax: undefined,
  portfolioPhotos: [],
  medicalBookExpiresOn: undefined,
  isActivelyLooking: true,
  profileCompleteness: 0,
};

const ALL_FIELDS_BY_WEIGHT: ProfileField[] = [
  'name',
  'experience',
  'metroStations',
  'bio',
  'workHistory',
  'hourlyRate',
  'portfolioPhotos',
  'medicalBook',
];

describe('getProfileVisibility', () => {
  it.each([
    [MIN_PROFILE_COMPLETENESS - 1, { visible: false, reasons: ['below_threshold'] }],
    [MIN_PROFILE_COMPLETENESS, { visible: true, reasons: [] }],
    [MIN_PROFILE_COMPLETENESS + 1, { visible: true, reasons: [] }],
  ])(
    'returns visibility %j for completeness at the threshold boundary',
    (completeness, expected) => {
      expect(
        getProfileVisibility({ ...COMPLETE_PROFILE, profileCompleteness: completeness }, NOW)
      ).toEqual({ ...expected, missing: [] });
    }
  );

  it('returns not_looking when the barista turned off "looking for work"', () => {
    expect(getProfileVisibility({ ...COMPLETE_PROFILE, isActivelyLooking: false }, NOW)).toEqual({
      visible: false,
      reasons: ['not_looking'],
      missing: [],
    });
  });

  it('returns both reasons and every field, ordered by weight, for an empty hidden profile', () => {
    expect(getProfileVisibility({ ...EMPTY_PROFILE, isActivelyLooking: false }, NOW)).toEqual({
      visible: false,
      reasons: ['not_looking', 'below_threshold'],
      missing: ALL_FIELDS_BY_WEIGHT,
    });
  });

  it.each<[ProfileField, Partial<ProfileVisibilityInput>]>([
    ['name', { firstName: '' }],
    ['name', { lastName: '   ' }],
    ['name', { city: '' as ProfileVisibilityInput['city'] }],
    ['experience', { yearsOfExperience: undefined }],
    ['experience', { equipmentExperience: [] }],
    ['experience', { yearsOfExperience: undefined, equipmentExperience: [] }],
    ['metroStations', { preferredMetroStations: [] }],
    ['metroStations', { preferredShiftTimes: [] }],
    ['metroStations', { preferredMetroStations: [], preferredShiftTimes: [] }],
    ['bio', { bio: undefined }],
    ['bio', { bio: 'а'.repeat(BIO_MIN_LENGTH - 1) }],
    ['workHistory', { workExperiences: [] }],
    ['workHistory', { workExperiences: undefined }],
    ['hourlyRate', { hourlyRateMin: undefined, hourlyRateMax: undefined }],
    ['portfolioPhotos', { portfolioPhotos: [] }],
    ['medicalBook', { medicalBookExpiresOn: undefined }],
    ['medicalBook', { medicalBookExpiresOn: MEDICAL_BOOK_EXPIRED_ON }],
  ])('reports only %s as missing for override %j', (field, override) => {
    expect(getProfileVisibility({ ...COMPLETE_PROFILE, ...override }, NOW).missing).toEqual([
      field,
    ]);
  });

  it.each<[string, Partial<ProfileVisibilityInput>]>([
    ['zero years of experience', { yearsOfExperience: 0 }],
    ['the "any station" sentinel', { preferredMetroStations: [METRO_ANY] }],
    ['a bio of exactly the minimum length', { bio: 'а'.repeat(BIO_MIN_LENGTH) }],
    ['only the max hourly rate', { hourlyRateMin: undefined, hourlyRateMax: 500 }],
    ['a medical book expiring today', { medicalBookExpiresOn: '2026-11-26' }],
  ])('treats %s as filled', (_label, override) => {
    expect(getProfileVisibility({ ...COMPLETE_PROFILE, ...override }, NOW).missing).toEqual([]);
  });

  it('orders missing fields by weight regardless of which are filled', () => {
    expect(
      getProfileVisibility(
        {
          ...COMPLETE_PROFILE,
          portfolioPhotos: [],
          preferredMetroStations: [],
          bio: undefined,
          firstName: '',
        },
        NOW
      ).missing
    ).toEqual(['name', 'metroStations', 'bio', 'portfolioPhotos']);
  });
});

describe('formatMissingFields', () => {
  const LABELS: Record<string, string> = {
    'profileVisibility.fields.metroStations': 'станции метро',
    'profileVisibility.fields.bio': 'пару слов о себе',
    'profileVisibility.fields.portfolioPhotos': 'фото',
    'profileVisibility.and': ' и ',
  };
  const t = (key: string): string => LABELS[key] ?? key;

  it.each<[ProfileField[], number | undefined, string]>([
    [[], undefined, ''],
    [['portfolioPhotos'], undefined, 'фото'],
    [['portfolioPhotos', 'metroStations'], undefined, 'фото и станции метро'],
    [['portfolioPhotos', 'metroStations', 'bio'], undefined, 'фото и станции метро'],
    [['portfolioPhotos', 'metroStations', 'bio'], 3, 'фото и станции метро и пару слов о себе'],
    [['portfolioPhotos', 'metroStations'], 1, 'фото'],
  ])('formats %j with limit %p as %p', (missing, limit, expected) => {
    expect(formatMissingFields(missing, t, limit)).toEqual(expected);
  });
});
