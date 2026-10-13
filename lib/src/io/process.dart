import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../memory.dart';

/// Waits for SIGINT (Ctrl-C), SIGTERM or SIGHUP (the terminal was closed)
/// instead of letting them end the process, so that the caller can put files back first.
///
/// While this is active the signal no longer terminates the process: the
/// caller has to return when [received] completes.
class SignalWatch {
  SignalWatch() {
    for (final signal in [
      ProcessSignal.sigint,
      // Windows only delivers SIGINT.
      if (!Platform.isWindows) ...[ProcessSignal.sigterm, ProcessSignal.sighup],
    ]) {
      _subscriptions.add(
        signal.watch().listen((signal) {
          if (!_received.isCompleted) {
            this.signal = signal;
            _received.complete(signal);
          }
        }),
      );
    }
  }

  final _received = Completer<ProcessSignal>();
  final _subscriptions = <StreamSubscription<ProcessSignal>>[];

  /// The first signal that arrived, if any.
  ProcessSignal? signal;

  /// Completes with the first signal.
  Future<ProcessSignal> get received => _received.future;

  /// Gives the signals back to their default handling.
  Future<void> cancel() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}

/// The exit code of a process ended by [signal], as a shell reports it.
int signalExitCode(ProcessSignal signal) => switch (signal) {
  ProcessSignal.sigint => 130,
  ProcessSignal.sighup => 129,
  _ => 143,
};

class CommandResult {
  const CommandResult({
    this.exitCode,
    this.output = '',
    this.startError,
    this.signal,
    this.timedOut = false,
    this.overMemory = false,
  });

  /// `null` when the command could not be started or was interrupted.
  final int? exitCode;

  /// stdout and stderr, when captured.
  final String output;

  /// Why the command could not be started.
  final String? startError;

  /// The signal that interrupted the run.
  final ProcessSignal? signal;

  /// True when the command was ended because it ran longer than its limit.
  final bool timedOut;

  /// True when the command was ended because it held more memory than its
  /// limit, see [MemoryWatch].
  final bool overMemory;

  /// True when the command was ended because it reached a limit.
  bool get limited => timedOut || overMemory;
}

/// What is measured of the memory of a command while it runs: the resident
/// set of the command and of the processes that descend from it, together,
/// as `ps` reports them a few times a second.
///
/// Nothing is measured on Windows and where there is no `ps`: [peak] stays
/// 0 there, and no command is ended.
class MemoryWatch {
  MemoryWatch({this.limit});

  /// How many kilobytes the command may hold from now on, or `null` for as
  /// many as it takes. Asked after every measurement, with [peak] already
  /// counting it.
  final int? Function()? limit;

  /// The most that was measured, in kilobytes.
  int peak = 0;
}

/// How often the memory of the commands is measured. A loop that does
/// nothing but allocate takes a few gigabytes in a second.
const _memoryTick = Duration(milliseconds: 100);

/// The commands whose memory is measured, by process id: one `ps` for all
/// of them.
final _measured = <int, void Function(String listing)>{};
Timer? _measuring;
var _listing = false;

Future<void> _measure() async {
  if (_listing) {
    // The last `ps` has not answered yet.
    return;
  }
  _listing = true;
  try {
    final listed = await Process.run('ps', processListing);
    if (listed.exitCode == 0) {
      for (final MapEntry(key: pid, value: measure)
          in _measured.entries.toList()) {
        // Not one that has ended since: its number may be another's now.
        if (_measured[pid] == measure) {
          measure(listed.stdout as String);
        }
      }
    }
  } on ProcessException {
    // No `ps`: nothing is measured.
  } finally {
    _listing = false;
  }
}

void _startMeasuring(int pid, void Function(String listing) measure) {
  if (Platform.isWindows) {
    return;
  }
  _measured[pid] = measure;
  _measuring ??= Timer.periodic(_memoryTick, (_) => _measure());
}

void _stopMeasuring(int pid) {
  _measured.remove(pid);
  if (_measured.isEmpty) {
    _measuring?.cancel();
    _measuring = null;
  }
}

/// The processes that descend from [root], as `ps` lists them now. Empty on
/// Windows and when `ps` cannot be run.
List<int> _descendantsOf(int root) {
  if (Platform.isWindows) {
    return const [];
  }
  final ProcessResult listed;
  try {
    listed = Process.runSync('ps', processListing);
  } on ProcessException {
    return const [];
  }
  return listed.exitCode != 0
      ? const []
      : processTree(listed.stdout as String, root).descendants;
}

/// Ends [process] and what it started: SIGTERM first, so that it can clean
/// up, then SIGKILL for whatever is left after [grace]. A test runner that is
/// killed alone can leave the process that runs the tests behind, spinning
/// in the very loop that made it time out.
Future<void> _endTree(Process process, Duration grace) async {
  final descendants = _descendantsOf(process.pid);
  process.kill();
  await process.exitCode.timeout(
    grace,
    onTimeout: () {
      process.kill(ProcessSignal.sigkill);
      return process.exitCode;
    },
  );
  for (final pid in descendants) {
    Process.killPid(pid, ProcessSignal.sigkill);
  }
}

