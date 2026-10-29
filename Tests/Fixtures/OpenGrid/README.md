# openGrid reference files

These are official openGrid files by **David D**, licensed under the
[Creative Commons Attribution 4.0 International license](https://creativecommons.org/licenses/by/4.0/).
They are not covered by Swipe & Sketch's PolyForm Shield license. They are kept here, as downloaded apart from
header metadata (below), so the tests can compare the app's openGrid templates with them.

- openGrid: https://www.opengrid.world/
- Core models: https://www.printables.com/model/1214361-opengrid-walldesk-mounting-framework-and-ecosystem
- Metric screw snaps: https://www.printables.com/model/1217921-opengrid-metric-screw-snaps

Downloaded October 29, 2026 (12:01 UTC) from Printables; the drawing is "last updated 08/10/25". The
STEP files are as downloaded except for their header metadata: the comment and fields naming the
exporting application and the author's local file paths are blanked. Their geometry is untouched
(`OpenGridTests` reads them). The SHA-256 below is of the files as kept here.

| File | Printables model / file id | SHA-256 |
| --- | --- | --- |
| openGrid 2x2.step | 1214361 / 5051182 | `a05abe4fd86dba00465e0e4e81e4b75d455268aad17610d936ccc958fa9c9b7e` |
| openGrid 3x2.step | 1214361 / 5051183 | `ce54717bde0712c1f604f91322d4e4a3c1ef685cb4c8750ca28a7f1b6562383d` |
| openGrid Lite 2x2.step | 1214361 / 5051060 | `bc8e2a2e5b96a6cd1bb015638ad5a26b9ad375957e6c990202cb6a125dce7848` |
| openGrid Lite 3x2.step | 1214361 / 5051062 | `7382d967edd8663c79c913929b4fd36bdbcc4df9c3661730073fb055496fbe9c` |
| openGrid Edge Connector.step | 1214361 / 5051325 | `319edc3e6e14f8d7fcd609aa0e339ceaf61a767e039357debe2c6fb4ac701b7d` |
| openGrid Lite Connector.step | 1214361 / 5051324 | `4dffc3d79dccd16e52bb11bc774f5a54ce4261db24e7c6355ba5ad26d434f580` |
| openGrid Wall Mount.step | 1214361 / 5064420 | `6968b45415872240808929e97e16ec2fcc598ca5c7039252dba3bd7a8e9aa06b` |
| openGrid Lite Wall Mount.step | 1214361 / 5064435 | `4351f14bea41884ab72557843964eeb63bfbd3bd820c9a8c4e5e714d96ad882a` |
| openGrid Open Wall Mount.step | 1214361 / 5064425 | `2ca8da4f115ce29d05a2ef7879377a3d736bf48053710255181ae7ab27124563` |
| openGrid Color_Cover Snap for Open Wall Mount.step | 1214361 / 5064445 | `216768ad17c4da08b9d733f675273cd75c44745aae81a54330733b391f250ed5` |
| openGrid Tile Dimensions.pdf | 1214361 / 134131 | `7ff1906fa0c1dd58e02e860645f29a151392a561bdb5e2b05ddf9ea0d3983925` |
| openGrid M3 Nut Snap.step | 1217921 / 5805934 | `3b03ff69a9fd2d3c3858ba0131bc8f9f94db5a019a66bbe7f78417fe582455d7` |
| openGrid M3 Nut Directional Snap v2.step | 1217921 / 5805937 | `fc8047495ba5f6f9eec5c9dd19021a5b2bf26aeb1573b10130644216aca8fff6` |
| openGrid Lite M3 Nut Snap.step | 1217921 / 5805932 | `485ecf456ef79568fec13d0677d3eb2eae0ab9bcdb6bcd2be531289ac76cf013` |
| openGrid Lite M3 Nut Directional Snap.step | 1217921 / 5805936 | `daac119d5832e15c63025ef84060c275eeb2b39b23f29850a7dcffc8c848f24d` |

## How the app uses them

- **Boards** are rebuilt in code (`SwipeAndSketch/Core/OpenGridGeometry.swift`) from the published
  profile. `OpenGridTests` checks that the rebuilt 2×2 and 2×3 Full and Lite boards are the same
  solids as these files (no volume left over either way).
- **Connectors, mounts, the cover, and the M3 nut snaps** are these files' solids, unchanged apart
  from being moved so each is centered on the origin, stored in
  `SwipeAndSketch/Core/OpenGridPartData.swift`. `Scripts/update_opengrid_parts.sh` writes that
  file from these, and `OpenGridTests` checks that it still matches them.
