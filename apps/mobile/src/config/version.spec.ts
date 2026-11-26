import { formatVersionLabel, parseBuildNumber } from './version';

describe('parseBuildNumber', () => {
  it.each([
    ['87', 87],
    [' 87 ', 87],
    [87, 87],
    ['1', 1],
  ])('parses %p as %p', (raw, expected) => {
    expect(parseBuildNumber(raw)).toEqual(expected);
  });

  it.each([['0'], [0], [''], ['abc'], ['87a'], ['2.2'], [-3], [1.5], [undefined], [null], ['-1']])(
    'returns null for %p',
    raw => {
      expect(parseBuildNumber(raw)).toBeNull();
    }
  );
});

describe('formatVersionLabel', () => {
  const version = '2.2';
  const build = 87;

  it('appends the build in parentheses when it is known', () => {
    expect(formatVersionLabel(version, build)).toEqual('2.2 (87)');
  });

  it('returns the bare version when the build is unknown', () => {
    expect(formatVersionLabel(version, null)).toEqual('2.2');
  });
});
