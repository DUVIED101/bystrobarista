const mockRpc = jest.fn();

jest.mock('../config/supabase', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

// Import after jest.mock so the service receives the mocked module.
import { UserService } from './UserService';

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

  it('resolves when the RPC returns an error, so app launch is never blocked', async () => {
    mockRpc.mockResolvedValue({ data: null, error: { message: 'function not found' } });

    await expect(UserService.touchLastSeen()).resolves.toBeUndefined();
  });

  it('resolves when the network request rejects', async () => {
    mockRpc.mockRejectedValue(new TypeError('Network request failed'));

    await expect(UserService.touchLastSeen()).resolves.toBeUndefined();
  });
});
