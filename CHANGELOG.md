## 2.0.0

The command surface changed, hence the major bump.

### Added

- `set-default <dir>` remembers where your API models live, so `--models` is
  no longer needed on every run. Machine-wide by default; `--project` writes a
  setting for one repo that wins over it.
- Commands warn and ask before falling back to scanning the whole of `lib`.

### Removed

- `--link-style`, `--json` and `--fail-on-unused`. The first threaded a
  rendering option through four files for a report that only ever opens on the
  machine that wrote it; the other two existed solely for CI, which this tool
  is not run in.
- `--models` no longer defaults to `lib/server/response`. Use `set-default`.

### Fixed

- Removing a field now also removes the `super.field` parameters that
  subclasses forward it through, including subclasses in other files. Before,
  the edit left `super_formal_parameter_without_associated_named` behind — a
  resolution error, so it parsed cleanly and only `dart analyze` caught it.
- `disable --undo` no longer refuses a dirty working tree. `disable` dirties
  the tree by construction, so the guard made undo unreachable exactly when it
  was most wanted. `--remove`, the irreversible path, keeps it.
- `--undo` restores every field sharing one commented range. A `hashCode`
  taken whole is recorded under each of its fields; the first field restored it
  and every later one was then skipped wholesale, stranding its declaration
  while the restored expression still named it.
- `--undo` restores byte-identical ranges separately. A field routinely
  produces `num? id,` twice — constructor and `copyWith` — and the record
  deduplicated them, leaving the second commented for good with the record
  cleared as though it had been restored.
- Undoing a subset now holds back ranges shared with fields that are not
  selected, and says which ones to tick, instead of writing code that does not
  compile and reverting the whole run.

### Changed

- `disabled_fields.json` records each range with its position in the file, not
  just its text. Records in the old format still load.
- `clear` keeps `config.json`; it is a setting, not a cached result.

## 1.0.0

- Initial version.
