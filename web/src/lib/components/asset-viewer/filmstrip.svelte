<script lang="ts">
  import Thumbnail from '$lib/components/assets/thumbnail/thumbnail.svelte';
  import type { FilmstripManager } from '$lib/components/asset-viewer/filmstrip-manager.svelte';
  import { filmstripPinned } from '$lib/stores/preferences.store';
  import { IconButton } from '@immich/ui';
  import { mdiPin, mdiPinOutline } from '@mdi/js';
  import { onDestroy, untrack } from 'svelte';
  import { fly } from 'svelte/transition';

  const FILMSTRIP_HEIGHT = 80;
  const PRELOAD_BUFFER = 400;
  const EDGE_LOAD_THRESHOLD = 300;
  const HIDE_DELAY_MS = 1500;
  const HOVER_ZONE_HEIGHT = 150;

  interface Props {
    filmstripManager: FilmstripManager;
    currentAssetId: string;
    hasStack: boolean;
    onNavigate: (assetId: string) => void;
  }

  let { filmstripManager, currentAssetId, hasStack, onNavigate }: Props = $props();

  let showFilmstrip = $state($filmstripPinned);
  let isOverFilmstrip = $state(false);
  let mouseNearBottom = $state(false);
  let hideTimer: ReturnType<typeof setTimeout> | undefined;
  let scrollContainer: HTMLDivElement | undefined = $state();
  let scrollLeft = $state(0);
  let containerWidth = $state(0);

  // Track mouse position to detect proximity to bottom of screen
  function handleMouseMove(e: MouseEvent) {
    const nearBottom = e.clientY >= window.innerHeight - HOVER_ZONE_HEIGHT;
    if (nearBottom && !mouseNearBottom) {
      mouseNearBottom = true;
      showFilmstrip = true;
      clearHideTimer();
    } else if (!nearBottom && mouseNearBottom) {
      mouseNearBottom = false;
      if (!isOverFilmstrip) {
        startHideTimer();
      }
    }
  }

  if (typeof document !== 'undefined') {
    document.addEventListener('mousemove', handleMouseMove);
  }

  onDestroy(() => {
    if (typeof document !== 'undefined') {
      document.removeEventListener('mousemove', handleMouseMove);
    }
    clearHideTimer();
  });

  // Compute total width and per-asset positions for virtual rendering
  const assetWidths = $derived(filmstripManager.assets.map((a) => Math.round(a.ratio * FILMSTRIP_HEIGHT)));
  const gap = 2;
  const assetPositions = $derived.by(() => {
    const positions: number[] = [];
    let offset = 0;
    for (let i = 0; i < assetWidths.length; i++) {
      positions.push(offset);
      offset += assetWidths[i] + gap;
    }
    return positions;
  });
  const totalWidth = $derived.by(() => {
    if (assetWidths.length === 0) return 0;
    const lastIdx = assetWidths.length - 1;
    return assetPositions[lastIdx] + assetWidths[lastIdx];
  });

  // Determine which assets are visible (for virtual rendering)
  const visibleRange = $derived.by(() => {
    const viewStart = scrollLeft - PRELOAD_BUFFER;
    const viewEnd = scrollLeft + containerWidth + PRELOAD_BUFFER;
    let startIdx = 0;
    let endIdx = assetPositions.length - 1;

    // Binary search for start
    let lo = 0;
    let hi = assetPositions.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (assetPositions[mid] + assetWidths[mid] < viewStart) {
        lo = mid + 1;
      } else {
        startIdx = mid;
        hi = mid - 1;
      }
    }

    // Binary search for end
    lo = startIdx;
    hi = assetPositions.length - 1;
    while (lo <= hi) {
      const mid = (lo + hi) >> 1;
      if (assetPositions[mid] > viewEnd) {
        hi = mid - 1;
      } else {
        endIdx = mid;
        lo = mid + 1;
      }
    }

    return { start: startIdx, end: endIdx };
  });

  // Auto-hide logic
  function startHideTimer() {
    clearHideTimer();
    if ($filmstripPinned) return;
    hideTimer = setTimeout(() => {
      if (!isOverFilmstrip && !mouseNearBottom) {
        showFilmstrip = false;
      }
    }, HIDE_DELAY_MS);
  }

  function clearHideTimer() {
    if (hideTimer) {
      clearTimeout(hideTimer);
      hideTimer = undefined;
    }
  }

  function handleFilmstripEnter() {
    isOverFilmstrip = true;
    clearHideTimer();
  }

  function handleFilmstripLeave() {
    isOverFilmstrip = false;
    startHideTimer();
  }

  function togglePin() {
    $filmstripPinned = !$filmstripPinned;
    if ($filmstripPinned) {
      showFilmstrip = true;
      clearHideTimer();
    }
  }

  // Scroll to center the current asset when it changes, when filmstrip loads,
  // or when the scroll container is (re)created (e.g. after hide/show cycle)
  $effect(() => {
    void currentAssetId;
    void scrollContainer;
    const idx = filmstripManager.currentIndex;
    untrack(() => {
      if (!scrollContainer || idx < 0 || idx >= assetPositions.length) return;

      const assetCenter = assetPositions[idx] + assetWidths[idx] / 2;
      const scrollTarget = assetCenter - scrollContainer.clientWidth / 2;
      scrollContainer.scrollTo({ left: scrollTarget, behavior: 'instant' });
    });
  });

  // Handle scroll for virtual rendering and edge loading
  function handleScroll() {
    if (!scrollContainer) return;
    scrollLeft = scrollContainer.scrollLeft;
    containerWidth = scrollContainer.clientWidth;

    // Load more when near edges
    if (scrollLeft + containerWidth >= scrollContainer.scrollWidth - EDGE_LOAD_THRESHOLD) {
      void filmstripManager.extendEarlier();
    }
    if (scrollLeft <= EDGE_LOAD_THRESHOLD) {
      void filmstripManager.extendLater();
    }
  }

  // Sync state when scroll container is (re)created
  $effect(() => {
    if (scrollContainer) {
      containerWidth = scrollContainer.clientWidth;
      scrollLeft = scrollContainer.scrollLeft;
    }
  });
