import type { DayGroup } from '$lib/managers/timeline-manager/day-group.svelte';
import type { MonthGroup } from '$lib/managers/timeline-manager/month-group.svelte';
import { TimelineManager } from '$lib/managers/timeline-manager/timeline-manager.svelte';
import type { TimelineAsset } from '$lib/managers/timeline-manager/types';

const INITIAL_BATCH_SIZE = 25;
const EXTEND_BATCH_SIZE = 20;

export class FilmstripManager {
  assets: TimelineAsset[] = $state([]);
  currentIndex: number = $state(-1);
  isLoadingEarlier: boolean = $state(false);
  isLoadingLater: boolean = $state(false);
  canExtendEarlier: boolean = $state(true);
  canExtendLater: boolean = $state(true);

  #timelineManager?: TimelineManager;
  #isArrayMode: boolean;
  #loadVersion = 0;

  private constructor(timelineManager?: TimelineManager) {
    this.#timelineManager = timelineManager;
    this.#isArrayMode = !timelineManager;
  }

  static fromTimeline(timelineManager: TimelineManager): FilmstripManager {
    return new FilmstripManager(timelineManager);
  }

  static fromArray(assets: TimelineAsset[]): FilmstripManager {
    const manager = new FilmstripManager();
    manager.assets = assets;
    manager.canExtendEarlier = false;
    manager.canExtendLater = false;
    return manager;
  }

  updateAssets(assets: TimelineAsset[]) {
    this.assets = assets;
    this.canExtendEarlier = false;
    this.canExtendLater = false;
    // Update currentIndex if we had one
    if (this.currentIndex >= 0 && this.currentIndex < this.assets.length) {
      // Try to preserve by ID
      const currentId = this.assets[this.currentIndex]?.id;
      if (currentId) {
        const newIndex = assets.findIndex((a) => a.id === currentId);
        this.currentIndex = newIndex;
      }
    }
  }

  async loadAround(assetId: string) {
    if (this.#isArrayMode) {
      this.currentIndex = this.assets.findIndex((a) => a.id === assetId);
      return;
    }

    // Timeline mode: check if asset is already loaded
    const existingIndex = this.assets.findIndex((a) => a.id === assetId);
    if (existingIndex >= 0) {
      this.currentIndex = existingIndex;
      return;
    }

    // Need to load assets around the new position
    const tm = this.#timelineManager!;
    const version = ++this.#loadVersion;

    const monthGroup = await tm.findMonthGroupForAsset({ id: assetId });
    if (!monthGroup || version !== this.#loadVersion) {
      return;
    }

    const asset = monthGroup.findAssetById({ id: assetId });
    if (!asset || version !== this.#loadVersion) {
      return;
    }

    const dayGroup = monthGroup.findDayGroupForAsset(asset);

    // Collect assets in both directions
    const [earlierAssets, laterAssets] = await Promise.all([
      this.#collectAssets(asset, monthGroup, dayGroup, 'earlier', INITIAL_BATCH_SIZE),
      this.#collectAssets(asset, monthGroup, dayGroup, 'later', INITIAL_BATCH_SIZE),
    ]);

    if (version !== this.#loadVersion) {
      return;
    }

    // Combine: later (reversed to chronological) + current + earlier
    this.assets = [...laterAssets.reverse(), asset, ...earlierAssets];
    this.currentIndex = laterAssets.length;
    this.canExtendEarlier = earlierAssets.length >= INITIAL_BATCH_SIZE;
    this.canExtendLater = laterAssets.length >= INITIAL_BATCH_SIZE;
  }

  async extendEarlier() {
    if (this.#isArrayMode || this.isLoadingEarlier || !this.canExtendEarlier || this.assets.length === 0) {
      return;
    }

    this.isLoadingEarlier = true;
    try {
      const lastAsset = this.assets[this.assets.length - 1];
      const tm = this.#timelineManager!;
      const monthGroup = await tm.findMonthGroupForAsset({ id: lastAsset.id });
      if (!monthGroup) {
        this.canExtendEarlier = false;
        return;
      }

      const asset = monthGroup.findAssetById({ id: lastAsset.id });
      if (!asset) {
        this.canExtendEarlier = false;
        return;
      }

      const dayGroup = monthGroup.findDayGroupForAsset(asset);
      const newAssets = await this.#collectAssets(asset, monthGroup, dayGroup, 'earlier', EXTEND_BATCH_SIZE);

      if (newAssets.length > 0) {
        this.assets = [...this.assets, ...newAssets];
      }
      this.canExtendEarlier = newAssets.length >= EXTEND_BATCH_SIZE;
    } finally {
      this.isLoadingEarlier = false;
    }
  }

  async extendLater() {
    if (this.#isArrayMode || this.isLoadingLater || !this.canExtendLater || this.assets.length === 0) {
      return;
    }

    this.isLoadingLater = true;
    try {
      const firstAsset = this.assets[0];
      const tm = this.#timelineManager!;
      const monthGroup = await tm.findMonthGroupForAsset({ id: firstAsset.id });
      if (!monthGroup) {
        this.canExtendLater = false;
        return;
      }

      const asset = monthGroup.findAssetById({ id: firstAsset.id });
      if (!asset) {
        this.canExtendLater = false;
        return;
      }

      const dayGroup = monthGroup.findDayGroupForAsset(asset);
      const newAssets = await this.#collectAssets(asset, monthGroup, dayGroup, 'later', EXTEND_BATCH_SIZE);

      if (newAssets.length > 0) {
        // Prepend: new later assets (reversed) go to the front
        this.assets = [...newAssets.reverse(), ...this.assets];
        this.currentIndex += newAssets.length;
      }
      this.canExtendLater = newAssets.length >= EXTEND_BATCH_SIZE;
    } finally {
      this.isLoadingLater = false;
    }
  }

  async #collectAssets(
    startAsset: TimelineAsset,
    startMonthGroup: MonthGroup,
    startDayGroup: DayGroup | undefined,
    direction: 'earlier' | 'later',
    count: number,
  ): Promise<TimelineAsset[]> {
    const tm = this.#timelineManager!;
    const collected: TimelineAsset[] = [];
    let skippedStart = false;

    for await (const asset of tm.assetsIterator({
      startMonthGroup,
      startDayGroup,
      startAsset,
      direction,
    })) {
      // Skip the start asset itself
      if (!skippedStart) {
        skippedStart = true;
        continue;
      }
      collected.push(asset);
      if (collected.length >= count) {
        break;
      }
    }

    return collected;
  }
}
