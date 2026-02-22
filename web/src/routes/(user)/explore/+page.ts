import { authenticate } from '$lib/utils/auth';
import { getFormatter } from '$lib/utils/i18n';
import { getAllPeople, getExploreData, getPartners, PartnerDirection, type PersonResponseDto } from '@immich/sdk';
import type { PageLoad } from './$types';

async function getAllPartnerPeople(partnerId: string): Promise<PersonResponseDto[]> {
  const people: PersonResponseDto[] = [];
  let page = 1;
  let hasNext = true;
  while (hasNext) {
    const res = await getAllPeople({ ownerId: partnerId, withHidden: false, page });
    people.push(...res.people);
    hasNext = res.hasNextPage ?? false;
    page++;
  }
  return people;
}

export const load = (async ({ url }) => {
  await authenticate(url);
  const [items, response, partners] = await Promise.all([
    getExploreData(),
    getAllPeople({ withHidden: false }),
    getPartners({ direction: PartnerDirection.SharedWith }),
  ]);

  // Fetch all people from partners who share their timeline
  const partnerPeopleArrays = await Promise.all(
    partners
      .filter((partner) => partner.inTimeline)
      .map((partner) => getAllPartnerPeople(partner.id)),
  );

  // Merge and dedup people by ID
  const allPeople = [...response.people];
  const seenIds = new Set(allPeople.map((p) => p.id));
  let partnerTotal = 0;
  for (const partnerPeople of partnerPeopleArrays) {
    partnerTotal += partnerPeople.length;
    for (const person of partnerPeople) {
      if (!seenIds.has(person.id)) {
        allPeople.push(person);
        seenIds.add(person.id);
      }
    }
  }

  const mergedResponse = {
    ...response,
    people: allPeople,
    total: response.total + partnerTotal,
  };

  const $t = await getFormatter();

  return {
    items,
    response: mergedResponse,
    meta: {
      title: $t('explore'),
    },
  };
}) satisfies PageLoad;
