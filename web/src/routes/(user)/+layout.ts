import { loadPartnerAccessMap } from '$lib/stores/partner-access.store';
import { authenticate } from '$lib/utils/auth';
import { getAssetInfoFromParam, isSharedLinkRoute } from '$lib/utils/navigation';
import type { LayoutLoad } from './$types';

export const load = (async ({ url, params, route }) => {
  await authenticate(url, { public: isSharedLinkRoute(route.id) });
  const asset = await getAssetInfoFromParam(params);

  // Load partner access levels in background (cached after first load)
  if (!isSharedLinkRoute(route.id)) {
    loadPartnerAccessMap();
  }

  return {
    asset,
  };
}) satisfies LayoutLoad;
