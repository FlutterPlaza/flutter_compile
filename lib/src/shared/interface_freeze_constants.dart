/// Filenames shared between the build service (writer), the release
/// command (path composition), and the archive service (destination) —
/// deliberately dependency-free so the archive does not have to import
/// the whole build service for two strings.
library;

/// The generated interface-freeze spec (intent).
const String kInterfaceSpecFilename = 'dynamic_interface.yaml';

/// The front end's detailed interface report (the compiler's own
/// account of what it guarded — evidence, where the spec is intent).
const String kInterfaceReportFilename = 'dynamic_interface_report.json';
