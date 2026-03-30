# Fork info

Quick summary of the changes done on this fork:

* [enhanced Partner Sharing](#branch-partner-sharing-improvements)
* [hide albums from timeline](#branch-hide-album-from-timeline)
* [fork info in version](#branch-version-show-fork)
* [Unraid deploy scripts](#branch-unraid-switch)
* [filmstrip navigation in asset viewer](#branch-filmstrip-navigation)

more info below.

## Branch management

I'll be rebasing and force-pushing. I aim to have each of the changes on a separate branch, each branched out
from `main`, at least until I start encountering conflicts. For my purposes I'll be merging all of them into
'release' branches that I'll build the container from and upload it to my Unraid machine - I'll push those as
tags and they'll be kept intact, if anything goes wrong I'll make new tags with new fixes merged in.

I'm currently using a build from tag [`fork-v2.5.6-2026-02-22`](https://github.com/bgr/immich/tree/fork-v2.5.6-2026-02-22) and it's working fine so far.

## Feature branches

### Branch [`partner-sharing-improvements`](https://github.com/bgr/immich/tree/partner-sharing-improvements)

Aims to make the UI experience for partners indistinguishable from owner's on the web. Partners will see
image metadata, the geotags on the map, the recognized faces. The photos will appear in memories and in
the "Map" sidebar, people and places will appear in "Explore" sidebar.

This was done with my use-case in mind, so I might have some things in a blind spot, e.g. I'll have both
the owner and the partners upload all images through the External Library exposed via the network share, so
I didn't care about uploading through the web interface at all.

**What works (web):**

- Partner's people appear on the People page alongside your own
- Clicking a partner's person shows all their photos (timeline loads correctly)
- Partner's people appear in search/filter dropdowns (search bar, smart search filters)
- Face info panel on assets shows partner's person names and links
- Partner's people appear in Explore sidebar
- Partner's places appear in Explore sidebar and on the Map
- Partner's photos appear in Memories
- Searching by person name finds both your own and partner's people
- People page pagination handles >500 people across multiple partners

**What doesn't work / known limitations:**

- **People management is read-only for partners.** Only the person's owner can rename, hide, merge,
  set birth dates, or change feature photos. Edit controls are hidden in the UI for partner people.
- **Mobile app** does not show partner people. The Dart client would need regeneration to pick up new
  types (`ownerId` on `PersonResponseDto`), and the mobile UI would need changes to pass `ownerId`
  when loading a person's timeline. The existing mobile app won't break — it ignores unknown fields.
- **No cross-user person merging.** You cannot merge a person from your library with a person from a
  partner's library, even if they're the same real person. Each user's face clusters are independent.

**Impact on other clients:**

| Feature | Web | Mobile (no rebuild) | Mobile (with rebuild) |
|---|---|---|---|
| Memories | Works | Works (resolves assets from local sync DB) | Works |
| Explore places | Works | Works (server returns partner cities) | Works |
| Explore people | Works | No change | Needs code to pass `ownerId` |
| Map | Works (default on) | No change (has own default) | One-line default change |
| People page | Works | No change | Needs `ownerId` + UI changes |
| Person detail | Works | No change | Needs `ownerId` for timeline |
| People management | Read-only for partners | N/A | N/A |

The OpenAPI spec and TypeScript SDK are regenerated and in sync.

### Branch [`hide-album-from-timeline`](https://github.com/bgr/immich/tree/hide-album-from-timeline)

Note: I didn't get to test this out propery yet.

Adds a per-album toggle to hide its assets from the main Photos timeline. The album itself remains visible and
accessible — only its assets stop appearing in the timeline view. A closed-eye indicator is shown on album
cards (cover view) and album rows (list view) when an album is hidden. The toggle is available in the album
context menu on the albums list page and as an eye icon button in the album detail page toolbar.

### Branch [`version-show-fork`](https://github.com/bgr/immich/tree/version-show-fork)

Adds `-fork` suffix to the version number in the sidebar and a "Fork" line in the About modal linking to this
repo. Makes it clear to the user that they're running a fork.

### Branch [`unraid-switch`](https://github.com/bgr/immich/tree/unraid-switch)

A deploy script for building the fork and uploading it to Unraid machines that previously ran
[ImageGenius Immich](https://ghcr.io/imagegenius/immich). It discovers the existing container's config,
builds a drop-in replacement image from the fork's source, transfers it to Unraid via SCP, and manages
it through Docker Compose Manager. The original container is stopped and left intact.

The build step patches the ImageGenius Dockerfile to `COPY` local source instead of downloading from
GitHub, and splits the monolithic `RUN` into two Docker layers — one for dependency installation (apt,
Node.js, Python, pnpm) and one for compiling the code (server, web, CLI, ML, plugins). This way
code-only changes reuse the cached dependency layer and skip the slow install step.

### Branch [`filmstrip-navigation`](https://github.com/bgr/immich/tree/filmstrip-navigation)

Adds a filmstrip/thumbnail strip at the bottom of the asset viewer (web) for quick visual navigation
between neighboring assets. The filmstrip auto-hides and appears when the mouse approaches the bottom of
the screen, with a pin button to keep it visible. Thumbnails have a fixed height with width varying by
aspect ratio, and the current asset is highlighted. Videos show the same duration indicators as the main
timeline. The filmstrip contents match the viewing context — timeline photos when browsing the timeline,
search results when viewing search results, album contents when viewing an album, etc.

---

*Original README below*

---

<p align="center">
  <br/>
  <a href="https://opensource.org/license/agpl-v3"><img src="https://img.shields.io/badge/License-AGPL_v3-blue.svg?color=3F51B5&style=for-the-badge&label=License&logoColor=000000&labelColor=ececec" alt="License: AGPLv3"></a>
  <a href="https://discord.immich.app">
    <img src="https://img.shields.io/discord/979116623879368755.svg?label=Discord&logo=Discord&style=for-the-badge&logoColor=000000&labelColor=ececec" alt="Discord"/>
  </a>
  <br/>
  <br/>
</p>

<p align="center">
<img src="design/immich-logo-stacked-light.svg" width="300" title="Login With Custom URL">
</p>
<h3 align="center">High performance self-hosted photo and video management solution</h3>
<br/>
<a href="https://immich.app">
<img src="design/immich-screenshots.png" title="Main Screenshot">
</a>
<br/>

<p align="center">
  <a href="readme_i18n/README_ca_ES.md">Català</a>
  <a href="readme_i18n/README_es_ES.md">Español</a>
  <a href="readme_i18n/README_fr_FR.md">Français</a>
  <a href="readme_i18n/README_it_IT.md">Italiano</a>
  <a href="readme_i18n/README_ja_JP.md">日本語</a>
  <a href="readme_i18n/README_ko_KR.md">한국어</a>
  <a href="readme_i18n/README_de_DE.md">Deutsch</a>
  <a href="readme_i18n/README_nl_NL.md">Nederlands</a>
  <a href="readme_i18n/README_tr_TR.md">Türkçe</a>
  <a href="readme_i18n/README_zh_CN.md">简体中文</a>
  <a href="readme_i18n/README_zh_TW.md">正體中文</a>
  <a href="readme_i18n/README_uk_UA.md">Українська</a>
  <a href="readme_i18n/README_ru_RU.md">Русский</a>
  <a href="readme_i18n/README_pt_BR.md">Português Brasileiro</a>
  <a href="readme_i18n/README_sv_SE.md">Svenska</a>
  <a href="readme_i18n/README_ar_JO.md">العربية</a>
  <a href="readme_i18n/README_vi_VN.md">Tiếng Việt</a>
  <a href="readme_i18n/README_th_TH.md">ภาษาไทย</a>
</p>


> [!WARNING]
> ⚠️ Always follow [3-2-1](https://www.backblaze.com/blog/the-3-2-1-backup-strategy/) backup plan for your precious photos and videos!
> 
 

> [!NOTE]
> You can find the main documentation, including installation guides, at https://immich.app/.

## Links

- [Documentation](https://docs.immich.app/)
- [About](https://docs.immich.app/overview/introduction)
- [Installation](https://docs.immich.app/install/requirements)
- [Roadmap](https://immich.app/roadmap)
- [Demo](#demo)
- [Features](#features)
- [Translations](https://docs.immich.app/developer/translations)
- [Contributing](https://docs.immich.app/overview/support-the-project)

## Demo

Access the demo [here](https://demo.immich.app). For the mobile app, you can use `https://demo.immich.app` for the `Server Endpoint URL`.

### Login credentials

| Email           | Password |
| --------------- | -------- |
| demo@immich.app | demo     |

## Features

| Features                                     | Mobile | Web |
| :------------------------------------------- | ------ | --- |
| Upload and view videos and photos            | Yes    | Yes |
| Auto backup when the app is opened           | Yes    | N/A |
| Prevent duplication of assets                | Yes    | Yes |
| Selective album(s) for backup                | Yes    | N/A |
| Download photos and videos to local device   | Yes    | Yes |
| Multi-user support                           | Yes    | Yes |
| Album and Shared albums                      | Yes    | Yes |
| Scrubbable/draggable scrollbar               | Yes    | Yes |
| Support raw formats                          | Yes    | Yes |
| Metadata view (EXIF, map)                    | Yes    | Yes |
| Search by metadata, objects, faces, and CLIP | Yes    | Yes |
| Administrative functions (user management)   | No     | Yes |
| Background backup                            | Yes    | N/A |
| Virtual scroll                               | Yes    | Yes |
| OAuth support                                | Yes    | Yes |
| API Keys                                     | N/A    | Yes |
| LivePhoto/MotionPhoto backup and playback    | Yes    | Yes |
| Support 360 degree image display             | No     | Yes |
| User-defined storage structure               | Yes    | Yes |
| Public Sharing                               | Yes    | Yes |
| Archive and Favorites                        | Yes    | Yes |
| Global Map                                   | Yes    | Yes |
| Partner Sharing                              | Yes    | Yes |
| Facial recognition and clustering            | Yes    | Yes |
| Memories (x years ago)                       | Yes    | Yes |
| Offline support                              | Yes    | No  |
| Read-only gallery                            | Yes    | Yes |
| Stacked Photos                               | Yes    | Yes |
| Tags                                         | No     | Yes |
| Folder View                                  | Yes    | Yes |

## Translations

Read more about translations [here](https://docs.immich.app/developer/translations).

<a href="https://hosted.weblate.org/engage/immich/">
<img src="https://hosted.weblate.org/widget/immich/immich/multi-auto.svg" alt="Translation status" />
</a>

## Repository activity

![Activities](https://repobeats.axiom.co/api/embed/9e86d9dc3ddd137161f2f6d2e758d7863b1789cb.svg "Repobeats analytics image")

## Star history

<a href="https://star-history.com/#immich-app/immich&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=immich-app/immich&type=date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=immich-app/immich&type=date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=immich-app/immich&type=date" width="100%" />
 </picture>
</a>

## Contributors

<a href="https://github.com/immich-app/immich/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=immich-app/immich" width="100%"/>
</a>
