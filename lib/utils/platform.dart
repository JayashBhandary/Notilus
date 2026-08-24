import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

/// Forces [isMobilePlatform] either way. Tests only: the mobile shape has to be
/// checkable from a desktop test run, since that is where the suite runs.
@visibleForTesting
bool? debugMobilePlatformOverride;

/// What the host OS lets this build do.
///
/// Layout is decided by width ([isCompact] in `responsive.dart`) — a narrow
/// desktop window gets the phone layout and should still keep every desktop
/// feature. These flags are the other axis: whether a feature can work here at
/// all. A phone-sized macOS window still has a shell to spawn; an iPad in
/// landscape does not.
bool get isMobilePlatform =>
    debugMobilePlatformOverride ??
    (!kIsWeb && (Platform.isIOS || Platform.isAndroid));

/// Whether the integrated terminal can run.
///
/// It spawns a real login shell through a pty. iOS has no shell to spawn and
/// forbids the app from spawning one; Android is no better placed.
bool get hasIntegratedTerminal => !isMobilePlatform;

/// Whether this build can publish a folder over SMB.
///
/// Mobile is the client half: an app that stops getting CPU the moment it
/// leaves the foreground can't answer a file server's socket, and the only
/// folder it could publish is its own container.
bool get canHostShares => !isMobilePlatform;

/// Whether the whole-machine tools — system overview, duplicate finder — have
/// anything to look at.
///
/// Both assume a filesystem the app can read all of: mounted volumes, other
/// users' folders, everything a scan would compare. Inside a mobile sandbox
/// they would report on a single app container and call it the machine.
bool get hasMachineTools => !isMobilePlatform;
