# Data model
- Run property summary: `{ total: <count of every node in .data[]>, passing: <count with status "Passing">, failing: [<name of every node with status != "Passing">] }` — same population as the detail's properties list.
- Summary cache: new filename namespace under the props cache dir (pre-fix files are never read); written only when the response's node list is non-empty and the run is completed.
- Fixture taxonomy (mirrors the live API): group nodes (failing and passing), plain leaves, event leaves; one response with an empty node list.
