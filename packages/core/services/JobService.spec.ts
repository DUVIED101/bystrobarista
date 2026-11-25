import type { JobId } from '@bystrobarista/core/types/ids';

const mockRpc = jest.fn();

jest.mock('../config/supabase', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
}));

// Import after jest.mock so the service receives the mocked client.
import { JobService } from './JobService';

const JOB_ID = 'job-uuid-1' as JobId;
const AUDIENCE_SIZE = 7;

describe('countJobAudience', () => {
  beforeEach(() => {
    mockRpc.mockReset();
  });

  it('calls count_job_audience with the job id and returns the count as a number', async () => {
    mockRpc.mockResolvedValue({ data: AUDIENCE_SIZE, error: null });

    const result = await JobService.countJobAudience(JOB_ID);

    expect([result, mockRpc.mock.calls]).toEqual([
      AUDIENCE_SIZE,
      [['count_job_audience', { p_job_id: JOB_ID }]],
    ]);
  });

  it('returns 0 when the RPC returns no data', async () => {
    mockRpc.mockResolvedValue({ data: null, error: null });

    await expect(JobService.countJobAudience(JOB_ID)).resolves.toBe(0);
  });

  it('rethrows the RPC error so callers can treat the audience as unknown', async () => {
    const rpcError = new Error('function count_job_audience does not exist');
    mockRpc.mockResolvedValue({ data: null, error: rpcError });

    await expect(JobService.countJobAudience(JOB_ID)).rejects.toBe(rpcError);
  });
});
