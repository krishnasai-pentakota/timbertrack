# TimberTrack: design notes (version 3.3)

## People and permissions

There are three kinds of login: owner, accountant and staff. Aditya and Bharat share one owner login. Permissions are flags on each person; the owner has all of them.

| Permission | Allows | Owner | Accountant | Staff |
|---|---|:---:|:---:|:---:|
| `plan` | Planning, Truck fixed, Cancel; add wood types | ✓ | | |
| `finance` | Bills, payments, balances; **view** rates and expenses | ✓ | ✓ | |
| `rates` | **Enter** sawmill rate cards and item rates | ✓ | | |
| `expenses` | **Enter** freight and other charges | ✓ | | |
| `people` | Logins, permissions, settings | ✓ | | |

- **Changing a flag:** any flag can be given to another person from More → Team without a database change.
- **Owner-only actions:** only the owner can create another owner, grant `people`, or reset an owner's password. The `team-admin` function checks this.

## Staff: from truck to Loaded

1. **+ Truck** (register a truck).
   - Enter the date, truck number, capacity (tons and CFT), driver name and phone.
   - The **photo of the driver beside the truck is compulsory**. Without it, a red box reads "Driver photo with truck is mandatory.", the photo tile is outlined in red, and nothing is saved.
   - The driving licence and C-Book are optional. When missing they show "Not Provided" in grey.
   - The truck is saved at **Going to load**.
