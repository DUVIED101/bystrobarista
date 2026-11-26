const mockRpc = jest.fn();

jest.mock('../config/supabase', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

// Import after jest.mock so the service receives the mocked module.
import { UserService } from './UserService';

const IOS_CLIENT = { platform: 'ios', build: 87 } as const;
const WEB_CLIENT = { platform: 'web', build: null } as const;
const MISSING_FUNCTION_ERROR = {
  code: 'PGRST202',
  message: 'Could not find the function public.touch_last_seen(p_build, p_platform)',
};

const OTHER_ERROR = { code: '57014', message: 'canceling statement due to statement timeout' };

describe('touchLastSeen', () => {
  beforeEach(() => {
    mockRpc.mockReset();
    jest.spyOn(console, 'warn').mockImplementation(() => {});
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('calls the touch_last_seen RPC without arguments', async () => {
    mockRpc.mockResolvedValue({ data: null, error: null });

    await UserService.touchLastSeen();

    expect(mockRpc.mock.calls).toEqual([['touch_last_seen']]);
  });

  it.each([IOS_CLIENT, WEB_CLIENT])(
    'passes platform and build to the RPC for client %j',
    async client => {
      mockRpc.mockResolvedValue({ data: null, error: null });

      await UserService.touchLastSeen(client);

      expect(mockRpc.mock.calls).toEqual([
        ['touch_last_seen', { p_platform: client.platform, p_build: client.build }],
      ]);
    }
  );

  it('falls back to the zero-argument RPC when the server lacks the client overload', async () => {
    mockRpc
      .mockResolvedValueOnce({ data: null, error: MISSING_FUNCTION_ERROR })
      .mockResolvedValueOnce({ data: null, error: null });

    await UserService.touchLastSeen(IOS_CLIENT);

    expect(mockRpc.mock.calls).toEqual([
      ['touch_last_seen', { p_platform: IOS_CLIENT.platform, p_build: IOS_CLIENT.build }],
      ['touch_last_seen'],
    ]);
  });

  it('does not fall back and warns once when the client RPC fails for another reason', async () => {
    mockRpc.mockResolvedValue({ data: null, error: OTHER_ERROR });

    await UserService.touchLastSeen(IOS_CLIENT);

    expect([mockRpc.mock.calls, (console.warn as jest.Mock).mock.calls.length]).toEqual([
      [['touch_last_seen', { p_platform: IOS_CLIENT.platform, p_build: IOS_CLIENT.build }]],
      1,
    ]);
  });

  it('resolves when both the client RPC and the fallback fail', async () => {
    mockRpc.mockResolvedValue({ data: null, error: MISSING_FUNCTION_ERROR });

    await expect(UserService.touchLastSeen(IOS_CLIENT)).resolves.toBeUndefined();
  });

  it('resolves when the RPC returns an error, so app launch is never blocked', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'function not found' } });

    await expect(UserService.touchLastSeen()).resolves.toBeUndefined();
  });

  it('resolves when the network request rejects', async () => {
    mockRpc.mockRejectedValue(new TypeError('Network request failed'));

    await expect(UserService.touchLastSeen()).resolves.toBeUndefined();
  });
});
