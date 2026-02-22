import { authenticate } from '$lib/utils/auth';
import { getFormatter } from '$lib/utils/i18n';
import { getAllPeople, getPartners, PartnerDirection } from '@immich/sdk';
import type { PageLoad } from './$types';

export const load = (async ({ url }) => {
  await authenticate(url);

  const [people, partners] = await Promise.all([
    getAllPeople({ withHidden: true }),
    getPartners({ direction: PartnerDirection.SharedWith }),
  ]);

  // Fetch people from partners who share their timeline
  const partnerPeopleResults = await Promise.all(
    partners
      .filter((partner) => partner.inTimeline)
      .map((partner) => getAllPeople({ ownerId: partner.id, withHidden: false })),
  );

  // Merge and dedup people by ID
  const allPeople = [...people.people];
  const seenIds = new Set(allPeople.map((p) => p.id));
  for (const partnerResult of partnerPeopleResults) {
    for (const person of partnerResult.people) {
      if (!seenIds.has(person.id)) {
        allPeople.push(person);
        seenIds.add(person.id);
      }
    }
  }

  const mergedPeople = {
    ...people,
    people: allPeople,
    total: people.total + partnerPeopleResults.reduce((sum, r) => sum + r.total, 0),
  };

  const $t = await getFormatter();

  return {
    people: mergedPeople,
    meta: {
      title: $t('people'),
    },
  };
}) satisfies PageLoad;