2. **+ Add sawmill** for each sawmill. Sawmill name, sawmill owner and party are kept as separate fields.
3. **+ Add wood item**, or **+ Piece tally** for wood counted piece by piece.
   - Wood type comes from the saved list (staff can't invent one).
   - Size is Small / Medium / Large.
   - Give the quantity and unit (CFT, CBM, RFT, SFT, Tons, Pieces), plus the pieces count and dimensions.
   - Units are never added together: a load shows, for example, "900 CFT + 100 Pieces".
4. **Truck reached** on a sawmill. The load moves to **Under loading** and the arrival time is recorded.
5. **Loading done here + weigh slip.**
   - Take that sawmill's slip photo; the net weight is optional.
   - The sawmill's items are marked done.
   - A truck may take its full load at one sawmill.
6. **Export Staff PDF** at any time after the items are in.
7. **Move to: Loaded**, entering the kata net weight of the whole truck. This is refused while any sawmill has no weigh slip or any item is open.
8. **In transit:** send the driver an "Ask location" WhatsApp message and post updates. Then mark **Delivered**.

## Owner

- **+ New load** (Planning): buyer, destination, truck size and reason. Then **Truck fixed**: truck, driver and transporter.
- **Freight and charges:** + Add expense on a load, with the category, amount, who was paid, an optional sawmill and an optional receipt photo. The Expenses screen shows the month by category and trip by trip.
- **Sawmill rates:** choose a sawmill, then + New rate (wood, size or any, unit, rate, start date, reason). On a load, Set rate on each item suggests the rate in force on the load date. A new rate never changes rates already saved.
- **Home screen:**
  - loads changed since you last checked (red);
  - missing documents (amber);
  - loads by stage;
  - freight and expenses this month;
  - money to collect and to pay.

## Accountant

- **Can view:** rates and expenses, without changing them.
- **Bills:** once a load is Delivered, + Create bill (invoice number and date, sale quantity and rate, GST amount, credit days).
- **Bill status moves by itself:** Ready to bill → Billed → Payment pending (part paid or overdue) → Paid.
- **Payments:** from buyers, to sawmills and to transporters, with balances per party.

## Loading PDF (staff)

- **Title:** **TRUCK LOADING / DISPATCH DETAILS**, marked as an operational document, not a tax invoice.
- **Header:** load reference, dates, destination, truck number, capacity, driver and kata net weight.
- **Parties:** dispatch-from (the business and the sawmills) and the consignee.
- **Table:** **Sl. No. · Saw Mill Name · Name of Product · Size · Quantity · Unit**.
  - The heading repeats on every page.
  - Columns are fixed, so nothing is cut off on A4.
- **Below the table:**
  - quantity by unit;
  - weigh slips per sawmill;
  - a piece-tally table (pieces and CFT by thickness and size);
  - remarks.
- **Footer:** prepared by, driver acknowledgement, loading confirmation.
- **No money:** the PDF is built only from a list of permitted fields. It never contains a rate, amount, GST, freight, bank or payment detail, even when the owner makes it.

## Weigh slips

- **One box per sawmill,** numbered and named, showing "Not Uploaded" or how many slips are in. A sawmill can have several slips.
- **Always tied to its sawmill:** the database refuses a slip with no sawmill, or with a sawmill from another truck.
- **Setting:** "Every sawmill needs a weigh slip before Loaded" is on by default.

## Piece tally

See [CFT_TALLY.md](CFT_TALLY.md).

## Database

| Table | Holds |
|---|---|
| `profiles` | Person, role, permission flags |
| `loads` | The truck trip: date, stage, truck, capacity, driver, transporter, party, destination, e-way bill, kata net weight |
| `load_allocations` | One sawmill on one trip: owner name, party name, reached time, loading-done time, slip net weight |
| `load_lines` | Wood items: wood type, size, quantity, unit, pieces, dimensions, status; `tally_id` when made by a tally |
| `load_tallies` | Piece counts by thickness × length × width for one wood at one sawmill |
| `line_prices` | Purchase rate and adjustment on an item (money) |
| `sawmill_rates` | Rate cards; insert-only, so history is kept |
| `load_costs` | Freight and charges: category, amount, paid to, receipt, optional sawmill |
| `load_billing`, `payments` | Bill per load; payments from buyers, to sawmills and transporters |
| `load_files` | Driver photo, licence, C-Book, weigh slips (with sawmill), other photos |
| `sawmills`, `parties` | Sawmills; buyers and transporters |
| `wood_types`, `expense_categories`, `app_settings` | Saved lists and rules |
| `activity` | Every change: before → after, person, exact time, reason, stage, who may see it |
| `load_reviews` | Each person's "checked" time per load (the red flags) |

- **Views:** `v_loads`, `v_allocations`, `v_lines` and `v_balances` run with the caller's rights, so staff get blank money columns.
- **Trucks and drivers** are kept on the trip, so there are no extra screens to manage.

## Rules enforced in the database

- **Owner-only stages:** Planning, Truck fixed and Cancel. Loads in those stages, and their history, are never returned to staff.
- **Stage order:**
  - no load leaves Planning without a truck number;
  - Under loading needs a sawmill marked "Truck reached";
  - the driver photo is required from Under loading on.
- **Loaded:** needs at least one item, all items done, and a weigh slip for every sawmill. After Loaded, sawmills, items and tallies are locked: move back to Under loading first.
- **Same truck only:** a weigh slip or an expense can only point to a sawmill on the same truck.
- **Money:** the money tables are not readable by staff, and expense receipts can't be opened by staff in storage. The anonymous key reaches no table at all.
- **History:** rate cards can't be edited or deleted, and nobody can edit or delete the history.

## Decisions

| Choice | Why |
|---|---|
| Rules in the database, not only on screen | Hiding a button is not security. A staff phone never receives money, even through the API. |
| One trip, many sawmills, many items | That is how trucks are loaded. Each sawmill keeps its own items, weigh slips and charges. |
| Under loading starts at the sawmill | The owner asked that the stage shows where the truck really is. |
| Piece tally computed in the database | The CFT can't drift between phones, and it matches the owner's Excel workbook exactly. |
| One HTML file, no build step | Easy to host anywhere, quick on cheap phones, easy to hand over. |
| Shared sizes for every wood | The owner confirmed that Small / Medium / Large mean the same lengths for all woods. |
