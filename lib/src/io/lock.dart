import 'dart:io';

import '../lock_state.dart';

/// Thrown when another run holds the lock of a package.
class LockHeld implements Exception {
  LockHeld({this.pid, this.started});

  /// The process that holds the lock and when it took it, as that process
  /// wrote them into the lock file. `null` when they cannot be read.
  final int? pid;
  final String? started;
}

/// The lock that keeps a second run out of a package while one is at work in
/// it.
///
/// It is a lock of the operating system on a file (`fcntl` on macOS and
/// Linux, `LockFileEx` on Windows), held for as long as the run keeps the
/// file open. The operating system gives it up when the process ends,
/// however it ends, so a run that was killed leaves no lock behind, and
/// nothing has to guess from a process id whether its owner is still alive:
/// a process id that was given to another program since cannot be mistaken
/// for the run.
///
/// The process id and the time in the file are for the message of the run
/// that is turned away. The file itself stays; only the lock on it counts.
class RunLock {
  RunLock._(this._path, this._file);

  final String _path;
  final RandomAccessFile _file;

  /// The locks of this process. The operating system keeps its locks per
  /// process, so two runs in one process (the tests of this package) have
  /// to be kept apart here.
  ///
  /// Path → the time the lock was taken. The file must not be read for it
  /// here: with `fcntl`, closing any handle of a file gives up the locks
  /// the process has on it.
  static final _held = <String, String>{};

  /// Takes the lock [path]. Throws [LockHeld] when another run has it, and
  /// a [FileSystemException] when the file cannot be made or cannot be
  /// locked at all (a file system without locks).
  static RunLock acquire(String path) {
    final file = File(path);
    final held = _held[file.absolute.path];
    if (held != null) {
      throw LockHeld(pid: pid, started: held);
    }
    file.parent.createSync(recursive: true);
    // Append: opening the file must not empty what the holder wrote.
    final opened = file.openSync(mode: FileMode.append);
    try {
      opened.lockSync(FileLock.exclusive);
    } on FileSystemException catch (error) {
      opened.closeSync();
      if (!lockedByAnother(
        error.osError?.errorCode,
        windows: Platform.isWindows,
      )) {
        throw FileSystemException(
          'cannot lock the file that keeps a second run out of the package',
          path,
          error.osError,
        );
      }
      final holder = _read(file);
      throw LockHeld(pid: holder?.pid, started: holder?.started);
    }
    final started = DateTime.now().toUtc().toIso8601String();
    try {
      opened.truncateSync(0);
      opened.writeStringSync(lockHolder(pid: pid, started: started));
      opened.flushSync();
    } on FileSystemException {
      opened.closeSync();
      rethrow;
    }
    _held[file.absolute.path] = started;
    return RunLock._(file.absolute.path, opened);
  }

  static ({int? pid, String? started})? _read(File file) {
    try {
      return readLockHolder(file.readAsStringSync());
    } on FileSystemException {
      // Windows does not let another process read a locked file.
      return null;
    }
  }

  /// Gives the lock up.
  void release() {
    if (_held.remove(_path) == null) {
      return;
    }
    try {
      _file.truncateSync(0);
    } on FileSystemException {
      // The lock is what counts.
    }
    _file.closeSync();
  }
}