/// How long a child gets to end after SIGTERM before it is killed.
const _killGrace = Duration(seconds: 10);

/// The same for a child that ran into its time limit: it is not expected to
/// answer at all.
const _limitGrace = Duration(seconds: 3);

class _LimitReached {
  const _LimitReached();
}

class _MemoryReached {
  const _MemoryReached();
}

/// How long the output of a child that has ended is waited for. A process it
/// left behind can keep the pipes open for good.
const _drainGrace = Duration(seconds: 5);

/// How long a signal is waited for after a child failed. Ctrl-C reaches the
/// child as well, and the child can end before the signal is seen here.
const _signalGrace = Duration(milliseconds: 250);

/// Runs [command] (program first) in [workingDirectory] without a shell, so
/// that no argument is interpreted. On Windows a shell is used, because
/// `flutter` and `dart` are batch files there.
///
/// On a signal, and at the time limit, the process is ended together with
/// the processes that descend from it (found with `ps`; on Windows, and where
/// there is no `ps`, only the process itself).
///
/// With [capture] the output is collected; otherwise it goes to the terminal.
/// When [signals] reports a signal, the child is ended and the result carries
/// the signal. When the command runs longer than [timeout], it is ended with
/// everything it started and the result says so.
///
/// [onLine] gets every line of the standard output when it is there (with
/// [capture]; the result then only has the standard error), and [stop] ends
/// the command the way [timeout] does when it completes: for a caller that
/// reads the output to decide how long the command may go on.
///
/// With [memory] the memory of the command and of the processes that
/// descend from it is measured while it runs. When they hold more than its
/// limit, all of them are killed at once, without the time to clean up that
/// the time limit gives: every moment costs more memory. The result says so
/// ([CommandResult.overMemory]).
Future<CommandResult> runCommand(
  List<String> command, {
  required String workingDirectory,
  required bool capture,
  required SignalWatch signals,
  Duration? timeout,
  void Function(String line)? onLine,
  Future<void>? stop,
  MemoryWatch? memory,
}) async {
  final Process process;
  try {
    process = await Process.start(
      command.first,
      command.sublist(1),
      workingDirectory: workingDirectory,
      runInShell: Platform.isWindows,
      mode: capture ? ProcessStartMode.normal : ProcessStartMode.inheritStdio,
    );
  } on ProcessException catch (error) {
    return CommandResult(startError: error.message);
  }

  final output = StringBuffer();
  final drained = <Future<void>>[];
  if (capture) {
    for (final stream in [process.stdout, process.stderr]) {
      final text = stream.transform(const Utf8Decoder(allowMalformed: true));
      drained.add(
        onLine == null || stream != process.stdout
            ? text.forEach(output.write)
            // Not kept: the caller reads it as it comes.
            : text.transform(const LineSplitter()).forEach(onLine),
      );
    }
  }

  final limit = Completer<_LimitReached>();
  final timer = timeout == null
      ? null
      : Timer(timeout, () => limit.complete(const _LimitReached()));
  final tooMuch = Completer<_MemoryReached>();
  if (memory != null) {
    _startMeasuring(process.pid, (listing) {
      final tree = processTree(listing, process.pid);
      if (tree.kilobytes > memory.peak) {
        memory.peak = tree.kilobytes;
      }
      final most = memory.limit?.call();
      if (most != null && tree.kilobytes > most && !tooMuch.isCompleted) {
        // What it started first: a process whose parent is gone is no
        // longer found as its descendant. Then what it has started since
        // the list was made.
        for (final pid in [
          ...tree.descendants,
          ..._descendantsOf(process.pid),
        ]) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
        process.kill(ProcessSignal.sigkill);
        tooMuch.complete(const _MemoryReached());
      }
    });
  }
  final Object ended;
  try {
    ended = await Future.any<Object>([
      process.exitCode,
      signals.received,
      limit.future,
      tooMuch.future,
      ?stop?.then((_) => const _LimitReached()),
    ]);
  } finally {
    _stopMeasuring(process.pid);
  }
  timer?.cancel();
  // A caller that reads the lines must have got the last one before it is
  // told that the command has ended.
  Future<void> lines() => onLine == null
      ? Future.value()
      : Future.wait(drained).timeout(_drainGrace, onTimeout: () => const []);
  if (ended is ProcessSignal) {
    await _endTree(process, _killGrace);
    await lines();
    return CommandResult(output: output.toString(), signal: ended);
  }
  if (ended is _LimitReached) {
    await _endTree(process, _limitGrace);
    await lines();
    return CommandResult(output: output.toString(), timedOut: true);
  }
  if (ended is _MemoryReached || tooMuch.isCompleted) {
    // Killed above.
    await process.exitCode;
    await lines();
    return CommandResult(output: output.toString(), overMemory: true);
  }
  await Future.any<Object?>([
    Future.wait(drained).timeout(_drainGrace, onTimeout: () => const []),
    signals.received,
  ]);
  if (ended != 0 && signals.signal == null) {
    await Future.any<Object?>([
      Future<void>.delayed(_signalGrace),
      signals.received,
    ]);
  }
  return CommandResult(
    exitCode: signals.signal == null ? ended as int : null,
    output: output.toString(),
    signal: signals.signal,
  );
}
