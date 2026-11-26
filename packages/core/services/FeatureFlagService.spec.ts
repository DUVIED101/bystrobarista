const mockMaybeSingle = jest.fn();
const mockEq = jest.fn(() => ({ maybeSingle: mockMaybeSingle }));
const mockSelect = jest.fn(() => ({ eq: mockEq }));
const mockFrom = jest.fn(() => ({ select: mockSelect }));

jest.mock('../config/supabase', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...(args as [])) },
}));

// Import after jest.mock so the service receives the mocked client.
import { FeatureFlagService } from './FeatureFlagService';

const FLAG_KEY = 'latest_ios_build';
const BUILD = 87;

describe('getNumber', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  it('reads the value column of the requested flag row', async () => {
    mockMaybeSingle.mockResolvedValue({ data: { value: BUILD }, error: null });

    await FeatureFlagService.getNumber(FLAG_KEY);

    expect([mockFrom.mock.calls, mockSelect.mock.calls, mockEq.mock.calls]).toEqual([
      [['feature_flags']],
      [['value']],
      [['key', FLAG_KEY]],
    ]);
  });

  it.each<[string, unknown, number | null]>([
    ['a finite number', { value: BUILD }, BUILD],
    ['zero', { value: 0 }, 0],
    ['a missing row', null, null],
    ['JSON null', { value: null }, null],
    ['a numeric string', { value: '87' }, null],
    ['an object', { value: { enabled: true } }, null],
    ['a boolean', { value: true }, null],
    ['an infinite number', { value: Infinity }, null],
    ['NaN', { value: NaN }, null],
  ])('returns the expected number for %s', async (_label, data, expected) => {
    mockMaybeSingle.mockResolvedValue({ data, error: null });

    await expect(FeatureFlagService.getNumber(FLAG_KEY)).resolves.toEqual(expected);
  });

  it('throws the query error', async () => {
    const error = { message: 'permission denied', code: '42501' };
    mockMaybeSingle.mockResolvedValue({ data: null, error });

    await expect(FeatureFlagService.getNumber(FLAG_KEY)).rejects.toEqual(error);
  });
});
