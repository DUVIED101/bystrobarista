export type OfferableJobsState = 'loading' | 'has_jobs' | 'no_jobs' | 'error';

export type OfferEntry = 'offer' | 'create_job';

export const resolveOfferEntry = (state: OfferableJobsState): OfferEntry =>
  state === 'no_jobs' ? 'create_job' : 'offer';
