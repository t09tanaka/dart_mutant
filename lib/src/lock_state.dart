import 'dart:convert';

import 'json.dart';

/// True for what the operating system answers when another process has the
/// lock of a file ([code] is the error code of the failed attempt, [windows]
/// says which system's codes they are): EAGAIN (11 on Linux, 35 on macOS) or
/// EACCES (13), and ERROR_LOCK_VIOLATION (33) on Windows.
///
/// Anything else, and no code at all, is a file system that cannot lock: a
/// run must not start there, and must not say that another run is at work.
bool lockedByAnother(int? code, {required bool windows}) =>
    windows ? code == 33 : code == 11 || code == 13 || code == 35;

/// What a run writes into the lock file when it has the lock: who it is and
/// since when, for the message of a run that is turned away.
String lockHolder({required int pid, required String started}) =>
    jsonEncode({'pid': pid, 'started': started});

/// The process that holds a lock and the time it took it, from what
/// [lockHolder] wrote ([text]). Each is `null` when it cannot be read: the
/// file is empty between two runs, and a run can be turned away in the
/// moment before the holder has written it.
({int? pid, String? started}) readLockHolder(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return (pid: null, started: null);
  }
  final holder = asObject(decoded);
  final pid = holder?['pid'];
  final started = holder?['started'];
  return (
    pid: pid is int ? pid : null,
    started: started is String ? started : null,
  );
}
