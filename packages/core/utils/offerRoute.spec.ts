import { resolveOfferEntry, type OfferEntry, type OfferableJobsState } from './offerRoute';

describe('resolveOfferEntry', () => {
  it.each<[OfferableJobsState, OfferEntry]>([
    ['loading', 'offer'],
    ['has_jobs', 'offer'],
    ['no_jobs', 'create_job'],
    ['error', 'offer'],
  ])('routes %s to %s', (state, expected) => {
    expect(resolveOfferEntry(state)).toEqual(expected);
  });
});
