import { getPartners, PartnerDirection } from '@immich/sdk';
import { get, writable } from 'svelte/store';

const partnerAccessMap = writable<Map<string, string>>(new Map());

let loaded = false;
let loading: Promise<void> | null = null;

export const loadPartnerAccessMap = async () => {
  if (loaded) {
    return;
  }

  if (loading) {
    return loading;
  }

  loading = (async () => {
    try {
      const partners = await getPartners({ direction: PartnerDirection.SharedWith });
      const map = new Map<string, string>();
      for (const partner of partners) {
        map.set(partner.id, partner.accessLevel || 'viewer');
      }
      partnerAccessMap.set(map);
      loaded = true;
    } catch {
      // If loading fails, leave the map empty
    } finally {
      loading = null;
    }
  })();

  return loading;
};

export const resetPartnerAccessMap = () => {
  partnerAccessMap.set(new Map());
  loaded = false;
};

export const isEditorPartner = (assetOwnerId: string): boolean => {
  const map = get(partnerAccessMap);
  return map.get(assetOwnerId) === 'editor';
};

export { partnerAccessMap };
