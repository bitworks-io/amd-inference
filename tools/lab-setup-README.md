# FastLLM private lab setup source

This is an unsigned, unqualified lab bootstrap. Review and obtain these setup
scripts from a source you trust **before running them**. The bundled manifest
and its SHA-256 sidecar check consistency or transfer integrity only; neither
authenticates Bitworks as publisher.

Run `Install-FastLLM-Lab.cmd` as a standard Windows user. Select the separately
obtained full FastLLM lab ZIP and enter its expected SHA-256 from a separate,
trusted channel. Do not treat the `.sha256` file distributed beside that ZIP as
an independent expected value. The bootstrap does not include the app ZIP,
engine, model weights, or an expected app ZIP digest.

Keep this external companion separately from the installed app. It also offers
Preview uninstall, recoverable Uninstall, and Restore for new installations with
a complete ownership ledger. Close the app and any managed CLI sessions first.
Review the exact item count and preview SHA-256 before confirming. Removal moves
only verified app versions, metadata and the exact owned shortcut into a sibling
`FastLLM-App-Quarantine` folder; it does not free that disk space or erase models,
consent receipts or reports. Preserve the displayed quarantine path for Restore.
Interrupted removal/restore exposes its verified recovery path in Preview.

Unknown or modified files, active sessions, and older pre-ledger installations
require review instead of automatic removal. A guarded new package cannot repair
a pre-ledger app in place. After removal, use Restore; clean reinstallation over
the retained root and permanent quarantine disposal remain manual-review tasks.
The lifetime guard is cooperative source logic, not protection against a
malicious same-user process. Native and visible-UI qualification remain separate.
Automatic busy detection covers only the managed control window and main CLI.
Directly launched developer/experimental tools do not hold that lease: run them
from a separate reviewed checkout and close them before app removal or restore.

This is not a public release or a claim of Windows/AMD qualification.
