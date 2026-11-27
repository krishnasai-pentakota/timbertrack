# Piece tally and CFT

At the sawmill, staff count sawn pieces on a paper grid. Until now the counts were typed into an Excel workbook that worked out the CFT. The app's piece tally replaces that step, and the database repeats the workbook's calculation exactly.

## The calculation (from the owner's workbook)

**CFT = thickness (inches) × width (inches) × length (decimal feet) × pieces ÷ 144**

- **No rounding inside the calculation:** each box is worked out exactly and the totals add the exact values. Totals are shown to 2 decimals; items store 3.
- **CBM = CFT ÷ 35.3147:** this is shown on the tally summary only. Units are never converted anywhere else.
- **Pieces:** the sum of all the counts.

## The grid

- **Thickness:** 1", 1.5" or 2". The workbook has one block per thickness.
- **Length (down):** 1'6" to 8'6" in 3-inch steps. It is shown the way it is written on paper, where "2.3" means 2 ft 3 in, and stored as decimal feet (2.25). The shortest length is 1'6", the same as the rule that shorter pieces are not loaded.
- **Width (across):** 4" to 11", whole inches.
- **Grid size:** this is the range found in the workbook's data. Wider and longer pieces are very rare, and the grid can be widened in Settings.
- **Entering counts:** type a count in a box, or tap the box and use +1, +5, +10 or −1. Unsaved counts stay on the phone if the signal drops.

## Sizes

These apply to every wood. They come from the workbook's summary sheet, and the owner confirmed they hold for all woods.

| Size | Length |
|---|---|
| Small | 1'6" to 2'9" |
| Medium | 3'0" to 4'9" |
| Large | 5'0" and longer |

## What saving a tally does

1. **Checks every box:** a known thickness, a 3-inch length step, a whole-inch width and whole-number counts.
2. **Works out** the CFT and pieces by size.
3. **Creates one wood item per size** that has pieces (for example "Mango · Small · 621.46 CFT · 5,034 pcs"). Rates and amounts then work on these items like on any other.
4. **Logs the change:** history records the reason and the before and after, for example "36.91 CFT · 477 pcs → 335.05 CFT · 2,190 pcs".

Items made by a tally can only be changed through the tally. After the truck is Loaded, the tally is locked.

## Checked against the workbook

The tests type the workbook's own counts into the app (`tests/db/workbook_tally_counts.json`) and compare the results:

| | Workbook | App |
|---|---:|---:|
| Sheet "1-1" | 36.91 CFT · 477 pcs | 36.91 CFT · 477 pcs |
| All 2-inch sheets | 1,223.20 CFT · 6,575 pcs | 1,223.20 CFT · 6,575 pcs |
| Whole truck | 1,350.00 CFT · 8,245 pcs | 1,350.00 CFT · 8,245 pcs (38.23 CBM) |
| Small / Medium / Large | 621.46 / 646.25 / 82.29 CFT | 621.46 / 646.25 / 82.29 CFT |

**Mistakes in the workbook that the app does not copy** (the owner confirmed both are mistakes):

- **Wrong thickness for long pieces:** in the 1-inch sheets, rows of 9 ft and longer were multiplied by 1.5 instead of 1.
- **Pieces left out of the count:** from 4 ft on, the pieces count left out the 3-inch width column.
