import { describe, it, expect } from '@jest/globals';
import { safeExternalUrl } from './safeUrl';

describe('safeExternalUrl', () => {
  it.each([
    ['https url', 'https://coffee.example/menu', 'https://coffee.example/menu'],
    ['http url', 'http://coffee.example/', 'http://coffee.example/'],
    ['uppercase scheme', 'HTTPS://coffee.example/', 'https://coffee.example/'],
    ['bare domain', 'coffee.example', 'https://coffee.example/'],
    ['surrounding whitespace', '  https://coffee.example/  ', 'https://coffee.example/'],
  ])('accepts %s', (_label, input, expected) => {
    expect(safeExternalUrl(input)).toBe(expected);
  });

  it.each([
    ['javascript scheme', 'javascript:alert(1)'],
    ['uppercase javascript scheme', 'JavaScript:alert(1)'],
    ['data scheme', 'data:text/html,<script>alert(1)</script>'],
    ['vbscript scheme', 'vbscript:msgbox(1)'],
    ['whitespace only', '   '],
    ['empty string', ''],
    ['null', null],
    ['undefined', undefined],
  ])('rejects %s', (_label, input) => {
    expect(safeExternalUrl(input)).toBeNull();
  });
});