</script>

{#if showFilmstrip && filmstripManager.assets.length > 0}
  <div
    class="absolute col-span-4 col-start-1 left-0 right-0 z-[2] pointer-events-none"
    style:bottom={hasStack ? '85px' : '0'}
    transition:fly={{ y: 80, duration: 150 }}
  >
    <div
      class="pointer-events-auto bg-black/60 backdrop-blur-sm"
      onmouseenter={handleFilmstripEnter}
      onmouseleave={handleFilmstripLeave}
      role="navigation"
      aria-label="Filmstrip"
    >
      <!-- Pin button -->
      <div class="absolute top-1 right-2 z-10">
        <IconButton
          variant="ghost"
          shape="round"
          color="secondary"
          icon={$filmstripPinned ? mdiPin : mdiPinOutline}
          onclick={togglePin}
          aria-label={$filmstripPinned ? 'Unpin filmstrip' : 'Pin filmstrip'}
          size="small"
        />
      </div>

      <!-- Scrollable thumbnail strip -->
      <div
        bind:this={scrollContainer}
        class="filmstrip-scroll flex items-center overflow-x-auto overflow-y-hidden py-2 px-1"
        style:height="{FILMSTRIP_HEIGHT + 16}px"
        onscroll={handleScroll}
      >
        <!-- Virtual scroll spacer -->
        <div class="flex-shrink-0 relative" style:width="{totalWidth}px" style:height="{FILMSTRIP_HEIGHT}px">
          {#each filmstripManager.assets as asset, i (asset.id)}
            {#if i >= visibleRange.start && i <= visibleRange.end}
              <div
                class="absolute top-0 transition-opacity"
                style:left="{assetPositions[i]}px"
                style:width="{assetWidths[i]}px"
                style:height="{FILMSTRIP_HEIGHT}px"
              >
                <Thumbnail
                  {asset}
                  thumbnailHeight={FILMSTRIP_HEIGHT}
                  thumbnailWidth={assetWidths[i]}
                  imageClass={{ 'border-2 border-white': asset.id === currentAssetId }}
                  dimmed={asset.id !== currentAssetId}
                  readonly
                  showStackedIcon={false}
                  disableLinkMouseOver
                  onClick={() => onNavigate(asset.id)}
                />
              </div>
            {/if}
          {/each}
        </div>
      </div>
    </div>
  </div>
{/if}

<style>
  .filmstrip-scroll::-webkit-scrollbar {
    width: 8px;
    height: 10px;
  }

  .filmstrip-scroll::-webkit-scrollbar-track {
    background: #000000;
    border-radius: 16px;
  }

  .filmstrip-scroll::-webkit-scrollbar-thumb {
    background: rgba(159, 159, 159, 0.408);
    border-radius: 16px;
  }

  .filmstrip-scroll::-webkit-scrollbar-thumb:hover {
    background: #adcbfa;
    border-radius: 16px;
  }
</style>
